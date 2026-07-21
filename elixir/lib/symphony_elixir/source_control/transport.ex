defmodule SymphonyElixir.SourceControl.Transport do
  @moduledoc false

  alias SymphonyElixir.SourceControl.Transport.{Git, HTTP}

  @type request :: %{
          required(:method) => :get | :post | :put | :patch | :git_push,
          required(:path) => String.t(),
          optional(:headers) => map(),
          optional(:query) => map(),
          optional(:json) => map() | list(),
          optional(:retry) => :safe | :never
        }

  @type response :: %{status: non_neg_integer(), headers: map(), body: term()}

  @credential_key {__MODULE__, :credential}
  @credential_header_names ~w(authorization proxy-authorization private-token cookie api-key x-api-key token)

  @spec with_credential(String.t() | nil, (-> result)) :: result when result: term()
  def with_credential(credential, fun) when is_function(fun, 0) do
    previous = Process.get(@credential_key, :not_set)
    Process.put(@credential_key, credential)

    try do
      fun.()
    after
      restore_credential(previous)
    end
  end

  @spec sign_marker_payload(String.t()) :: {:ok, String.t()} | {:error, :invalid_configuration}
  def sign_marker_payload(payload) when is_binary(payload) do
    with {:ok, credential} <- scoped_credential() do
      signature =
        :crypto.mac(:hmac, :sha256, credential, payload)
        |> Base.encode16(case: :lower)

      {:ok, signature}
    end
  end

  def sign_marker_payload(_payload), do: {:error, :invalid_configuration}

  @spec valid_marker_signature?(String.t(), String.t()) :: boolean()
  def valid_marker_signature?(payload, signature)
      when is_binary(payload) and is_binary(signature) do
    with {:ok, expected} <- sign_marker_payload(payload),
         true <- byte_size(expected) == byte_size(signature) do
      :crypto.hash_equals(expected, signature)
    else
      _invalid -> false
    end
  end

  def valid_marker_signature?(_payload, _signature), do: false

  @spec request(map(), :github | :gitlab, request()) ::
          {:ok, response()} | {:error, term()}
  def request(config, provider, request)
      when is_map(config) and provider in [:github, :gitlab] and is_map(request) do
    with :ok <- validate_request(request),
         {:ok, credential} <- credential(config),
         request <- authorize(request, provider, credential) do
      do_request(config, provider, request, 1)
    end
  end

  @spec push(map(), :github | :gitlab, String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def push(config, provider, branch, desired_commit_sha, expected_remote_sha)
      when is_map(config) and provider in [:github, :gitlab] do
    request = %{
      method: :git_push,
      path: "refs/heads/#{branch}",
      branch: branch,
      desired_commit_sha: desired_commit_sha,
      expected_remote_sha: expected_remote_sha,
      retry: :never
    }

    with {:ok, credential} <- credential(config),
         request <- authorize(request, provider, credential) do
      dispatch_push(
        config,
        provider,
        branch,
        desired_commit_sha,
        expected_remote_sha,
        credential,
        request
      )
    end
  end

  defp dispatch_push(config, provider, branch, desired_sha, expected_sha, credential, request) do
    case value(config, :transport) do
      {module, state} when is_atom(module) ->
        normalize_push_result(module.request(request, state))

      nil ->
        Git.push(config, provider, branch, desired_sha, expected_sha, credential)

      _invalid ->
        {:error, :transport_failure}
    end
  end

  defp normalize_push_result({:ok, %{status: 0}}), do: :ok
  defp normalize_push_result(:ok), do: :ok
  defp normalize_push_result(_failure), do: {:error, :transport_failure}

  defp do_request(config, provider, request, attempt) do
    case dispatch(config, provider, request) do
      {:ok, response} ->
        handle_response(config, provider, request, attempt, response)

      {:error, :invalid_configuration} = error ->
        error

      {:error, _reason} ->
        {:error, :transport_failure}

      _other ->
        {:error, :transport_failure}
    end
  end

  defp handle_response(config, provider, request, attempt, response) do
    retry? = request_retryable?(request) and retryable_response?(response)
    maybe_retry(config, provider, request, attempt, response, retry?)
  end

  defp maybe_retry(_config, _provider, _request, _attempt, response, false),
    do: {:ok, normalize_response(response)}

  defp maybe_retry(config, provider, request, attempt, response, true) do
    if attempt < max_attempts(config) do
      sleep(config, retry_delay_ms(response, attempt))
      do_request(config, provider, request, attempt + 1)
    else
      rate_or_transport_error(response)
    end
  end

  defp dispatch(config, provider, request) do
    case value(config, :transport) do
      {module, state} when is_atom(module) -> module.request(request, state)
      nil -> HTTP.request(config, provider, request)
      _invalid -> {:error, :invalid_transport}
    end
  end

  defp authorize(request, :github, credential) do
    headers =
      request
      |> Map.get(:headers, %{})
      |> replace_headers(%{
        "accept" => "application/vnd.github+json",
        "authorization" => "Bearer #{credential}",
        "x-github-api-version" => "2026-03-10"
      })

    Map.put(request, :headers, headers)
  end

  defp authorize(request, :gitlab, credential) do
    headers =
      request
      |> Map.get(:headers, %{})
      |> replace_headers(%{"private-token" => credential})

    Map.put(request, :headers, headers)
  end

  defp replace_headers(headers, authoritative) do
    authoritative_names = Map.keys(authoritative)

    headers
    |> Enum.reject(fn {name, _value} ->
      normalized_name = name |> to_string() |> String.downcase()
      normalized_name in authoritative_names or credential_header_name?(normalized_name)
    end)
    |> Map.new()
    |> Map.merge(authoritative)
  end

  defp credential_header_name?(name) do
    name in @credential_header_names or
      String.ends_with?(name, ["-authorization", "-token", "-api-key"])
  end

  defp credential(config) do
    reference = value(config, :credential_ref)
    credential = Process.get(@credential_key)

    if opaque_reference?(reference) and is_binary(credential) and String.trim(credential) != "" do
      {:ok, credential}
    else
      {:error, :invalid_configuration}
    end
  end

  defp scoped_credential do
    case Process.get(@credential_key) do
      credential when is_binary(credential) ->
        if String.trim(credential) != "",
          do: {:ok, credential},
          else: {:error, :invalid_configuration}

      _missing ->
        {:error, :invalid_configuration}
    end
  end

  defp opaque_reference?(reference) when is_binary(reference) do
    Regex.match?(
      ~r/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/,
      reference
    )
  end

  defp opaque_reference?(_reference), do: false

  defp restore_credential(:not_set), do: Process.delete(@credential_key)
  defp restore_credential(previous), do: Process.put(@credential_key, previous)

  defp validate_request(%{method: method, path: path} = request)
       when method in [:get, :post, :put, :patch] do
    cond do
      not safe_absolute_path?(path) ->
        {:error, :invalid_configuration}

      invalid_optional_map?(request, :headers) ->
        {:error, :invalid_configuration}

      invalid_optional_map?(request, :query) ->
        {:error, :invalid_configuration}

      invalid_json?(request) ->
        {:error, :invalid_configuration}

      true ->
        :ok
    end
  end

  defp validate_request(_request), do: {:error, :invalid_configuration}

  defp invalid_optional_map?(request, key) do
    case Map.fetch(request, key) do
      {:ok, value} -> not is_map(value)
      :error -> false
    end
  end

  defp invalid_json?(request) do
    case Map.fetch(request, :json) do
      {:ok, value} -> not (is_map(value) or is_list(value))
      :error -> false
    end
  end

  defp safe_absolute_path?(path) do
    with true <- is_binary(path),
         true <- String.valid?(path),
         true <- String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
         true <- valid_percent_encoding?(path),
         decoded <- URI.decode(path),
         true <- String.valid?(decoded),
         true <- canonical_decoded_path?(decoded),
         %URI{
           scheme: nil,
           query: nil,
           fragment: nil,
           path: ^path
         } <- URI.parse(path) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_percent_encoding?(path) do
    ~r/%[0-9A-Fa-f]{2}/
    |> Regex.replace(path, "")
    |> then(&(not String.contains?(&1, "%")))
  end

  defp canonical_decoded_path?(path) do
    segments = String.split(path, "/", trim: false)

    not String.starts_with?(path, ["//", "/\\", "/@"]) and
      not String.contains?(path, ["\\", "//"]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/u, path) and
      Enum.all?(segments, &(&1 not in [".", ".."]))
  end

  defp request_retryable?(%{retry: :never}), do: false
  defp request_retryable?(%{method: method}) when method in [:post, :put, :patch], do: false
  defp request_retryable?(_request), do: true

  defp retryable_response?(%{status: status}) when status in [429, 502, 503, 504], do: true

  defp retryable_response?(%{status: 403} = response) do
    header(response, "retry-after") != nil or header(response, "x-ratelimit-remaining") == "0"
  end

  defp retryable_response?(_response), do: false

  defp max_attempts(config) do
    settings = value(config, :settings) || %{}

    case value(settings, :max_read_attempts) do
      attempts when is_integer(attempts) and attempts in 1..5 -> attempts
      _other -> 3
    end
  end

  defp retry_delay_ms(response, attempt) do
    retry_after = header(response, "retry-after")

    case Integer.parse(to_string(retry_after || "")) do
      {seconds, ""} when seconds >= 0 -> min(seconds * 1_000, 5_000)
      _other -> rate_reset_or_backoff(response, attempt)
    end
  end

  defp rate_reset_or_backoff(response, attempt) do
    case Integer.parse(to_string(header(response, "x-ratelimit-reset") || "")) do
      {epoch_seconds, ""} when epoch_seconds >= 0 ->
        min(max(epoch_seconds - System.system_time(:second), 0) * 1_000, 5_000)

      _other ->
        min(100 * Integer.pow(2, attempt - 1), 1_000)
    end
  end

  defp sleep(config, milliseconds) do
    case value(config, :retry_sleep) do
      fun when is_function(fun, 1) -> fun.(milliseconds)
      _other -> Process.sleep(milliseconds)
    end
  end

  defp rate_or_transport_error(%{status: status} = response) when status in [403, 429] do
    seconds = div(retry_delay_ms(response, 1), 1_000)
    {:error, {:rate_limited, seconds}}
  end

  defp rate_or_transport_error(_response), do: {:error, :transport_failure}

  defp normalize_response(response) do
    %{
      status: Map.get(response, :status),
      headers: normalize_headers(Map.get(response, :headers, %{})),
      body: Map.get(response, :body)
    }
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(to_string(name)), header_value(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(to_string(name)), header_value(value)} end)
  end

  defp normalize_headers(_headers), do: %{}

  defp header(response, name) do
    response
    |> Map.get(:headers, %{})
    |> normalize_headers()
    |> Map.get(name)
  end

  defp header_value([value | _rest]), do: to_string(value)
  defp header_value(value), do: to_string(value)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end

