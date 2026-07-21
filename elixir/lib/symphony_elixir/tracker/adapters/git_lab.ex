defmodule SymphonyElixir.Tracker.Adapters.GitLab do
  @moduledoc false

  @behaviour SymphonyElixir.Tracker.Adapter

  alias SymphonyElixir.Tracker.Adapters.Support
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Transport

  @spec health_check(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def health_check(config, opts) do
    settings = Support.settings(config)
    headers = gitlab_headers(Keyword.fetch!(opts, :credential))

    project_request = %{method: :get, url: project_url(config), headers: headers}
    user_request = %{method: :get, url: api_url(config, "/user"), headers: headers}

    token_request = %{
      method: :get,
      url: api_url(config, "/personal_access_tokens/self"),
      headers: headers
    }

    issue_request = %{
      method: :get,
      url: project_url(config) <> "/issues",
      headers: headers,
      params: [state: "all", per_page: 1]
    }

    with {:ok, project_status, project} <- health_get(project_request, opts, :map),
         {:ok, scope} <- validate_project_health(project, settings),
         {:ok, _user_status, user} <- health_get(user_request, opts, :map),
         {:ok, bot_actor_id} <- validate_bot_identity(user, settings),
         {:ok, _token_status, token} <- health_get(token_request, opts, :map),
         :ok <- validate_write_token(token),
         {:ok, _issue_status, issues} <- health_get(issue_request, opts, :list),
         :ok <- validate_health_issues(issues) do
      {:ok,
       %{
         provider: "gitlab",
         status: :healthy,
         evidence: %{
           http_status: project_status,
           credentials: :verified,
           scope: :verified,
           scope_ref: scope,
           bot_actor_id: bot_actor_id,
           issue_read: :verified,
           state_mappings: :verified,
           comment_permissions: :verified
         }
       }}
    end
  end

  defp health_get(request, opts, expected_body) do
    case Transport.request(request, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if health_body?(body, expected_body), do: {:ok, status, body}, else: invalid_response()

      {:ok, %{status: status} = response} when status not in 200..299 ->
        Support.http_error("gitlab", response)

      {:ok, _response} ->
        invalid_response()

      {:error, _reason} ->
        Support.transport_error("gitlab")
    end
  end

  defp health_body?(body, :map), do: is_map(body)
  defp health_body?(body, :list), do: is_list(body)

  defp validate_project_health(project, settings) do
    configured_scope = settings |> Support.value(:project_id) |> to_string()
    project_id = project |> Map.get("id") |> to_string()
    project_path = Map.get(project, "path_with_namespace")
    scope = if is_binary(project_path), do: project_path, else: project_id
    issues_enabled? = Map.get(project, "issues_enabled", true) and Map.get(project, "issues_access_level") != "disabled"

    cond do
      configured_scope not in [project_id, project_path] ->
        invalid_response()

      not issues_enabled? ->
        forbidden_health()

      effective_access_level(project) < 10 ->
        forbidden_health()

      true ->
        {:ok, scope}
    end
  end

  defp validate_bot_identity(%{"id" => actor_id, "state" => "active"}, settings)
       when not is_nil(actor_id) do
    configured_actor_id = Support.value(settings, :bot_actor_id)

    if not is_nil(configured_actor_id) and to_string(actor_id) == to_string(configured_actor_id) do
      {:ok, to_string(actor_id)}
    else
      invalid_response()
    end
  end

  defp validate_bot_identity(_user, _settings), do: invalid_response()

  defp validate_write_token(%{"active" => true, "revoked" => false, "scopes" => scopes})
       when is_list(scopes) do
    if "api" in scopes, do: :ok, else: forbidden_health()
  end

  defp validate_write_token(_token), do: forbidden_health()

  defp validate_health_issues(issues) do
    if Enum.all?(issues, &health_issue?/1), do: :ok, else: invalid_response()
  end

  defp health_issue?(%{"iid" => iid, "state" => state}) do
    valid_external_id?(iid) and state in ["opened", "closed"]
  end

  defp health_issue?(_issue), do: false

  defp effective_access_level(project) do
    permissions = Map.get(project, "permissions", %{})

    [get_in(permissions, ["project_access", "access_level"]), get_in(permissions, ["group_access", "access_level"])]
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  @spec fetch_eligible(map(), map(), keyword()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_eligible(config, criteria, opts) do
    do_fetch_eligible(config, criteria, opts, 1, [], [])
  end

  @spec fetch_by_ids(map(), [String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_by_ids(config, issue_ids, opts) do
    Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, issues} ->
      case fetch_one(config, to_string(issue_id), opts) do
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
    header_source = %{headers: Support.value(request, :headers, %{})}
    webhook_id = Support.header(header_source, "webhook-id")
    timestamp = Support.header(header_source, "webhook-timestamp")
    signature = Support.header(header_source, "webhook-signature")
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, timestamp_integer} <- parse_webhook_timestamp(timestamp),
         :ok <- validate_webhook_age(timestamp_integer, now, opts),
         true <-
           valid_signature?(
             webhook_id,
             timestamp,
             body,
             signature,
             Keyword.fetch!(opts, :credential)
           ),
         {:ok, payload} <- Jason.decode(body) do
      normalize_signed_webhook(payload, webhook_id)
    else
      false ->
        {:error, Support.error("gitlab", :invalid_signature, false, "tracker webhook signature is invalid")}

      {:error, %{code: _code} = error} ->
        {:error, error}

      _other ->
        {:error, Support.error("gitlab", :invalid_webhook, false, "tracker webhook is invalid")}
    end
  rescue
    _exception ->
      {:error, Support.error("gitlab", :invalid_webhook, false, "tracker webhook is invalid")}
  end

  @spec transition_issue(map(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def transition_issue(config, issue_id, target_state, opts) do
    with {:ok, state, state_event, provider_state} <- normalized_transition(target_state) do
      request = %{
        method: :put,
        url: issue_url(config, issue_id),
        headers: gitlab_headers(Keyword.fetch!(opts, :credential)),
        body: %{state_event: state_event}
      }

      request
      |> Transport.request(opts)
      |> transition_result(issue_id, state, provider_state)
    end
  end

  defp transition_result({:ok, %{status: status, body: body}}, issue_id, state, provider_state)
       when status in 200..299 do
    if valid_transition_payload?(body, issue_id, provider_state) do
      {:ok, %{provider: "gitlab", issue_id: issue_id, state: state}}
    else
      invalid_response()
    end
  end

  defp transition_result({:ok, %{status: status} = response}, _issue_id, _state, _provider_state)
       when status not in 200..299,
       do: Support.http_error("gitlab", response)

  defp transition_result({:ok, _response}, _issue_id, _state, _provider_state), do: invalid_response()

  defp transition_result({:error, _reason}, _issue_id, _state, _provider_state),
    do: Support.transport_error("gitlab")

  @spec upsert_progress(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def upsert_progress(config, issue_id, progress, opts) do
    upsert_marker_note(config, issue_id, :progress, progress, opts)
  end

  @spec append_final_summary(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def append_final_summary(config, issue_id, summary, opts) do
    upsert_marker_note(config, issue_id, :final, summary, opts)
  end

  @spec do_fetch_eligible(map(), map(), keyword(), pos_integer(), [Issue.t()], [pos_integer()]) ::
          {:ok, [Issue.t()]} | {:error, map()}
  defp do_fetch_eligible(config, criteria, opts, page, acc, seen_pages) do
    max_pages = Keyword.get(opts, :max_pages, 100)

    if pagination_limit_reached?(page, seen_pages, max_pages) do
      pagination_limit_error()
    else
      seen_pages = [page | seen_pages]

      request = %{
        method: :get,
        url: project_url(config) <> "/issues",
        headers: gitlab_headers(Keyword.fetch!(opts, :credential)),
        params: [
          state: gitlab_state(Support.value(criteria, :states, [])),
          labels: Enum.join(Support.value(criteria, :required_labels, []), ","),
          per_page: 100,
          page: page
        ]
      }

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
    with {:ok, issues} <- normalize_issue_page(body, criteria) do
      continue_issue_pagination(response, config, criteria, opts, acc ++ issues, seen_pages)
    end
  end

  defp fetch_eligible_result({:ok, response}, _config, _criteria, _opts, _acc, _seen_pages),
    do: Support.http_error("gitlab", response)

  defp fetch_eligible_result({:error, _reason}, _config, _criteria, _opts, _acc, _seen_pages),
    do: Support.transport_error("gitlab")

  defp continue_issue_pagination(response, config, criteria, opts, issues, seen_pages) do
    case next_page(response) do
      nil -> {:ok, issues}
      next -> do_fetch_eligible(config, criteria, opts, next, issues, seen_pages)
    end
  end

  defp normalize_issue(issue) do
    assignee = Map.get(issue, "assignee") || %{}
    iid = Map.get(issue, "iid")
    state = normalize_issue_state(Map.get(issue, "state"))

    %Issue{
      id: to_string(iid),
      native_ref: %{provider: "gitlab", iid: iid},
      identifier: "##{iid}",
      title: Map.get(issue, "title"),
      description: Map.get(issue, "description"),
      state: state,
      url: Map.get(issue, "web_url"),
      assignee_id: assignee_id(assignee),
      labels: normalize_labels(Map.get(issue, "labels", [])),
      dispatchable: state == "open",
      created_at: parse_datetime(Map.get(issue, "created_at")),
      updated_at: parse_datetime(Map.get(issue, "updated_at"))
    }
  end

  defp normalize_issue_state("opened"), do: "open"
  defp normalize_issue_state("closed"), do: "closed"

  defp normalize_issue_page(body, criteria) do
    issue_payloads = Enum.reject(body, &change_request?/1)

    if Enum.all?(issue_payloads, &valid_issue_payload?/1) do
      {:ok,
       issue_payloads
       |> Enum.map(&normalize_issue/1)
       |> Enum.filter(&Support.eligible?(&1, criteria))}
    else
      invalid_response()
    end
  end

  defp fetch_one(config, issue_id, opts) do
    request = %{
      method: :get,
      url: issue_url(config, issue_id),
      headers: gitlab_headers(Keyword.fetch!(opts, :credential))
    }

    case Transport.request(request, opts) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        cond do
          change_request?(body) -> {:ok, nil}
          valid_issue_payload?(body) and requested_issue?(body, issue_id) -> {:ok, normalize_issue(body)}
          true -> invalid_response()
        end

      {:ok, response} ->
        Support.http_error("gitlab", response)

      {:error, _reason} ->
        Support.transport_error("gitlab")
    end
  end

  defp change_request?(issue) when is_map(issue) do
    Map.get(issue, "object_kind") == "merge_request" or Map.has_key?(issue, "merge_status")
  end

  defp change_request?(_issue), do: false

  defp valid_issue_payload?(%{"iid" => iid, "title" => title, "state" => state})
       when is_binary(title) and state in ["opened", "closed"] do
    valid_external_id?(iid)
  end

  defp valid_issue_payload?(_issue), do: false

  defp requested_issue?(%{"iid" => iid}, issue_id), do: to_string(iid) == to_string(issue_id)

  defp valid_transition_payload?(%{"iid" => iid, "state" => state} = issue, issue_id, target_state) do
    valid_issue_payload?(issue) and to_string(iid) == to_string(issue_id) and state == target_state
  end

  defp valid_transition_payload?(_issue, _issue_id, _target_state), do: false

  defp next_page(response) do
    case Integer.parse(Support.header(response, "x-next-page") || "") do
      {page, ""} when page > 0 -> page
      _other -> nil
    end
  end

  defp gitlab_state(states) do
    normalized = Enum.map(states, &(&1 |> to_string() |> String.downcase()))
    open? = Enum.any?(normalized, &(&1 in ["open", "opened"]))
    closed? = "closed" in normalized

    cond do
      open? and closed? -> "all"
      closed? -> "closed"
      true -> "opened"
    end
  end

  defp normalize_labels(labels) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp normalize_labels(_labels), do: []

  defp assignee_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp assignee_id(%{"username" => username}) when is_binary(username), do: username
  defp assignee_id(_assignee), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp parse_webhook_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {value, ""} -> {:ok, value}
      _other -> {:error, Support.error("gitlab", :invalid_webhook, false, "tracker webhook is invalid")}
    end
  end

  defp parse_webhook_timestamp(_timestamp) do
    {:error, Support.error("gitlab", :invalid_webhook, false, "tracker webhook is invalid")}
  end

  defp validate_webhook_age(timestamp, now, opts) do
    if abs(now - timestamp) <= Keyword.get(opts, :webhook_tolerance_seconds, 300) do
      :ok
    else
      {:error, Support.error("gitlab", :stale_webhook, false, "tracker webhook timestamp is stale")}
    end
  end

  defp valid_signature?(webhook_id, timestamp, body, signature, credential)
       when is_binary(webhook_id) and is_binary(timestamp) and is_binary(body) and is_binary(signature) do
    case signing_key(credential) do
      {:ok, signing_key} ->
        expected =
          :crypto.mac(:hmac, :sha256, signing_key, "#{webhook_id}.#{timestamp}.#{body}")
          |> Base.encode64()

        signature
        |> String.split(" ", trim: true)
        |> Enum.any?(&valid_signature_candidate?(&1, expected))

      :error ->
        false
    end
  end

  defp valid_signature?(_webhook_id, _timestamp, _body, _signature, _credential), do: false

  defp valid_signature_candidate?(candidate, expected) do
    case String.split(candidate, ",", parts: 2) do
      ["v1", encoded] -> Support.secure_compare(encoded, expected)
      _other -> false
    end
  end

  defp signing_key("whsec_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, signing_key} when byte_size(signing_key) > 0 -> {:ok, signing_key}
      _other -> :error
    end
  end

  defp signing_key(credential) when is_binary(credential) and credential != "", do: {:ok, credential}
  defp signing_key(_credential), do: :error

  defp normalize_signed_webhook(%{"object_kind" => "issue", "object_attributes" => issue}, webhook_id)
       when is_map(issue) do
    iid = Map.get(issue, "iid")

    if valid_external_id?(iid) do
      {:ok,
       %{
         provider: "gitlab",
         kind: webhook_kind(issue),
         action: Map.get(issue, "action"),
         issue_id: to_string(iid),
         reconciliation_key: "gitlab:#{webhook_id}"
       }}
    else
      {:error, Support.error("gitlab", :invalid_webhook, false, "tracker webhook is invalid")}
    end
  end

  defp normalize_signed_webhook(%{"object_kind" => "merge_request"}, webhook_id) do
    {:ok,
     %{
       provider: "gitlab",
       kind: :ignored,
       reason: :change_request,
       reconciliation_key: "gitlab:#{webhook_id}"
     }}
  end

  defp normalize_signed_webhook(_payload, _webhook_id) do
    {:error, Support.error("gitlab", :invalid_webhook, false, "tracker webhook is invalid")}
  end

  defp webhook_kind(issue) do
    state = issue |> Map.get("state") |> normalize_webhook_value()
    action = issue |> Map.get("action") |> normalize_webhook_value()

    if state in ["closed", "completed", "canceled", "cancelled", "done"] or
         action in ["close", "closed", "complete", "completed", "cancel", "canceled", "cancelled"] do
      :human_terminal
    else
      :issue
    end
  end

  defp normalize_webhook_value(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_webhook_value(_value), do: ""

  defp normalized_transition(state) when state in [:open, :opened, "open", "opened"],
    do: {:ok, "open", "reopen", "opened"}

  defp normalized_transition(state) when state in [:closed, "closed"],
    do: {:ok, "closed", "close", "closed"}

  defp normalized_transition(_state) do
    {:error, Support.error("gitlab", :unsupported_transition, false, "tracker transition is unsupported")}
  end

  defp upsert_marker_note(config, issue_id, kind, content, opts) do
    marker = "<!-- symphony-tracker:#{kind} issue=gitlab:#{issue_id} -->"
    bot_actor_id = config |> Support.settings() |> Support.value(:bot_actor_id)

    with {:ok, notes} <- fetch_notes(config, issue_id, opts, 1, [], []) do
      case Enum.find(notes, &(note_has_marker?(&1, marker) and owned_by?(&1, bot_actor_id))) do
        nil -> create_note(config, issue_id, marker, content, opts)
        note -> update_note(config, issue_id, note, marker, content, opts)
      end
    end
  end

  @spec fetch_notes(map(), String.t(), keyword(), pos_integer(), [map()], [pos_integer()]) ::
          {:ok, [map()]} | {:error, map()}
  defp fetch_notes(config, issue_id, opts, page, acc, seen_pages) do
    max_pages = Keyword.get(opts, :max_pages, 100)

    if pagination_limit_reached?(page, seen_pages, max_pages) do
      pagination_limit_error()
    else
      seen_pages = [page | seen_pages]

      request = %{
        method: :get,
        url: issue_url(config, issue_id) <> "/notes",
        headers: gitlab_headers(Keyword.fetch!(opts, :credential)),
        params: [per_page: 100, page: page]
      }

      request
      |> Transport.request(opts)
      |> notes_result(config, issue_id, opts, acc, seen_pages)
    end
  end

  defp notes_result({:ok, %{status: status, body: notes} = response}, config, issue_id, opts, acc, seen_pages)
       when status in 200..299 and is_list(notes) do
    if Enum.all?(notes, &valid_note_payload?/1) do
      continue_note_pagination(response, config, issue_id, opts, acc ++ notes, seen_pages)
    else
      invalid_response()
    end
  end

  defp notes_result({:ok, response}, _config, _issue_id, _opts, _acc, _seen_pages),
    do: Support.http_error("gitlab", response)

  defp notes_result({:error, _reason}, _config, _issue_id, _opts, _acc, _seen_pages),
    do: Support.transport_error("gitlab")

  defp continue_note_pagination(response, config, issue_id, opts, notes, seen_pages) do
    case next_page(response) do
      nil -> {:ok, notes}
      next -> fetch_notes(config, issue_id, opts, next, notes, seen_pages)
    end
  end

  defp create_note(config, issue_id, marker, content, opts) do
    request = %{
      method: :post,
      url: issue_url(config, issue_id) <> "/notes",
      headers: gitlab_headers(Keyword.fetch!(opts, :credential)),
      body: %{body: marker <> "\n" <> content}
    }

    note_result(request, issue_id, marker, :created, opts)
  end

  defp update_note(config, issue_id, note, marker, content, opts) do
    note_id = note |> Map.get("id") |> to_string()

    request = %{
      method: :put,
      url: issue_url(config, issue_id) <> "/notes/#{URI.encode(note_id, &URI.char_unreserved?/1)}",
      headers: gitlab_headers(Keyword.fetch!(opts, :credential)),
      body: %{body: marker <> "\n" <> content}
    }

    note_result(request, issue_id, marker, :updated, opts)
  end

  defp note_result(request, issue_id, marker, action, opts) do
    case Transport.request(request, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        valid_note_result(body, issue_id, marker, action)

      {:ok, response} ->
        Support.http_error("gitlab", response)

      {:error, _reason} ->
        Support.transport_error("gitlab")
    end
  end

  defp valid_note_result(%{"id" => note_id}, issue_id, marker, action) do
    if valid_external_id?(note_id) do
      external_id = to_string(note_id)

      {:ok,
       %{
         provider: "gitlab",
         issue_id: issue_id,
         action: action,
         external_id: external_id,
         external_comment_id: external_id,
         marker: marker
       }}
    else
      invalid_response()
    end
  end

  defp valid_note_result(_body, _issue_id, _marker, _action), do: invalid_response()

  defp note_has_marker?(%{"body" => body}, marker) do
    body
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim_trailing("\r")
    |> Kernel.==(marker)
  end

  defp valid_note_payload?(%{"id" => id, "body" => body, "author" => %{"id" => actor_id}})
       when is_binary(body),
       do: valid_external_id?(id) and valid_external_id?(actor_id)

  defp valid_note_payload?(_note), do: false

  defp owned_by?(%{"author" => %{"id" => actor_id}}, bot_actor_id),
    do: to_string(actor_id) == to_string(bot_actor_id)

  defp valid_external_id?(id) when is_integer(id), do: id > 0
  defp valid_external_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp valid_external_id?(_id), do: false

  defp pagination_limit_reached?(page, seen_pages, max_pages) do
    page in seen_pages or length(seen_pages) >= max_pages
  end

  defp pagination_limit_error do
    {:error,
     Support.error(
       "gitlab",
       :pagination_limit,
       false,
       "tracker provider pagination limit was exceeded"
     )}
  end

  defp invalid_response do
    {:error, Support.error("gitlab", :invalid_response, false, "tracker provider returned an invalid response")}
  end

  defp forbidden_health do
    {:error, Support.error("gitlab", :forbidden, false, "tracker provider denied the required capability")}
  end

  defp api_url(config, path) do
    endpoint = config |> Support.settings() |> Support.value(:endpoint, "https://gitlab.com/api/v4")
    String.trim_trailing(endpoint, "/") <> path
  end

  defp project_url(config) do
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://gitlab.com/api/v4")
    project_id = Support.value(settings, :project_id) |> URI.encode(&URI.char_unreserved?/1)
    String.trim_trailing(endpoint, "/") <> "/projects/#{project_id}"
  end

  defp issue_url(config, issue_id) do
    encoded_id = URI.encode(issue_id, &URI.char_unreserved?/1)
    project_url(config) <> "/issues/#{encoded_id}"
  end

  defp gitlab_headers(credential) do
    %{
      "accept" => "application/json",
      "private-token" => credential
    }
  end
end
