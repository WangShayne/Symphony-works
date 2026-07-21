defmodule SymphonyElixir.Tracker.EndpointPolicy do
  @moduledoc """
  Validates credential-bearing tracker endpoints and pins their network target.

  Trusted origins come from operator-controlled runtime configuration, separate
  from dashboard-editable integration endpoints.
  """

  @enforce_keys [:scheme, :host, :port, :base_path, :addresses]
  defstruct [:scheme, :host, :port, :base_path, :addresses]

  @opaque t :: %__MODULE__{
            scheme: String.t(),
            host: String.t(),
            port: :inet.port_number(),
            base_path: String.t(),
            addresses: [:inet.ip_address()]
          }

  @type authorization :: %{
          address: :inet.ip_address(),
          host_header: String.t(),
          hostname: String.t(),
          url: URI.t()
        }

  @local_suffixes [".localhost", ".local", ".localdomain", ".internal", ".lan", ".home", ".home.arpa"]
  @dns_label ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/
  @control_characters ~r/[\x00-\x1F\x7F]/

  @type error :: :invalid_endpoint | :untrusted_origin | :resolution_failed | :unsafe_address

  @spec validate(String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def validate(endpoint, opts) when is_binary(endpoint) and is_list(opts) do
    with {:ok, uri} <- parse_endpoint(endpoint),
         :ok <- require_trusted_origin(uri, Keyword.get(opts, :trusted_origins, [])),
         {:ok, addresses} <- resolve(uri.host, Keyword.get(opts, :resolver, &:inet.getaddrs/2)),
         :ok <- require_public_addresses(addresses) do
      {:ok,
       %__MODULE__{
         scheme: uri.scheme,
         host: canonical_host(uri.host),
         port: uri.port,
         base_path: normalize_path(uri.path),
         addresses: Enum.sort_by(addresses, &address_text/1)
       }}
    end
  rescue
    _exception -> {:error, :invalid_endpoint}
  catch
    _kind, _reason -> {:error, :invalid_endpoint}
  end

  def validate(_endpoint, _opts), do: {:error, :invalid_endpoint}

  @spec host(t()) :: String.t()
  def host(%__MODULE__{host: host}), do: host

  @spec port(t()) :: :inet.port_number()
  def port(%__MODULE__{port: port}), do: port

  @spec first_address(t()) :: :inet.ip_address()
  def first_address(%__MODULE__{addresses: [address | _rest]}), do: address

  @spec authorize(t(), String.t()) :: {:ok, authorization()} | {:error, error()}
  def authorize(%__MODULE__{} = policy, request_url) when is_binary(request_url) do
    with {:ok, uri} <- parse_request_url(request_url),
         :ok <- require_policy_origin(policy, uri),
         :ok <- require_policy_path(policy, uri.path) do
      [address | _rest] = policy.addresses

      {:ok,
       %{
         address: address,
         hostname: policy.host,
         host_header: host_header(policy.host, policy.port),
         url: %{uri | host: address_text(address)}
       }}
    end
  end

  def authorize(_policy, _request_url), do: {:error, :invalid_endpoint}

  defp parse_endpoint(endpoint) do
    with true <- endpoint == String.trim(endpoint),
         {:ok, %URI{} = uri} <- URI.new(endpoint),
         true <- uri.scheme == "https",
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         {:ok, host} <- validate_host(uri.host),
         :ok <- require_canonical_base_path(uri.path) do
      {:ok, %{uri | host: host}}
    else
      _other -> {:error, :invalid_endpoint}
    end
  end

  defp parse_request_url(url) do
    with {:ok, %URI{} = uri} <- URI.new(url),
         true <- uri.scheme == "https",
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         {:ok, host} <- validate_host(uri.host) do
      {:ok, %{uri | host: host}}
    else
      _other -> {:error, :invalid_endpoint}
    end
  end

  defp require_trusted_origin(uri, trusted_origins) when is_list(trusted_origins) do
    if Enum.any?(trusted_origins, &(trusted_origin(&1) == origin(uri))) do
      :ok
    else
      {:error, :untrusted_origin}
    end
  end

  defp require_trusted_origin(_uri, _trusted_origins), do: {:error, :untrusted_origin}

  defp trusted_origin(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{} = uri}
      when uri.scheme == "https" and is_integer(uri.port) and uri.port in 1..65_535 ->
        with true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
             true <- normalize_path(uri.path) == "/",
             {:ok, host} <- validate_host(uri.host) do
          origin(%{uri | host: host})
        else
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp trusted_origin(_value), do: nil

  defp require_policy_origin(policy, uri) do
    if {uri.scheme, canonical_host(uri.host), uri.port} ==
         {policy.scheme, policy.host, policy.port} do
      :ok
    else
      {:error, :untrusted_origin}
    end
  end

  defp require_policy_path(%__MODULE__{base_path: base_path}, path) do
    require_safe_path_layers(normalize_path(path), base_path)
  end

  defp require_safe_path_layers(path, base_path) do
    with :ok <- require_path_under_base(path, base_path),
         :ok <- require_safe_path_shape(path),
         {:ok, decoded_path} <- decode_path(path) do
      decoded_path = normalize_path(decoded_path)

      if decoded_path == path do
        :ok
      else
        require_safe_path_layers(decoded_path, base_path)
      end
    end
  end

  defp require_path_under_base(_path, "/"), do: :ok

  defp require_path_under_base(path, base_path) do
    if path == base_path or String.starts_with?(path, base_path <> "/") do
      :ok
    else
      {:error, :untrusted_origin}
    end
  end

  defp require_canonical_base_path(path) do
    path = normalize_path(path)

    with :ok <- require_safe_path_shape(path),
         {:ok, decoded_path} <- decode_path(path),
         true <- decoded_path == path do
      :ok
    else
      _other -> {:error, :invalid_endpoint}
    end
  end

  defp require_safe_path_shape(path) do
    segments = String.split(path, "/", trim: false)

    if String.valid?(path) and not String.contains?(path, "\\") and
         not Regex.match?(@control_characters, path) and
         not Enum.any?(segments, &(&1 in [".", ".."])) do
      :ok
    else
      {:error, :untrusted_origin}
    end
  end

  defp decode_path(path), do: {:ok, URI.decode(path)}

  defp resolve(host, resolver) when is_function(resolver, 1) or is_function(resolver, 2) do
    case parse_address(host) do
      {:ok, address} ->
        {:ok, [address]}

      :error ->
        resolve_dns(host, resolver)
    end
  end

  defp resolve(_host, _resolver), do: {:error, :resolution_failed}

  defp resolve_dns(host, resolver) when is_function(resolver, 1) do
    normalize_resolution(resolver.(host))
  end

  defp resolve_dns(host, resolver) when is_function(resolver, 2) do
    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case resolver.(String.to_charlist(host), family) do
          {:ok, resolved} -> resolved
          {:error, _reason} -> []
        end
      end)

    normalize_resolution({:ok, addresses})
  end

  defp normalize_resolution({:ok, addresses}) when is_list(addresses) and addresses != [],
    do: {:ok, Enum.uniq(addresses)}

  defp normalize_resolution(_result), do: {:error, :resolution_failed}

  defp require_public_addresses(addresses) do
    if Enum.all?(addresses, &public_address?/1), do: :ok, else: {:error, :unsafe_address}
  end

  defp public_address?({a, b, c, d})
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not reserved_ipv4?(a, b, c)
  end

  defp public_address?({0, 0, 0, 0, 0, 65_535, g, h}) do
    public_address?({div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)})
  end

  defp public_address?({a, b, c, d, e, f, g, h})
       when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
              e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    not reserved_ipv6?(a, b)
  end

  defp public_address?(_address), do: false

  defp reserved_ipv4?(0, _b, _c), do: true
  defp reserved_ipv4?(10, _b, _c), do: true
  defp reserved_ipv4?(100, b, _c) when b in 64..127, do: true
  defp reserved_ipv4?(127, _b, _c), do: true
  defp reserved_ipv4?(169, 254, _c), do: true
  defp reserved_ipv4?(172, b, _c) when b in 16..31, do: true
  defp reserved_ipv4?(192, 0, _c), do: true
  defp reserved_ipv4?(192, 88, 99), do: true
  defp reserved_ipv4?(192, 168, _c), do: true
  defp reserved_ipv4?(198, b, _c) when b in 18..19, do: true
  defp reserved_ipv4?(198, 51, 100), do: true
  defp reserved_ipv4?(203, 0, 113), do: true
  defp reserved_ipv4?(a, _b, _c) when a >= 224, do: true
  defp reserved_ipv4?(_a, _b, _c), do: false

  defp reserved_ipv6?(0, _b), do: true
  defp reserved_ipv6?(a, _b) when a in 0xFC00..0xFDFF, do: true
  defp reserved_ipv6?(a, _b) when a in 0xFE80..0xFEBF, do: true
  defp reserved_ipv6?(a, _b) when a in 0xFF00..0xFFFF, do: true
  defp reserved_ipv6?(a, _b) when a not in 0x2000..0x3FFF, do: true
  defp reserved_ipv6?(0x2001, b) when b in [0x0000, 0x0002, 0x000D, 0x0DB8], do: true
  defp reserved_ipv6?(0x2002, _b), do: true
  defp reserved_ipv6?(_a, _b), do: false

  defp origin(%URI{} = uri), do: {uri.scheme, canonical_host(uri.host), uri.port}

  defp normalize_path(path) when path in [nil, "", "/"], do: "/"
  defp normalize_path(path), do: String.trim_trailing(path, "/")

  defp validate_host(host) when is_binary(host) and host != "" do
    host = canonical_host(host)

    cond do
      String.contains?(host, ["%", "\\", "\0", "\r", "\n", "\t", " "]) ->
        {:error, :invalid_endpoint}

      String.ends_with?(host, ".") ->
        {:error, :invalid_endpoint}

      match?({:ok, _address}, parse_address(host)) ->
        {:ok, host}

      local_name?(host) or obfuscated_ip?(host) ->
        {:error, :invalid_endpoint}

      valid_dns_name?(host) ->
        {:ok, host}

      true ->
        {:error, :invalid_endpoint}
    end
  end

  defp validate_host(_host), do: {:error, :invalid_endpoint}

  defp local_name?(host) do
    not String.contains?(host, ".") or
      Enum.any?(@local_suffixes, &(host == String.trim_leading(&1, ".") or String.ends_with?(host, &1)))
  end

  defp obfuscated_ip?(host) do
    parts = String.split(host, ".")

    Enum.all?(parts, fn part ->
      Regex.match?(~r/^(?:0x[0-9a-f]+|[0-9]+)$/i, part)
    end)
  end

  defp valid_dns_name?(host) when byte_size(host) <= 253 do
    labels = String.split(host, ".")
    length(labels) >= 2 and Enum.all?(labels, &(byte_size(&1) <= 63 and Regex.match?(@dns_label, &1)))
  end

  defp valid_dns_name?(_host), do: false

  defp parse_address(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp canonical_host(host), do: String.downcase(host)

  defp host_header(host, port) do
    authority_host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == 443, do: authority_host, else: "#{authority_host}:#{port}"
  end

  defp address_text(address), do: address |> :inet.ntoa() |> List.to_string()
end