defmodule SymphonyElixir.SourceControl.Transport.HTTP do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.EndpointPolicy

  @spec request(map(), :github | :gitlab, map()) :: {:ok, map()} | {:error, term()}
  def request(config, provider, request) do
    with {:ok, authorization} <- endpoint_authorization(config, provider, request),
         {:ok, response} <- Req.request(request_options(authorization, request)) do
      {:ok, %{status: response.status, headers: response.headers, body: response.body}}
    else
      {:error, :invalid_configuration} = error ->
        error

      {:error, reason}
      when reason in [:invalid_endpoint, :untrusted_origin, :resolution_failed, :unsafe_address] ->
        {:error, :invalid_configuration}

      _failure ->
        {:error, :transport_failure}
    end
  end

  defp request_options(authorization, request) do
    options = [
      method: request.method,
      url: URI.to_string(authorization.url),
      headers: pinned_headers(Map.get(request, :headers, %{}), authorization.host_header),
      params: Map.get(request, :query, %{}),
      retry: false,
      redirect: false,
      connect_options: [hostname: authorization.hostname]
    ]

    case Map.fetch(request, :json) do
      {:ok, body} -> Keyword.put(options, :json, body)
      :error -> options
    end
  end

  defp pinned_headers(headers, host_header) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(to_string(name)) == "host" end)
    |> Enum.to_list()
    |> List.insert_at(0, {"host", host_header})
  end

  defp request_url(endpoint, path) when is_binary(path) do
    base = URI.parse(endpoint)

    with true <- safe_absolute_path?(path),
         joined <- %{base | path: (base.path || "") <> path},
         url <- URI.to_string(joined),
         final <- URI.parse(url),
         true <- same_origin?(base, final) do
      {:ok, url}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp request_url(_endpoint, _path), do: {:error, :invalid_configuration}

  defp safe_absolute_path?(path) do
    with true <- String.valid?(path),
         true <- String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
         true <- valid_percent_encoding?(path),
         decoded <- URI.decode(path),
         true <- String.valid?(decoded),
         true <- canonical_decoded_path?(decoded),
         %URI{
           scheme: nil,
           query: nil,
           fragment: nil,
           path: ^path
         } <- URI.parse(path) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_percent_encoding?(path) do
    ~r/%[0-9A-Fa-f]{2}/
    |> Regex.replace(path, "")
    |> then(&(not String.contains?(&1, "%")))
  end

  defp canonical_decoded_path?(path) do
    segments = String.split(path, "/", trim: false)

    not String.starts_with?(path, ["//", "/\\", "/@"]) and
      not String.contains?(path, ["\\", "//"]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/u, path) and
      Enum.all?(segments, &(&1 not in [".", ".."]))
  end

  defp same_origin?(left, right) do
    {left.scheme, left.host, left.port, left.userinfo} ==
      {right.scheme, right.host, right.port, right.userinfo}
  end

  defp endpoint_authorization(config, provider, request) do
    settings = value(config, :settings) || %{}
    endpoint = endpoint_value(settings, provider, request.path)

    with {:ok, endpoint} <- validate_endpoint(endpoint),
         {:ok, policy} <-
           EndpointPolicy.validate(endpoint,
             trusted_origins: trusted_origins(provider, settings),
             resolver: endpoint_resolver(settings)
           ),
         {:ok, url} <- request_url(endpoint, request.path) do
      EndpointPolicy.authorize(policy, url)
    end
  end

  defp endpoint_value(settings, :github, "/graphql") do
    value(settings, :graphql_base_url) || value(settings, :api_base_url) ||
      "https://api.github.com"
  end

  defp endpoint_value(settings, :github, _path) do
    value(settings, :api_base_url) || "https://api.github.com"
  end

  defp endpoint_value(settings, :gitlab, _path) do
    value(settings, :api_base_url) || "https://gitlab.com/api/v4"
  end

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _invalid ->
        {:error, :invalid_configuration}
    end
  end

  defp validate_endpoint(_endpoint), do: {:error, :invalid_configuration}

  defp trusted_origins(provider, settings) do
    value(settings, :endpoint_trusted_origins) || configured_trusted_origins(provider) ||
      default_trusted_origins(provider)
  end

  defp configured_trusted_origins(provider) do
    case Config.source_control_trusted_origins() do
      origins when is_map(origins) ->
        Map.get(origins, provider) || Map.get(origins, Atom.to_string(provider))

      _other ->
        nil
    end
  end

  defp default_trusted_origins(:github), do: ["https://api.github.com"]
  defp default_trusted_origins(:gitlab), do: ["https://gitlab.com"]

  defp endpoint_resolver(settings) do
    value(settings, :endpoint_resolver) ||
      Config.source_control_endpoint_resolver()
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end

