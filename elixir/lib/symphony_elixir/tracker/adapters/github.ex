defmodule SymphonyElixir.Tracker.Adapters.GitHub do
  @moduledoc false

  @behaviour SymphonyElixir.Tracker.Adapter

  alias SymphonyElixir.Tracker.Adapters.Support
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Transport

  @spec health_check(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def health_check(config, opts) do
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://api.github.com")
    owner = Support.value(settings, :owner)
    repository = Support.value(settings, :repository)
    bot_actor_id = Support.value(settings, :bot_actor_id)
    credential = Keyword.fetch!(opts, :credential)
    base_url = String.trim_trailing(endpoint, "/")
    encoded_owner = URI.encode(owner, &URI.char_unreserved?/1)
    encoded_repository = URI.encode(repository, &URI.char_unreserved?/1)
    repository_url = base_url <> "/repos/#{encoded_owner}/#{encoded_repository}"

    with {:ok, user} <-
           health_get(base_url <> "/user", credential, opts),
         :ok <- validate_health_identity(user, bot_actor_id),
         {:ok, repository_body} <- health_get(repository_url, credential, opts),
         :ok <- validate_health_scope(repository_body, owner, repository),
         :ok <- validate_comment_permission(repository_body),
         {:ok, issue_body} <-
           health_get(repository_url <> "/issues", credential, opts, params: [state: "all", per_page: 2]),
         {:ok, _issues} <- normalize_issue_list_response(issue_body) do
      {:ok,
       %{
         provider: "github",
         status: :healthy,
         evidence: %{
           http_status: 200,
           credentials: :verified,
           scope: :verified,
           configured_scope: "#{owner}/#{repository}",
           bot_actor_id: to_string(bot_actor_id),
           issue_read: :verified,
           state_mappings: :verified,
           comment_permissions: :verified
         }
       }}
    end
  end

  defp health_get(url, credential, opts, request_fields \\ []) do
    request =
      request_fields
      |> Map.new()
      |> Map.merge(%{method: :get, url: url, headers: github_headers(credential)})

    case Transport.request(request, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status} = response} when status not in 200..299 ->
        Support.http_error("github", response)

      {:ok, _response} ->
        invalid_response()

      {:error, _reason} ->
        Support.transport_error("github")
    end
  end

  defp validate_health_identity(%{"id" => id, "login" => login}, bot_actor_id)
       when is_binary(login) do
    cond do
      not valid_external_id?(id) or String.trim(login) == "" ->
        invalid_response()

      to_string(id) != to_string(bot_actor_id) ->
        {:error,
         Support.error(
           "github",
           :identity_mismatch,
           false,
           "tracker credential identity does not match the configured bot"
         )}

      true ->
        :ok
    end
  end

  defp validate_health_identity(_user, _bot_actor_id), do: invalid_response()

  defp validate_health_scope(%{"full_name" => full_name}, owner, repository)
       when is_binary(full_name) do
    expected = String.downcase("#{owner}/#{repository}")

    if String.downcase(full_name) == expected do
      :ok
    else
      {:error,
       Support.error(
         "github",
         :scope_mismatch,
         false,
         "tracker credential does not resolve the configured scope"
       )}
    end
  end

  defp validate_health_scope(_repository, _owner, _name), do: invalid_response()

  defp validate_comment_permission(%{"permissions" => permissions}) when is_map(permissions) do
    if Enum.any?(["triage", "push", "maintain", "admin"], &(Map.get(permissions, &1) == true)) do
      :ok
    else
      {:error,
       Support.error(
         "github",
         :forbidden,
         false,
         "tracker credential cannot write issue comments"
       )}
    end
  end

  defp validate_comment_permission(_repository), do: invalid_response()

  defp normalize_issue_list_response(body) when is_list(body) do
    case normalize_issue_list(body) do
      {:ok, issues} -> {:ok, issues}
      :error -> invalid_response()
    end
  end

  defp normalize_issue_list_response(_body), do: invalid_response()

  @spec fetch_eligible(map(), map(), keyword()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_eligible(config, criteria, opts) do
    do_fetch_eligible(config, criteria, opts, 1, [], [])
  end

  @spec fetch_by_ids(map(), [String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_by_ids(config, issue_ids, opts) do
    Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, issues} ->
      case fetch_one(config, issue_id, opts) do
        {:ok, nil} -> {:cont, {:ok, issues}}
        {:ok, issue} -> {:cont, {:ok, issues ++ [issue]}}
        {:error, %{code: :not_found}} -> {:cont, {:ok, issues}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec normalize_webhook(map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def normalize_webhook(_config, request, opts) do
    body = Support.value(request, :body)
    headers = normalize_header_map(Support.value(request, :headers, %{}))
    signature = Map.get(headers, "x-hub-signature-256", "")
    credential = Keyword.fetch!(opts, :credential)

    with :ok <- validate_webhook_headers(headers) do
      expected_signature =
        "sha256=" <> (:crypto.mac(:hmac, :sha256, credential, body) |> Base.encode16(case: :lower))

      if secure_compare(signature, expected_signature) do
        normalize_signed_webhook(headers, body, body_digest(body))
      else
        {:error, Support.error("github", :invalid_signature, false, "tracker webhook signature is invalid")}
      end
    end
  rescue
    _exception ->
      {:error, Support.error("github", :invalid_webhook, false, "tracker webhook is invalid")}
  end

  @spec transition_issue(map(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def transition_issue(config, issue_id, target_state, opts) do
    with {:ok, github_state} <- normalized_github_state(target_state) do
      config
      |> transition_request(issue_id, github_state, opts)
      |> Transport.request(opts)
      |> transition_result(issue_id, github_state)
    end
  end

  defp transition_request(config, issue_id, github_state, opts) do
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://api.github.com")
    owner = URI.encode(Support.value(settings, :owner), &URI.char_unreserved?/1)
    repository = URI.encode(Support.value(settings, :repository), &URI.char_unreserved?/1)
    encoded_id = URI.encode(issue_id, &URI.char_unreserved?/1)

    %{
      method: :patch,
      url:
        String.trim_trailing(endpoint, "/") <>
          "/repos/#{owner}/#{repository}/issues/#{encoded_id}",
      headers: github_headers(Keyword.fetch!(opts, :credential)),
      body: %{state: github_state}
    }
  end

  defp transition_result({:ok, %{status: status, body: body}}, issue_id, github_state)
       when status in 200..299 and is_map(body) do
    if valid_transition_payload?(body, issue_id, github_state) do
      {:ok, %{provider: "github", issue_id: issue_id, state: github_state}}
    else
      invalid_response()
    end
  end

  defp transition_result({:ok, %{status: status} = response}, _issue_id, _github_state)
       when status not in 200..299,
       do: Support.http_error("github", response)

  defp transition_result({:ok, _response}, _issue_id, _github_state), do: invalid_response()

  defp transition_result({:error, _reason}, _issue_id, _github_state), do: Support.transport_error("github")

  @spec upsert_progress(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def upsert_progress(config, issue_id, progress, opts) do
    upsert_marker_comment(config, issue_id, :progress, progress, opts)
  end

  @spec append_final_summary(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def append_final_summary(config, issue_id, summary, opts) do
    upsert_marker_comment(config, issue_id, :final, summary, opts)
  end

  @spec do_fetch_eligible(map(), map(), keyword(), pos_integer(), [Issue.t()], [pos_integer()]) ::
          {:ok, [Issue.t()]} | {:error, map()}
  defp do_fetch_eligible(config, criteria, opts, page, acc, seen_pages) do
    max_pages = Keyword.get(opts, :max_pages, 100)

    if pagination_limit_reached?(page, seen_pages, max_pages) do
      pagination_limit_error()
    else
      seen_pages = [page | seen_pages]
      request = issues_request(config, criteria, opts, page)

      request
      |> Transport.request(opts)
      |> fetch_eligible_result(config, criteria, opts, acc, seen_pages)
    end
  end

  defp fetch_eligible_result(
         {:ok, %{status: status, body: body} = response},
         config,
         criteria,
         opts,
         acc,
         seen_pages
       )
       when status in 200..299 and is_list(body) do
    case normalize_issue_list(body) do
      {:ok, normalized} ->
        issues = Enum.filter(normalized, &Support.eligible?(&1, criteria))
        continue_issue_pagination(response, config, criteria, opts, acc ++ issues, seen_pages)

      :error ->
        invalid_response()
    end
  end

  defp fetch_eligible_result({:ok, %{status: status} = response}, _config, _criteria, _opts, _acc, _seen_pages)
       when status not in 200..299,
       do: Support.http_error("github", response)

  defp fetch_eligible_result({:ok, _response}, _config, _criteria, _opts, _acc, _seen_pages),
    do: invalid_response()

  defp fetch_eligible_result({:error, _reason}, _config, _criteria, _opts, _acc, _seen_pages),
    do: Support.transport_error("github")

  defp continue_issue_pagination(response, config, criteria, opts, issues, seen_pages) do
    case next_page(response) do
      nil -> {:ok, issues}
      next_page -> do_fetch_eligible(config, criteria, opts, next_page, issues, seen_pages)
    end
  end

  defp issues_request(config, criteria, opts, page) do
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://api.github.com")
    owner = URI.encode(Support.value(settings, :owner), &URI.char_unreserved?/1)
    repository = URI.encode(Support.value(settings, :repository), &URI.char_unreserved?/1)
    states = Support.value(criteria, :states, [])
    labels = Support.value(criteria, :required_labels, [])

    %{
      method: :get,
      url: String.trim_trailing(endpoint, "/") <> "/repos/#{owner}/#{repository}/issues",
      headers: github_headers(Keyword.fetch!(opts, :credential)),
      params: [
        state: github_state(states),
        labels: Enum.join(labels, ","),
        per_page: 100,
        page: page
      ]
    }
  end

  defp fetch_one(config, issue_id, opts) do
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://api.github.com")
    owner = URI.encode(Support.value(settings, :owner), &URI.char_unreserved?/1)
    repository = URI.encode(Support.value(settings, :repository), &URI.char_unreserved?/1)
    encoded_id = issue_id |> to_string() |> URI.encode(&URI.char_unreserved?/1)

    request = %{
      method: :get,
      url: String.trim_trailing(endpoint, "/") <> "/repos/#{owner}/#{repository}/issues/#{encoded_id}",
      headers: github_headers(Keyword.fetch!(opts, :credential))
    }

    request
    |> Transport.request(opts)
    |> fetch_one_result(issue_id)
  end

  defp fetch_one_result({:ok, %{status: status, body: body}}, issue_id)
       when status in 200..299 and is_map(body) do
    github_issue_result(body, issue_id)
  end

  defp fetch_one_result({:ok, %{status: status}}, _issue_id) when status in 200..299,
    do: invalid_response()

  defp fetch_one_result({:ok, response}, _issue_id), do: Support.http_error("github", response)

  defp fetch_one_result({:error, _reason}, _issue_id), do: Support.transport_error("github")

  defp github_issue_result(%{"pull_request" => _pull_request}, _issue_id), do: {:ok, nil}

  defp github_issue_result(body, issue_id) do
    if requested_issue_payload?(body, issue_id) do
      {:ok, normalize_issue(body)}
    else
      invalid_response()
    end
  end

  defp github_state(states) do
    normalized = states |> Enum.map(&(&1 |> to_string() |> String.downcase())) |> Enum.uniq()

    cond do
      normalized == ["closed"] -> "closed"
      "open" in normalized and "closed" in normalized -> "all"
      true -> "open"
    end
  end

  defp next_page(response) do
    case Support.header(response, "link") do
      nil ->
        nil

      link ->
        case Regex.run(~r/[?&]page=(\d+)[^>]*>;\s*rel="next"/, link, capture: :all_but_first) do
          [page] -> String.to_integer(page)
          _other -> nil
        end
    end
  end

  defp normalize_issue(issue) do
    number = Map.get(issue, "number")
    assignee = Map.get(issue, "assignee") || %{}

    %Issue{
      id: to_string(number),
      native_ref: %{provider: "github", number: number},
      identifier: "##{number}",
      title: Map.get(issue, "title"),
      description: Map.get(issue, "body"),
      state: Map.get(issue, "state"),
      url: Map.get(issue, "html_url"),
      assignee_id: assignee_id(assignee),
      labels: normalize_labels(Map.get(issue, "labels", [])),
      dispatchable: Map.get(issue, "state") == "open",
      created_at: parse_datetime(Map.get(issue, "created_at")),
      updated_at: parse_datetime(Map.get(issue, "updated_at"))
    }
  end

  defp normalize_issue_list(issues) do
    Enum.reduce_while(issues, {:ok, []}, fn
      %{"pull_request" => _pull_request}, {:ok, normalized} ->
        {:cont, {:ok, normalized}}

      issue, {:ok, normalized} ->
        if valid_issue_payload?(issue) do
          {:cont, {:ok, normalized ++ [normalize_issue(issue)]}}
        else
          {:halt, :error}
        end
    end)
  end

  defp valid_issue_payload?(issue) when is_map(issue) do
    is_integer(Map.get(issue, "number")) and Map.get(issue, "number") > 0 and
      is_binary(Map.get(issue, "title")) and Map.get(issue, "state") in ["open", "closed"] and
      is_list(Map.get(issue, "labels")) and is_binary(Map.get(issue, "html_url"))
  end

  defp valid_issue_payload?(_issue), do: false

  defp requested_issue_payload?(body, issue_id) do
    valid_issue_payload?(body) and to_string(Map.get(body, "number")) == to_string(issue_id)
  end

  defp valid_transition_payload?(body, issue_id, github_state) do
    not Map.has_key?(body, "pull_request") and requested_issue_payload?(body, issue_id) and
      Map.get(body, "state") == github_state
  end

  defp normalize_labels(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _other -> []
    end)
  end

  defp assignee_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp assignee_id(%{"login" => login}) when is_binary(login), do: login
  defp assignee_id(_assignee), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_signed_webhook(headers, body, digest) do
    with "issues" <- Map.get(headers, "x-github-event"),
         {:ok, payload} <- Jason.decode(body),
         %{} = issue <- Map.get(payload, "issue"),
         number when is_integer(number) and number > 0 <- Map.get(issue, "number"),
         action when is_binary(action) <- Map.get(payload, "action") do
      signed_webhook_result(headers, issue, number, action, digest)
    else
      _other ->
        {:error, Support.error("github", :invalid_webhook, false, "tracker webhook is invalid")}
    end
  end

  defp signed_webhook_result(headers, %{"pull_request" => _pull_request}, _number, _action, digest) do
    {:ok,
     %{
       provider: "github",
       kind: :ignored,
       reason: :change_request,
       delivery_id: Map.fetch!(headers, "x-github-delivery"),
       reconciliation_key: reconciliation_key(digest)
     }}
  end

  defp signed_webhook_result(headers, issue, number, action, digest) do
    signal = %{
      provider: "github",
      kind: :issue,
      action: action,
      issue_id: to_string(number),
      delivery_id: Map.fetch!(headers, "x-github-delivery"),
      reconciliation_key: reconciliation_key(digest)
    }

    if Map.get(issue, "state") == "closed" or action == "closed" do
      {:ok, Map.merge(signal, %{kind: :human_terminal, state: "closed"})}
    else
      {:ok, signal}
    end
  end

  defp reconciliation_key(digest), do: "github:sha256:" <> digest

  defp body_digest(body) do
    :sha256
    |> :crypto.hash(body)
    |> Base.encode16(case: :lower)
  end

  defp validate_webhook_headers(headers) do
    if nonblank_header?(headers, "x-github-event") and
         nonblank_header?(headers, "x-github-delivery") do
      :ok
    else
      {:error, Support.error("github", :invalid_webhook, false, "tracker webhook is invalid")}
    end
  end

  defp nonblank_header?(headers, name) do
    case Map.get(headers, name) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp normalize_header_map(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {key |> to_string() |> String.downcase(), to_string(value)} end)
  end

  defp normalize_header_map(_headers), do: %{}

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp normalized_github_state(state) when state in [:open, "open"], do: {:ok, "open"}
  defp normalized_github_state(state) when state in [:closed, "closed"], do: {:ok, "closed"}

  defp normalized_github_state(_state) do
    {:error, Support.error("github", :unsupported_transition, false, "tracker transition is unsupported")}
  end

  defp upsert_marker_comment(config, issue_id, marker_kind, content, opts) do
    marker = marker(marker_kind, issue_id)
    bot_actor_id = config |> Support.settings() |> Support.value(:bot_actor_id)

    with {:ok, comments} <- list_comments(config, issue_id, opts) do
      case Enum.find(comments, &(comment_has_marker?(&1, marker) and owned_by?(&1, bot_actor_id))) do
        nil -> create_comment(config, issue_id, marker, content, opts)
        comment -> update_comment(config, issue_id, comment, marker, content, opts)
      end
    end
  end

  defp list_comments(config, issue_id, opts) do
    do_list_comments(config, issue_id, opts, 1, [], [])
  end

  @spec do_list_comments(map(), String.t(), keyword(), pos_integer(), [map()], [pos_integer()]) ::
          {:ok, [map()]} | {:error, map()}
  defp do_list_comments(config, issue_id, opts, page, acc, seen_pages) do
    max_pages = Keyword.get(opts, :max_pages, 100)

    if pagination_limit_reached?(page, seen_pages, max_pages) do
      pagination_limit_error()
    else
      seen_pages = [page | seen_pages]

      request = %{
        method: :get,
        url: issue_url(config, issue_id) <> "/comments",
        headers: github_headers(Keyword.fetch!(opts, :credential)),
        params: [per_page: 100, page: page]
      }

      request
      |> Transport.request(opts)
      |> comments_result(config, issue_id, opts, acc, seen_pages)
    end
  end

  defp comments_result(
         {:ok, %{status: status, body: comments} = response},
         config,
         issue_id,
         opts,
         acc,
         seen_pages
       )
       when status in 200..299 and is_list(comments) do
    if Enum.all?(comments, &valid_comment_payload?/1) do
      continue_comment_pagination(response, config, issue_id, opts, acc ++ comments, seen_pages)
    else
      invalid_response()
    end
  end

  defp comments_result({:ok, %{status: status} = response}, _config, _issue_id, _opts, _acc, _seen_pages)
       when status not in 200..299,
       do: Support.http_error("github", response)

  defp comments_result({:ok, _response}, _config, _issue_id, _opts, _acc, _seen_pages),
    do: invalid_response()

  defp comments_result({:error, _reason}, _config, _issue_id, _opts, _acc, _seen_pages),
    do: Support.transport_error("github")

  defp continue_comment_pagination(response, config, issue_id, opts, comments, seen_pages) do
    case next_page(response) do
      nil -> {:ok, comments}
      next -> do_list_comments(config, issue_id, opts, next, comments, seen_pages)
    end
  end

  defp create_comment(config, issue_id, marker, content, opts) do
    request = %{
      method: :post,
      url: issue_url(config, issue_id) <> "/comments",
      headers: github_headers(Keyword.fetch!(opts, :credential)),
      body: %{body: marker <> "\n" <> content}
    }

    comment_result(request, issue_id, marker, :created, opts)
  end

  defp update_comment(config, issue_id, comment, marker, content, opts) do
    comment_id = comment |> Map.get("id") |> to_string()
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://api.github.com")
    owner = URI.encode(Support.value(settings, :owner), &URI.char_unreserved?/1)
    repository = URI.encode(Support.value(settings, :repository), &URI.char_unreserved?/1)

    request = %{
      method: :patch,
      url:
        String.trim_trailing(endpoint, "/") <>
          "/repos/#{owner}/#{repository}/issues/comments/#{comment_id}",
      headers: github_headers(Keyword.fetch!(opts, :credential)),
      body: %{body: marker <> "\n" <> content}
    }

    comment_result(request, issue_id, marker, :updated, opts)
  end

  defp comment_result(request, issue_id, marker, action, opts) do
    case Transport.request(request, opts) do
      {:ok, %{status: status, body: %{"id" => comment_id}}} when status in 200..299 ->
        if valid_external_id?(comment_id) do
          external_id = to_string(comment_id)

          {:ok,
           %{
             provider: "github",
             issue_id: issue_id,
             action: action,
             external_id: external_id,
             external_comment_id: external_id,
             marker: marker
           }}
        else
          invalid_response()
        end

      {:ok, response} ->
        Support.http_error("github", response)

      {:error, _reason} ->
        Support.transport_error("github")
    end
  end

  defp issue_url(config, issue_id) do
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://api.github.com")
    owner = URI.encode(Support.value(settings, :owner), &URI.char_unreserved?/1)
    repository = URI.encode(Support.value(settings, :repository), &URI.char_unreserved?/1)
    encoded_id = URI.encode(issue_id, &URI.char_unreserved?/1)

    String.trim_trailing(endpoint, "/") <> "/repos/#{owner}/#{repository}/issues/#{encoded_id}"
  end

  defp marker(kind, issue_id), do: "<!-- symphony-tracker:#{kind} issue=github:#{issue_id} -->"

  defp comment_has_marker?(comment, marker) do
    comment
    |> Map.fetch!("body")
    |> String.split(~r/\r?\n/, parts: 2)
    |> List.first()
    |> Kernel.==(marker)
  end

  defp owned_by?(comment, bot_actor_id) when not is_nil(bot_actor_id) do
    comment
    |> get_in(["user", "id"])
    |> to_string()
    |> Kernel.==(to_string(bot_actor_id))
  end

  defp owned_by?(_comment, _bot_actor_id), do: false

  defp valid_comment_payload?(%{"id" => id, "body" => body, "user" => %{"id" => actor_id}})
       when is_binary(body) do
    valid_external_id?(id) and valid_external_id?(actor_id)
  end

  defp valid_comment_payload?(_comment), do: false

  defp valid_external_id?(id) when is_integer(id), do: id > 0
  defp valid_external_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp valid_external_id?(_id), do: false

  defp pagination_limit_reached?(page, seen_pages, max_pages) do
    page in seen_pages or length(seen_pages) >= max_pages
  end

  defp pagination_limit_error do
    {:error,
     Support.error(
       "github",
       :pagination_limit,
       false,
       "tracker provider pagination limit was exceeded"
     )}
  end

  defp github_headers(credential) do
    %{
      "accept" => "application/vnd.github+json",
      "authorization" => "Bearer #{credential}",
      "x-github-api-version" => "2022-11-28"
    }
  end

  defp invalid_response do
    {:error, Support.error("github", :invalid_response, false, "tracker provider returned an invalid response")}
  end
end
