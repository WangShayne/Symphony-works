defmodule SymphonyElixir.Tracker.Adapters.Fixture do
  @moduledoc false

  @behaviour SymphonyElixir.Tracker.Adapter

  alias SymphonyElixir.Tracker.Issue

  @spec health_check(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def health_check(config, opts) do
    case Keyword.get(opts, :health_observer) do
      observer when is_pid(observer) ->
        send(observer, {:fixture_health_called, config, Keyword.take(opts, [:credential, :webhook_secret])})

      _observer ->
        :ok
    end

    case config |> value(:settings, %{}) |> value(:scenario, "healthy") do
      "unhealthy" ->
        {:error,
         %{
           provider: "fixture",
           code: :fixture_unhealthy,
           retryable: false,
           message: "tracker fixture is unhealthy"
         }}

      "echo_runtime_secrets" ->
        {:ok,
         %{
           provider: "fixture",
           status: :healthy,
           evidence: %{
             credential: Keyword.get(opts, :credential),
             webhook_secret: Keyword.get(opts, :webhook_secret)
           }
         }}

      "echo_runtime_secret_list" ->
        {:ok, [credential: [Keyword.get(opts, :credential)]]}

      "raise" ->
        raise "tracker fixture failed"

      "throw" ->
        throw(:tracker_fixture_failed)

      _scenario ->
        {:ok,
         %{
           provider: "fixture",
           status: :healthy,
           evidence: %{
             transport: :deterministic_fixture,
             credentials: :verified,
             scope: :verified,
             issue_read: :verified,
             state_mappings: :verified,
             comment_permissions: :verified
           }
         }}
    end
  end

  @spec fetch_eligible(map(), map(), keyword()) :: {:ok, [Issue.t()]}
  def fetch_eligible(config, criteria, _opts) do
    states = criteria |> value(:states, []) |> normalized_set()
    labels = criteria |> value(:required_labels, []) |> normalized_set()
    assignee_id = value(criteria, :assignee_id)

    issues =
      config
      |> value(:settings, %{})
      |> value(:issues, [])
      |> Enum.map(&normalize_issue/1)
      |> Enum.filter(fn issue -> eligible?(issue, states, labels, assignee_id) end)

    {:ok, issues}
  end

  @spec fetch_by_ids(map(), [String.t()], keyword()) :: {:ok, [Issue.t()]}
  def fetch_by_ids(config, issue_ids, _opts) do
    issues_by_id =
      config
      |> value(:settings, %{})
      |> value(:issues, [])
      |> Enum.map(&normalize_issue/1)
      |> Map.new(&{&1.id, &1})

    issues = Enum.flat_map(issue_ids, &(Map.take(issues_by_id, [&1]) |> Map.values()))
    {:ok, issues}
  end

  @spec normalize_webhook(map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def normalize_webhook(_config, request, _opts) do
    body = value(request, :body, %{})
    event_id = value(body, :event_id)
    issue_id = value(body, :issue_id)

    if Enum.all?([is_map(body), present_string?(event_id), present_string?(issue_id)]) do
      {:ok,
       %{
         provider: "fixture",
         kind: webhook_kind(body),
         action: value(body, :action, "updated"),
         issue_id: issue_id,
         reconciliation_key: "fixture:#{event_id}"
       }}
    else
      {:error,
       %{
         provider: "fixture",
         code: :invalid_webhook,
         retryable: false,
         message: "tracker fixture webhook is invalid"
       }}
    end
  end

  @spec transition_issue(map(), String.t(), atom() | String.t(), keyword()) :: {:ok, map()}
  def transition_issue(_config, issue_id, target_state, _opts) do
    {:ok, %{provider: "fixture", issue_id: issue_id, state: normalize(target_state)}}
  end

  @spec upsert_progress(map(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def upsert_progress(_config, issue_id, progress, opts) do
    persist_comment(:progress, issue_id, progress, opts)
  end

  @spec append_final_summary(map(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def append_final_summary(_config, issue_id, summary, opts) do
    persist_comment(:final, issue_id, summary, opts)
  end

  defp normalize_issue(issue) do
    kind = value(issue, :kind, "issue")
    state = value(issue, :state)

    %Issue{
      id: value(issue, :id),
      native_ref: value(issue, :native_ref),
      identifier: value(issue, :identifier),
      title: value(issue, :title),
      description: value(issue, :description),
      priority: value(issue, :priority),
      state: state,
      branch_name: value(issue, :branch_name),
      url: value(issue, :url),
      assignee_id: value(issue, :assignee_id),
      labels: value(issue, :labels, []),
      blocked_by: value(issue, :blocked_by, []),
      dispatchable:
        Enum.all?([
          value(issue, :dispatchable, true) == true,
          issue_kind?(kind),
          not terminal_state?(state)
        ]),
      created_at: value(issue, :created_at),
      updated_at: value(issue, :updated_at)
    }
  end

  defp persist_comment(kind, issue_id, content, opts) do
    external_id = "fixture-#{kind}-#{issue_id}"
    marker = "<!-- symphony-tracker:#{kind} issue=fixture:#{issue_id} -->"
    state = Keyword.get(opts, :fixture_state)
    operation_id = Keyword.get(opts, :operation_id)

    if is_pid(state) do
      Agent.get_and_update(state, &persist_agent_comment(&1, kind, issue_id, content, operation_id, marker))
    else
      {:ok,
       %{
         provider: "fixture",
         issue_id: issue_id,
         action: :updated,
         external_id: external_id,
         external_comment_id: external_id,
         marker: marker
       }}
    end
  end

  defp persist_agent_comment(comments, kind, issue_id, content, operation_id, marker) do
    operation_key = {:operation, operation_id}

    case operation_id && Map.get(comments, operation_key) do
      nil -> put_agent_comment(comments, kind, issue_id, content, operation_id, marker)
      result -> {{:ok, result}, comments}
    end
  end

  defp put_agent_comment(comments, kind, issue_id, content, operation_id, marker) do
    comment_key = {:comment, kind, issue_id}
    external_id = "fixture-#{kind}-#{issue_id}"
    action = if Map.has_key?(comments, comment_key), do: :updated, else: :created

    result = %{
      provider: "fixture",
      issue_id: issue_id,
      action: action,
      external_id: external_id,
      external_comment_id: external_id,
      marker: marker
    }

    updated = Map.put(comments, comment_key, content)
    updated = if operation_id, do: Map.put(updated, {:operation, operation_id}, result), else: updated
    {{:ok, result}, updated}
  end

  defp webhook_kind(body) do
    kind = body |> value(:kind, "issue") |> normalize()
    state = body |> value(:state) |> normalize()
    action = body |> value(:action) |> normalize()

    if kind in ["pull_request", "merge_request", "delivery_artifact"] do
      :delivery_artifact
    else
      if terminal_state?(state) or terminal_state?(action), do: :human_terminal, else: :issue
    end
  end

  defp issue_kind?(kind), do: normalize(kind) in ["", "issue"]

  defp terminal_state?(state) do
    normalize(state) in ["closed", "completed", "canceled", "cancelled", "done"]
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp eligible?(issue, states, labels, assignee_id) do
    state_matches? = MapSet.member?(states, normalize(issue.state))
    issue_labels = normalized_set(issue.labels)
    labels_match? = Enum.all?(labels, &MapSet.member?(issue_labels, &1))
    assignee_matches? = Enum.any?([is_nil(assignee_id), issue.assignee_id == assignee_id])

    Enum.all?([issue.dispatchable, state_matches?, labels_match?, assignee_matches?])
  end

  defp normalized_set(values) when is_list(values) do
    values
    |> Enum.map(&normalize/1)
    |> MapSet.new()
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()
  defp normalize(_value), do: ""

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