defmodule SymphonyElixir.SourceControl.Transport.Git do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.ExecCommand
  alias SymphonyElixir.Tracker.EndpointPolicy

  @default_timeout_ms 30_000
  @owner_shutdown_grace_ms 6_000

  @spec push(map(), :github | :gitlab, String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :transport_failure | :invalid_configuration}
  def push(config, provider, branch, desired_sha, expected_sha, credential) do
    settings = value(config, :settings) || %{}
    workspace = value(settings, :workspace)
    remote_url = value(settings, :remote_url)
    repository = value(settings, :repository)
    timeout_ms = git_timeout_ms(settings)

    with true <- is_binary(workspace) and File.dir?(workspace),
         {:ok, remote_url} <- normalized_remote_url(remote_url, provider, repository),
         {:ok, remote_policy} <- remote_policy(remote_url, provider, settings),
         true <- safe_credential?(credential),
         true <- valid_branch?(branch),
         true <- valid_sha?(desired_sha) and valid_sha?(expected_sha),
         git when is_binary(git) <- System.find_executable("git"),
         true <- safe_local_config?(git, workspace, timeout_ms) do
      credential_host = host_header(EndpointPolicy.host(remote_policy), EndpointPolicy.port(remote_policy))

      helper =
        ~S/!f() { test "$1" = get || exit 0; protocol=; host=; / <>
          ~S/while IFS='=' read key value; do / <>
          ~S/test "$key" = protocol && protocol="$value"; / <>
          ~S/test "$key" = host && host="$value"; done; / <>
          ~S/test "$protocol" = https && test "$host" = "$SYMPHONY_GIT_HOST" || exit 0; / <>
          ~S/printf 'username=%s\npassword=%s\n' "$SYMPHONY_GIT_USERNAME" / <>
          ~S/"$SYMPHONY_GIT_CREDENTIAL"; }; f/

      args = [
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "credential.helper=",
        "-c",
        "credential.helper=#{helper}",
        "-c",
        "credential.useHttpPath=true",
        "-c",
        "credential.interactive=false",
        "-c",
        "http.followRedirects=false",
        "-c",
        "http.sslVerify=true",
        "-c",
        "http.curloptResolve=#{curlopt_resolve(remote_policy)}",
        "push",
        "--porcelain",
        "--force-with-lease=refs/heads/#{branch}:#{expected_sha}",
        remote_url,
        "#{desired_sha}:refs/heads/#{branch}"
      ]

      env = [
        {"GIT_TERMINAL_PROMPT", "0"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_ASKPASS", false},
        {"SSH_ASKPASS", nil},
        {"GIT_PROXY_COMMAND", nil},
        {"HTTP_PROXY", nil},
        {"HTTPS_PROXY", nil},
        {"ALL_PROXY", nil},
        {"http_proxy", nil},
        {"https_proxy", nil},
        {"all_proxy", nil},
        {"SYMPHONY_GIT_USERNAME", git_username(provider)},
        {"SYMPHONY_GIT_HOST", credential_host},
        {"SYMPHONY_GIT_CREDENTIAL", credential}
      ]

      case run_git_command(git, args, workspace, env, timeout_ms) do
        {:ok, %{status: 0}} -> :ok
        {:ok, %{status: _status}} -> {:error, :transport_failure}
        {:error, _reason} -> {:error, :transport_failure}
      end
    else
      _invalid -> {:error, :invalid_configuration}
    end
  rescue
    _exception -> {:error, :transport_failure}
  end

  if Mix.env() == :test do
    @doc false
    @spec run_owned_for_test((reference() -> term()), non_neg_integer()) :: term()
    def run_owned_for_test(run, timeout_ms), do: run_owned_git_command(run, timeout_ms)
  end

  defp git_username(:github), do: "x-access-token"
  defp git_username(:gitlab), do: "oauth2"

  defp safe_credential?(credential) when is_binary(credential) do
    credential != "" and String.valid?(credential) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, credential)
  end

  defp safe_credential?(_credential), do: false

  defp normalized_remote_url(url, provider, repository) when is_binary(url) do
    with {:ok, expected_path} <- expected_repository_path(provider, repository),
         {:ok, uri} <- strict_https_uri(url),
         {:ok, actual_path, git_suffix?} <- normalized_repository_path(uri.path),
         true <- actual_path == expected_path do
      suffix = if git_suffix?, do: ".git", else: ""
      {:ok, URI.to_string(%{uri | path: "/" <> actual_path <> suffix})}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp normalized_remote_url(_url, _provider, _repository), do: {:error, :invalid_configuration}

  defp strict_https_uri(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      } = uri
      when is_binary(host) and host != "" and is_binary(path) ->
        {:ok, uri}

      _invalid ->
        {:error, :invalid_configuration}
    end
  end

  defp normalized_repository_path(path) do
    with true <- String.valid?(path),
         true <- String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
         true <- valid_percent_encoding?(path),
         decoded <- URI.decode(path),
         true <- String.valid?(decoded),
         true <- canonical_repository_path?(decoded),
         trimmed <- String.trim_leading(decoded, "/"),
         {repository_path, git_suffix?} <- strip_git_suffix(trimmed),
         true <- canonical_repository_path?("/" <> repository_path) do
      {:ok, repository_path, git_suffix?}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp strip_git_suffix(path) do
    if String.ends_with?(path, ".git") do
      {String.trim_trailing(path, ".git"), true}
    else
      {path, false}
    end
  end

  defp canonical_repository_path?(path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.split("/", trim: false)

    not String.contains?(path, ["\\", "//"]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/u, path) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp expected_repository_path(:github, repository) when is_binary(repository) do
    case String.split(repository, "/") do
      [owner, name] ->
        if valid_repository_segment?(owner) and valid_repository_segment?(name) do
          {:ok, repository}
        else
          {:error, :invalid_configuration}
        end

      _other ->
        {:error, :invalid_configuration}
    end
  end

  defp expected_repository_path(:gitlab, repository) when is_binary(repository) do
    segments = String.split(repository, "/")

    if Enum.all?(segments, &valid_repository_segment?/1) do
      {:ok, repository}
    else
      {:error, :invalid_configuration}
    end
  end

  defp expected_repository_path(_provider, _repository), do: {:error, :invalid_configuration}

  defp valid_repository_segment?(segment) do
    is_binary(segment) and segment != "" and String.valid?(segment) and
      not String.ends_with?(segment, ".git") and
      not String.contains?(segment, ["\\", "?", "#", "%", ":"]) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/u, segment) and segment not in [".", ".."]
  end

  defp valid_percent_encoding?(path) do
    ~r/%[0-9A-Fa-f]{2}/
    |> Regex.replace(path, "")
    |> then(&(not String.contains?(&1, "%")))
  end

  defp remote_policy(url, provider, settings) when is_binary(url) do
    EndpointPolicy.validate(url,
      trusted_origins: git_trusted_origins(provider, settings),
      resolver: git_endpoint_resolver(settings)
    )
  end

  defp git_trusted_origins(provider, settings) do
    value(settings, :git_trusted_origins) || configured_git_trusted_origins(provider) ||
      default_git_trusted_origins(provider)
  end

  defp configured_git_trusted_origins(provider) do
    case Config.source_control_git_trusted_origins() do
      origins when is_map(origins) ->
        Map.get(origins, provider) || Map.get(origins, Atom.to_string(provider))

      _other ->
        nil
    end
  end

  defp default_git_trusted_origins(:github), do: ["https://github.com"]
  defp default_git_trusted_origins(:gitlab), do: ["https://gitlab.com"]

  defp git_endpoint_resolver(settings) do
    value(settings, :git_endpoint_resolver) ||
      Config.source_control_git_endpoint_resolver()
  end

  defp curlopt_resolve(policy) do
    "+#{EndpointPolicy.host(policy)}:#{EndpointPolicy.port(policy)}:#{address_text(EndpointPolicy.first_address(policy))}"
  end

  defp host_header(host, 443), do: authority_host(host)
  defp host_header(host, port), do: "#{authority_host(host)}:#{port}"

  defp authority_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  defp address_text(address), do: address |> :inet.ntoa() |> List.to_string()

  defp safe_local_config?(git, workspace, timeout_ms) do
    case run_git_command(
           git,
           ["config", "--local", "--name-only", "--list"],
           workspace,
           [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}],
           timeout_ms
         ) do
      {:ok, %{stdout: keys, status: 0}} ->
        keys
        |> String.split("\n", trim: true)
        |> Enum.all?(&(not dangerous_config_key?(&1)))

      {:ok, %{status: _status}} ->
        false

      {:error, _reason} ->
        false
    end
  end

  defp run_git_command(git, args, workspace, env, timeout_ms) do
    run_owned_git_command(
      fn caller_ref ->
        ExecCommand.run([git | args],
          cd: workspace,
          env: command_env(env),
          timeout_ms: timeout_ms,
          caller_ref: caller_ref
        )
      end,
      timeout_ms + @owner_shutdown_grace_ms
    )
  end

  defp run_owned_git_command(run, timeout_ms) when is_function(run, 1) do
    caller = self()
    result_ref = make_ref()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        caller_ref = Process.monitor(caller)
        send(caller, {result_ref, run.(caller_ref)})
      end)

    owner_ref = Process.monitor(owner)

    receive do
      {^result_ref, result} ->
        Process.demonitor(owner_ref, [:flush])
        result

      {:DOWN, ^owner_ref, :process, ^owner, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        Process.exit(owner, :kill)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
        end

        {:error, :timeout}
    end
  end

  defp command_env(overrides) do
    Enum.reduce(overrides, System.get_env(), fn
      {key, nil}, env -> Map.delete(env, key)
      {key, false}, env -> Map.delete(env, key)
      {key, value}, env -> Map.put(env, key, value)
    end)
    |> Map.to_list()
  end

  defp git_timeout_ms(settings) do
    case value(settings, :git_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms in 1..120_000 -> timeout_ms
      _other -> @default_timeout_ms
    end
  end

  defp dangerous_config_key?(key) do
    normalized = String.downcase(key)

    Enum.any?(
      [
        "include.",
        "url.",
        "http.",
        "credential.",
        "protocol.",
        "uploadpack.",
        "receive."
      ],
      &String.starts_with?(normalized, &1)
    ) or
      normalized in ["core.hookspath", "core.fsmonitor", "core.sshcommand"] or
      dangerous_remote_config_key?(normalized)
  end

  defp dangerous_remote_config_key?("remote." <> _name = key) do
    String.ends_with?(key, [".proxy", ".proxyauthmethod", ".vcs", ".uploadpack", ".receivepack"])
  end

  defp dangerous_remote_config_key?(_key), do: false

  defp valid_branch?(branch) when is_binary(branch) do
    Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/, branch) and
      not String.contains?(branch, ["..", "//", "@{"]) and
      not String.ends_with?(branch, ["/", ".lock"])
  end

  defp valid_branch?(_branch), do: false
  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, sha)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
