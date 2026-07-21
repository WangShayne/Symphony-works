defmodule SymphonyElixir.Tracker.Adapters.Linear do
  @moduledoc false

  @behaviour SymphonyElixir.Tracker.Adapter

  alias SymphonyElixir.Tracker.Adapters.Support
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Transport

  @health_query """
  query SymphonyTrackerHealth($projectSlug: String!) {
    viewer { id }
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes { id slugId }
    }
    issues(filter: {project: {slugId: {eq: $projectSlug}}}, first: 1) {
      nodes {
        id
        state { id name type }
        comments(first: 1) { nodes { id } }
      }
    }
    workflowStates(first: 250) {
      nodes { id name type }
    }
    commentCreateCapability: __type(name: "Mutation") {
      fields(includeDeprecated: false) { name }
    }
  }
  """
  @issues_query """
  query SymphonyTrackerPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id identifier title description priority branchName url createdAt updatedAt
        state { name type }
        assignee { id }
        labels { nodes { name } }
        inverseRelations(first: 50) {
          nodes { type issue { id identifier state { name type } } }
          pageInfo { hasNextPage endCursor }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """
  @issues_by_id_query """
  query SymphonyTrackerIssuesById($ids: [ID!]!, $projectSlug: String!, $first: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
      nodes {
        id identifier title description priority branchName url createdAt updatedAt
        state { name type }
        assignee { id }
        labels { nodes { name } }
        inverseRelations(first: 50) {
          nodes { type issue { id identifier state { name type } } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """
  @transition_mutation """
  mutation SymphonyTrackerTransition($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: {stateId: $stateId}) {
      success
      issue { id state { name } }
    }
  }
  """
  @comments_query """
  query SymphonyTrackerComments($issueId: String!, $after: String) {
    issue(id: $issueId) {
      comments(first: 50, after: $after) {
        nodes { id body user { id } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """
  @comment_create_mutation """
  mutation SymphonyTrackerCommentCreate($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment { id }
    }
  }
  """
  @comment_update_mutation """
  mutation SymphonyTrackerCommentUpdate($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment { id }
    }
  }
  """

  @spec health_check(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def health_check(config, opts) do
    settings = Support.settings(config)
    endpoint = Support.value(settings, :endpoint, "https://api.linear.app/graphql")
    project_slug = Support.value(settings, :project_slug)

    request = %{
      method: :post,
      url: endpoint,
      headers: linear_headers(Keyword.fetch!(opts, :credential)),
      body: %{
        query: @health_query,
        variables: %{projectSlug: project_slug},
        operation_name: "SymphonyTrackerHealth"
      }
    }

    case graphql_response(request, opts) do
      {:ok, %{status: status, body: %{"data" => data}}}
      when status in 200..299 and is_map(data) ->
        with {:ok, scope} <- validate_health_scope(data, settings),
             {:ok, bot_actor_id} <- validate_health_bot_identity(data, settings),
             :ok <- validate_health_issue_read(data),
             {:ok, state_mapping} <- validate_health_state_mapping(data, settings),
             :ok <- validate_health_comment_permission(data) do
          {:ok,
           %{
             provider: "linear",
             status: :healthy,
             evidence: %{
               credentials: :verified,
               scope: :verified,
               issue_read: :verified,
               state_mappings: :verified,
               comment_permissions: :verified,
               http_status: status,
               details: %{
                 tracker_scope: scope,
                 bot_actor_id: bot_actor_id,
                 state_mapping: state_mapping
               }
             }
           }}
        end

      {:ok, _response} ->
        {:error, Support.error("linear", :invalid_response, false, "tracker provider returned an invalid response")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_health_scope(data, settings) do
    configured_scope = Support.value(settings, :project_slug)
    projects = get_in(data, ["projects", "nodes"])

    if present_string?(configured_scope) and is_list(projects) and
         Enum.any?(projects, fn
           %{"id" => id, "slugId" => ^configured_scope} -> present_string?(id)
           _project -> false
         end) do
      {:ok, configured_scope}
    else
      invalid_response()
    end
  end

  defp validate_health_bot_identity(data, settings) do
    configured_actor_id = Support.value(settings, :bot_actor_id)
    actor_id = get_in(data, ["viewer", "id"])

    if present_string?(to_string(configured_actor_id || "")) and
         present_string?(to_string(actor_id || "")) and
         to_string(configured_actor_id) == to_string(actor_id) do
      {:ok, to_string(actor_id)}
    else
      invalid_response()
    end
  end

  defp validate_health_issue_read(data) do
    case get_in(data, ["issues", "nodes"]) do
      issues when is_list(issues) ->
        if Enum.all?(issues, &valid_health_issue?/1), do: :ok, else: invalid_response()

      _issues ->
        invalid_response()
    end
  end

  defp valid_health_issue?(%{
         "id" => id,
         "state" => %{"id" => state_id, "name" => state_name, "type" => state_type},
         "comments" => %{"nodes" => comments}
       }) do
    Enum.all?([id, state_id, state_name, state_type], &present_string?/1) and is_list(comments) and
      Enum.all?(comments, fn
        %{"id" => comment_id} -> present_string?(comment_id)
        _comment -> false
      end)
  end

  defp valid_health_issue?(_issue), do: false

  defp validate_health_state_mapping(data, settings) do
    configured_state_ids = Support.value(settings, :state_ids, %{})
    workflow_states = get_in(data, ["workflowStates", "nodes"])

    with true <- is_map(configured_state_ids) and map_size(configured_state_ids) > 0,
         true <- is_list(workflow_states),
         {:ok, states_by_id} <- index_health_states(workflow_states) do
      Enum.reduce_while(configured_state_ids, {:ok, %{}}, fn {logical_state, state_id}, {:ok, mapping} ->
        add_health_state_mapping(mapping, logical_state, state_id, Map.get(states_by_id, state_id))
      end)
    else
      _invalid_states -> invalid_response()
    end
  end

  defp add_health_state_mapping(mapping, logical_state, state_id, state) do
    case health_state_entry(logical_state, state_id, state) do
      {:ok, entry} -> {:cont, {:ok, Map.put(mapping, to_string(logical_state), entry)}}
      :error -> {:halt, invalid_response()}
    end
  end

  defp health_state_entry(logical_state, state_id, %{"id" => id, "name" => name, "type" => type} = state)
       when is_binary(id) and is_binary(name) and is_binary(type) do
    if present_string?(state_id) and valid_health_state_type?(logical_state, state) do
      {:ok, %{id: id, name: name, type: type}}
    else
      :error
    end
  end

  defp health_state_entry(_logical_state, _state_id, _state), do: :error

  defp index_health_states(workflow_states) do
    Enum.reduce_while(workflow_states, {:ok, %{}}, fn
      %{"id" => id} = state, {:ok, states} when is_binary(id) ->
        if present_string?(id) do
          {:cont, {:ok, Map.put(states, id, state)}}
        else
          {:halt, invalid_response()}
        end

      _state, _states ->
        {:halt, invalid_response()}
    end)
  end

  defp valid_health_state_type?(logical_state, %{"type" => state_type}) do
    logical_state = logical_state |> to_string() |> String.trim() |> String.downcase()
    state_type = state_type |> String.trim() |> String.downcase()

    case logical_state do
      state when state in ["backlog", "unstarted", "started", "completed"] -> state_type == state
      state when state in ["canceled", "cancelled"] -> state_type in ["canceled", "cancelled"]
      _custom_state -> true
    end
  end

  defp validate_health_comment_permission(data) do
    fields = get_in(data, ["commentCreateCapability", "fields"])

    if is_list(fields) and
         Enum.any?(fields, fn
           %{"name" => "commentCreate"} -> true
           %{name: "commentCreate"} -> true
           _field -> false
         end) do
      :ok
    else
      forbidden_health()
    end
  end

  defp forbidden_health do
    {:error, Support.error("linear", :forbidden, false, "tracker provider denied the request")}
  end

  @spec fetch_eligible(map(), map(), keyword()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_eligible(config, criteria, opts) do
    do_fetch_eligible(config, criteria, opts, nil, [], 1)
  end

  @spec fetch_by_ids(map(), [String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_by_ids(config, issue_ids, opts) do
    requested_ids = Enum.map(issue_ids, &to_string/1) |> Enum.uniq()

    with {:ok, issues} <- fetch_id_chunks(config, Enum.chunk_every(requested_ids, 50), opts, []) do
      by_id = Map.new(issues, &{&1.id, &1})
      {:ok, Enum.flat_map(requested_ids, &(Map.take(by_id, [&1]) |> Map.values()))}
    end
  end

  @spec normalize_webhook(map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def normalize_webhook(config, request, opts) do
    body = Support.value(request, :body)
    signature = Support.header(%{headers: Support.value(request, :headers, %{})}, "linear-signature")
    credential = Keyword.fetch!(opts, :credential)
    expected = :crypto.mac(:hmac, :sha256, credential, body) |> Base.encode16(case: :lower)

    if Support.secure_compare(signature || "", expected) do
      with {:ok, payload} <- Jason.decode(body),
           :ok <- validate_webhook_timestamp(payload, opts) do
        normalize_signed_webhook(config, payload)
      else
        {:error, %{code: _code} = error} -> {:error, error}
        _other -> invalid_webhook()
      end
    else
      {:error, Support.error("linear", :invalid_signature, false, "tracker webhook signature is invalid")}
    end
  rescue
    _exception ->
      invalid_webhook()
  end

  @spec transition_issue(map(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def transition_issue(config, issue_id, target_state, opts) do
    normalized_state = target_state |> to_string() |> String.trim() |> String.downcase()
    settings = Support.settings(config)
    state_ids = Support.value(settings, :state_ids, %{})

    state_id = Map.get(state_ids, normalized_state) || Map.get(state_ids, target_state)

    case state_id do
      state_id when is_binary(state_id) and state_id != "" ->
        request = %{
          method: :post,
          url: Support.value(settings, :endpoint, "https://api.linear.app/graphql"),
          headers: linear_headers(Keyword.fetch!(opts, :credential)),
          body: %{
            query: @transition_mutation,
            operation_name: "SymphonyTrackerTransition",
            variables: %{id: issue_id, stateId: state_id}
          }
        }

        transition_result(request, issue_id, normalized_state, opts)

      _other ->
        {:error, Support.error("linear", :unsupported_transition, false, "tracker transition is unsupported")}
    end
  end

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

  defp fetch_id_chunks(_config, [], _opts, acc), do: {:ok, acc}

  defp fetch_id_chunks(config, [ids | remaining], opts, acc) do
    settings = Support.settings(config)

    request = %{
      method: :post,
      url: Support.value(settings, :endpoint, "https://api.linear.app/graphql"),
      headers: linear_headers(Keyword.fetch!(opts, :credential)),
      body: %{
        query: @issues_by_id_query,
        operation_name: "SymphonyTrackerIssuesById",
        variables: %{
          ids: ids,
          projectSlug: Support.value(settings, :project_slug),
          first: length(ids)
        }
      }
    }

    case graphql_response(request, opts) do
      {:ok,
       %{
         status: status,
         body: %{"data" => %{"issues" => %{"nodes" => nodes}}}
       }}
      when status in 200..299 and is_list(nodes) ->
        fetch_id_chunks(config, remaining, opts, acc ++ Enum.map(nodes, &normalize_issue/1))

      {:ok, _response} ->
        {:error, Support.error("linear", :invalid_response, false, "tracker provider returned an invalid response")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_fetch_eligible(config, criteria, opts, cursor, acc, page_count) do
    if page_count > Keyword.get(opts, :max_pages, 100) do
      pagination_limit_error()
    else
      config
      |> eligible_request(criteria, opts, cursor)
      |> graphql_response(opts)
      |> eligible_response(config, criteria, opts, acc, page_count)
    end
  end

  defp eligible_request(config, criteria, opts, cursor) do
    settings = Support.settings(config)

    %{
      method: :post,
      url: Support.value(settings, :endpoint, "https://api.linear.app/graphql"),
      headers: linear_headers(Keyword.fetch!(opts, :credential)),
      body: %{
        query: @issues_query,
        operation_name: "SymphonyTrackerPoll",
        variables: %{
          projectSlug: Support.value(settings, :project_slug),
          stateNames: Support.value(criteria, :states, []),
          first: 50,
          after: cursor
        }
      }
    }
  end

  defp eligible_response(
         {:ok,
          %{
            status: status,
            body: %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}}
          }},
         config,
         criteria,
         opts,
         acc,
         page_count
       )
       when status in 200..299 and is_list(nodes) and is_map(page_info) do
    issues =
      nodes
      |> Enum.map(&normalize_issue/1)
      |> Enum.filter(&Support.eligible?(&1, criteria))

    continue_eligible_pagination(page_info, config, criteria, opts, acc ++ issues, page_count)
  end

  defp eligible_response({:ok, _response}, _config, _criteria, _opts, _acc, _page_count) do
    {:error, Support.error("linear", :invalid_response, false, "tracker provider returned an invalid response")}
  end

  defp eligible_response({:error, error}, _config, _criteria, _opts, _acc, _page_count), do: {:error, error}

  defp continue_eligible_pagination(page_info, config, criteria, opts, issues, page_count) do
    case next_cursor(page_info) do
      :done -> {:ok, issues}
      {:ok, next_cursor} -> do_fetch_eligible(config, criteria, opts, next_cursor, issues, page_count + 1)
      {:error, error} -> {:error, error}
    end
  end

  defp next_cursor(%{"hasNextPage" => true, "endCursor" => cursor})
       when is_binary(cursor) and cursor != "",
       do: {:ok, cursor}

  defp next_cursor(%{"hasNextPage" => true}) do
    {:error, Support.error("linear", :invalid_response, false, "tracker provider returned an invalid cursor")}
  end

  defp next_cursor(_page_info), do: :done

  defp normalize_issue(issue) do
    state = get_in(issue, ["state", "name"])
    state_type = get_in(issue, ["state", "type"])

    relation_connection =
      case Map.get(issue, "inverseRelations") do
        connection when is_map(connection) -> connection
        _connection -> %{}
      end

    blockers = normalize_blockers(Map.get(relation_connection, "nodes"))
    blocker_connection_complete? = blocker_connection_complete?(relation_connection)

    %Issue{
      id: Map.get(issue, "id"),
      native_ref: %{provider: "linear", id: Map.get(issue, "id")},
      identifier: Map.get(issue, "identifier"),
      title: Map.get(issue, "title"),
      description: Map.get(issue, "description"),
      priority: Map.get(issue, "priority"),
      state: state,
      branch_name: Map.get(issue, "branchName"),
      url: Map.get(issue, "url"),
      assignee_id: get_in(issue, ["assignee", "id"]),
      labels: normalize_labels(get_in(issue, ["labels", "nodes"]) || []),
      blocked_by: blockers,
      dispatchable:
        not terminal_state_type?(state_type) and blocker_connection_complete? and
          Enum.all?(blockers, & &1.completed?),
      created_at: parse_datetime(Map.get(issue, "createdAt")),
      updated_at: parse_datetime(Map.get(issue, "updatedAt"))
    }
  end

  defp normalize_labels(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      _other -> []
    end)
  end

  defp normalize_blockers(relations) when is_list(relations) do
    Enum.flat_map(relations, fn
      %{"type" => "blocks", "issue" => issue} when is_map(issue) ->
        state = get_in(issue, ["state", "name"])
        completed? = issue |> get_in(["state", "type"]) |> terminal_state_type?()
        id = Map.get(issue, "id")
        identifier = Map.get(issue, "identifier")

        [
          %{
            id: id,
            identifier: identifier,
            external_id: identifier || id,
            state: state,
            terminal: completed?,
            completed?: completed?
          }
        ]

      _other ->
        []
    end)
  end

  defp normalize_blockers(_relations), do: []

  defp blocker_connection_complete?(%{
         "nodes" => nodes,
         "pageInfo" => %{"hasNextPage" => false}
       })
       when is_list(nodes),
       do: true

  defp blocker_connection_complete?(_connection), do: false

  defp terminal_state_type?(state_type) when is_binary(state_type) do
    (state_type |> String.trim() |> String.downcase()) in ["completed", "canceled", "cancelled"]
  end

  defp terminal_state_type?(_state_type), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_signed_webhook(config, payload) do
    with webhook_id when is_binary(webhook_id) and webhook_id != "" <- Map.get(payload, "webhookId"),
         %{} = data <- Map.get(payload, "data") do
      signed_webhook_result(config, payload, data, webhook_id)
    else
      _other ->
        invalid_webhook()
    end
  end

  defp signed_webhook_result(config, %{"type" => "Issue"} = payload, data, webhook_id) do
    case Map.get(data, "id") do
      issue_id when is_binary(issue_id) and issue_id != "" ->
        payload
        |> issue_webhook_signal(issue_id, webhook_id)
        |> terminal_webhook_signal(config, data)

      _issue_id ->
        invalid_webhook()
    end
  end

  defp signed_webhook_result(_config, _payload, _data, webhook_id) do
    {:ok,
     %{
       provider: "linear",
       kind: :ignored,
       reason: :unsupported_object,
       reconciliation_key: "linear:#{webhook_id}"
     }}
  end

  defp issue_webhook_signal(payload, issue_id, webhook_id) do
    %{
      provider: "linear",
      kind: :issue,
      action: Map.get(payload, "action"),
      issue_id: issue_id,
      reconciliation_key: "linear:#{webhook_id}"
    }
  end

  defp terminal_webhook_signal(signal, config, data) do
    case terminal_webhook_state(config, data) do
      nil -> {:ok, signal}
      terminal_state -> {:ok, %{signal | kind: :human_terminal} |> Map.put(:terminal_state, terminal_state)}
    end
  end

  defp validate_webhook_timestamp(payload, opts) when is_map(payload) do
    with {:ok, timestamp} <- parse_webhook_timestamp(Map.get(payload, "webhookTimestamp")),
         {:ok, now} <- webhook_now_ms(opts) do
      past_tolerance = tolerance_ms(opts, :webhook_tolerance_ms, 60_000)
      future_tolerance = tolerance_ms(opts, :webhook_future_tolerance_ms, past_tolerance)
      age = now - timestamp

      if age <= past_tolerance and age >= -future_tolerance do
        :ok
      else
        {:error, Support.error("linear", :stale_webhook, false, "tracker webhook timestamp is stale")}
      end
    end
  end

  defp validate_webhook_timestamp(_payload, _opts), do: invalid_webhook()

  defp parse_webhook_timestamp(timestamp) when is_integer(timestamp) and timestamp >= 0,
    do: {:ok, timestamp}

  defp parse_webhook_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> invalid_webhook()
    end
  end

  defp parse_webhook_timestamp(_timestamp), do: invalid_webhook()

  defp webhook_now_ms(opts) do
    now =
      case Keyword.get(opts, :clock) do
        clock when is_function(clock, 0) -> clock.()
        nil -> Keyword.get(opts, :now_ms, Keyword.get(opts, :now, System.system_time(:millisecond)))
        _invalid_clock -> nil
      end

    if is_integer(now) and now >= 0, do: {:ok, now}, else: invalid_webhook()
  end

  defp tolerance_ms(opts, key, default) do
    case Keyword.get(opts, key, default) do
      tolerance when is_integer(tolerance) and tolerance >= 0 -> tolerance
      _invalid_tolerance -> default
    end
  end

  defp terminal_webhook_state(config, data) do
    state_type =
      get_in(data, ["state", "type"]) || Map.get(data, "stateType") ||
        configured_terminal_state(config, Map.get(data, "stateId"))

    normalized_terminal_state(state_type)
  end

  defp configured_terminal_state(_config, nil), do: nil

  defp configured_terminal_state(config, state_id) do
    case config |> Support.settings() |> Support.value(:state_ids, %{}) do
      state_ids when is_map(state_ids) ->
        Enum.find_value(state_ids, &terminal_state_match(&1, state_id))

      _state_ids ->
        nil
    end
  end

  defp terminal_state_match({state, configured_id}, state_id) do
    if to_string(configured_id) == to_string(state_id), do: state
  end

  defp normalized_terminal_state(state) when is_atom(state),
    do: state |> Atom.to_string() |> normalized_terminal_state()

  defp normalized_terminal_state(state) when is_binary(state) do
    case state |> String.trim() |> String.downcase() do
      "completed" -> :completed
      state when state in ["canceled", "cancelled"] -> :cancelled
      _state -> nil
    end
  end

  defp normalized_terminal_state(_state), do: nil

  defp transition_result(request, issue_id, state, opts) do
    case graphql_response(request, opts) do
      {:ok,
       %{
         status: status,
         body: %{"data" => %{"issueUpdate" => %{"success" => true}}}
       }}
      when status in 200..299 ->
        {:ok, %{provider: "linear", issue_id: issue_id, state: state}}

      {:ok, _response} ->
        {:error, Support.error("linear", :provider_error, false, "tracker provider rejected the transition")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp upsert_marker_comment(config, issue_id, kind, content, opts) do
    marker = "<!-- symphony-tracker:#{kind} issue=linear:#{issue_id} -->"
    bot_actor_id = config |> Support.settings() |> Support.value(:bot_actor_id)

    with {:ok, comments} <- fetch_comments(config, issue_id, opts) do
      case Enum.find(comments, &(comment_has_marker?(&1, marker) and owned_by?(&1, bot_actor_id))) do
        nil -> create_comment(config, issue_id, marker, content, opts)
        comment -> update_comment(config, issue_id, comment, marker, content, opts)
      end
    end
  end

  defp fetch_comments(config, issue_id, opts) do
    do_fetch_comments(config, issue_id, opts, nil, [], [])
  end

  @spec do_fetch_comments(map(), String.t(), keyword(), String.t() | nil, [map()], [String.t() | nil]) ::
          {:ok, [map()]} | {:error, map()}
  defp do_fetch_comments(config, issue_id, opts, cursor, acc, seen_cursors) do
    max_pages = Keyword.get(opts, :max_pages, 100)

    if cursor in seen_cursors or length(seen_cursors) >= max_pages do
      pagination_limit_error()
    else
      seen_cursors = [cursor | seen_cursors]

      request =
        graphql_request(
          config,
          opts,
          @comments_query,
          "SymphonyTrackerComments",
          %{issueId: issue_id, after: cursor}
        )

      request
      |> graphql_response(opts)
      |> comments_response(config, issue_id, opts, acc, seen_cursors)
    end
  end

  defp comments_response(
         {:ok,
          %{
            status: status,
            body: %{"data" => %{"issue" => %{"comments" => comments_connection}}}
          }},
         config,
         issue_id,
         opts,
         acc,
         seen_cursors
       )
       when status in 200..299 and is_map(comments_connection) do
    comments = Map.get(comments_connection, "nodes", [])

    if is_list(comments) do
      continue_comment_pagination(comments_connection, config, issue_id, opts, acc ++ comments, seen_cursors)
    else
      invalid_response()
    end
  end

  defp comments_response({:ok, _response}, _config, _issue_id, _opts, _acc, _seen_cursors),
    do: invalid_response()

  defp comments_response({:error, error}, _config, _issue_id, _opts, _acc, _seen_cursors), do: {:error, error}

  defp continue_comment_pagination(comments_connection, config, issue_id, opts, comments, seen_cursors) do
    case next_cursor(Map.get(comments_connection, "pageInfo", %{})) do
      :done -> {:ok, comments}
      {:ok, next} -> do_fetch_comments(config, issue_id, opts, next, comments, seen_cursors)
      {:error, error} -> {:error, error}
    end
  end

  defp create_comment(config, issue_id, marker, content, opts) do
    request =
      graphql_request(
        config,
        opts,
        @comment_create_mutation,
        "SymphonyTrackerCommentCreate",
        %{issueId: issue_id, body: marker <> "\n" <> content}
      )

    comment_result(request, issue_id, marker, :created, "commentCreate", opts)
  end

  defp update_comment(config, issue_id, comment, marker, content, opts) do
    request =
      graphql_request(
        config,
        opts,
        @comment_update_mutation,
        "SymphonyTrackerCommentUpdate",
        %{commentId: Map.get(comment, "id"), body: marker <> "\n" <> content}
      )

    comment_result(request, issue_id, marker, :updated, "commentUpdate", opts)
  end

  defp comment_result(request, issue_id, marker, action, result_key, opts) do
    case graphql_response(request, opts) do
      {:ok,
       %{
         status: status,
         body: %{
           "data" => %{
             ^result_key => %{"success" => true, "comment" => %{"id" => comment_id}}
           }
         }
       }}
      when status in 200..299 ->
        {:ok,
         %{
           provider: "linear",
           issue_id: issue_id,
           action: action,
           external_id: to_string(comment_id),
           external_comment_id: to_string(comment_id),
           marker: marker
         }}

      {:ok, _response} ->
        {:error, Support.error("linear", :provider_error, false, "tracker provider rejected the comment")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp graphql_request(config, opts, query, operation_name, variables) do
    settings = Support.settings(config)

    %{
      method: :post,
      url: Support.value(settings, :endpoint, "https://api.linear.app/graphql"),
      headers: linear_headers(Keyword.fetch!(opts, :credential)),
      body: %{query: query, operation_name: operation_name, variables: variables}
    }
  end

  defp comment_has_marker?(comment, marker) do
    case Map.get(comment, "body") do
      body when is_binary(body) ->
        body
        |> String.split(["\r\n", "\n", "\r"], parts: 2)
        |> List.first() == marker

      _other ->
        false
    end
  end

  defp owned_by?(comment, bot_actor_id) when not is_nil(bot_actor_id) do
    case get_in(comment, ["user", "id"]) do
      nil -> false
      actor_id -> to_string(actor_id) == to_string(bot_actor_id)
    end
  end

  defp owned_by?(_comment, _bot_actor_id), do: false

  defp invalid_response do
    {:error, Support.error("linear", :invalid_response, false, "tracker provider returned an invalid response")}
  end

  defp invalid_webhook do
    {:error, Support.error("linear", :invalid_webhook, false, "tracker webhook is invalid")}
  end

  defp graphql_response(request, opts) do
    case Transport.request(request, opts) do
      {:ok, response} -> validate_graphql_response(response)
      {:error, _reason} -> Support.transport_error("linear")
    end
  end

  defp validate_graphql_response(%{status: status} = response) when is_integer(status) do
    case Map.get(response, :body) do
      body when is_map(body) ->
        response_with_graphql_body(response, status, Support.value(body, :errors))

      _body ->
        response_without_graphql_body(response, status)
    end
  end

  defp validate_graphql_response(_response), do: invalid_response()

  defp response_with_graphql_body(response, _status, errors) when is_list(errors) and errors != [] do
    graphql_error_response(response, errors)
  end

  defp response_with_graphql_body(response, status, errors) when errors in [nil, []] do
    if status in 200..299, do: {:ok, response}, else: Support.http_error("linear", response)
  end

  defp response_with_graphql_body(response, status, _invalid_errors) do
    if status in 200..299, do: invalid_response(), else: Support.http_error("linear", response)
  end

  defp response_without_graphql_body(response, status) do
    if status in 200..299, do: invalid_response(), else: Support.http_error("linear", response)
  end

  defp graphql_error_response(%{status: status} = response, errors) do
    cond do
      Enum.any?(errors, &rate_limited_graphql_error?/1) ->
        {:error,
         Support.error(
           "linear",
           :rate_limited,
           true,
           "tracker provider rate limited the request",
           retry_after_ms: graphql_retry_after_ms(response, errors)
         )}

      status not in 200..299 ->
        Support.http_error("linear", response)

      true ->
        {:error, Support.error("linear", :provider_error, false, "tracker provider rejected the request")}
    end
  end

  defp rate_limited_graphql_error?(error) when is_map(error) do
    error
    |> graphql_error_extensions()
    |> Support.value(:code)
    |> case do
      code when is_binary(code) -> String.upcase(code) == "RATELIMITED"
      _code -> false
    end
  end

  defp rate_limited_graphql_error?(_error), do: false

  defp graphql_retry_after_ms(response, errors) do
    retry_after_header_ms(response) || Enum.find_value(errors, &graphql_error_retry_after_ms/1)
  end

  defp retry_after_header_ms(response) do
    response
    |> Support.header("retry-after")
    |> parse_nonnegative_integer()
    |> case do
      nil -> nil
      seconds -> seconds * 1_000
    end
  end

  defp graphql_error_retry_after_ms(error) when is_map(error) do
    extensions = graphql_error_extensions(error)

    parse_nonnegative_integer(Support.value(extensions, :retryAfterMs)) ||
      parse_nonnegative_integer(Support.value(extensions, :retry_after_ms)) ||
      retry_after_seconds_ms(extensions)
  end

  defp graphql_error_retry_after_ms(_error), do: nil

  defp graphql_error_extensions(error) do
    case Support.value(error, :extensions, %{}) do
      extensions when is_map(extensions) -> extensions
      _extensions -> %{}
    end
  end

  defp retry_after_seconds_ms(extensions) do
    extensions
    |> Support.value(:retryAfter, Support.value(extensions, :retry_after))
    |> parse_nonnegative_integer()
    |> case do
      nil -> nil
      seconds -> seconds * 1_000
    end
  end

  defp parse_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp parse_nonnegative_integer(_value), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp pagination_limit_error do
    {:error,
     Support.error(
       "linear",
       :pagination_limit,
       false,
       "tracker provider pagination limit was exceeded"
     )}
  end

  defp linear_headers(credential) do
    %{
      "authorization" => credential,
      "content-type" => "application/json"
    }
  end
end
