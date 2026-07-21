defmodule SymphonyElixir.SourceControl.Fake do
  @moduledoc """
  Deterministic Source Control adapter used for configuration and contract evidence.
  """

  @behaviour SymphonyElixir.SourceControl

  alias SymphonyElixir.SourceControl.{Baseline, Branch, ChangeRequest}
  alias SymphonyElixir.SourceControl.ChangeRequest.State

  @state_owner SymphonyElixir.SourceControl.Fake.StateOwner

  @impl true
  def health_check(config) when is_map(config) do
    settings = value(config, :settings) || %{}

    case value(settings, :scenario) || "healthy" do
      "healthy" ->
        base_branch = value(settings, :base_branch)
        permissions = fake_permissions(settings)

        if nonempty_string?(value(settings, :repository)) and nonempty_string?(base_branch) and
             required_permissions_allowed?(permissions) do
          base_commit_sha = fake_sha([value(settings, :repository), base_branch])

          {:ok,
           %{
             provider: :fixture,
             repository: value(settings, :repository),
             base_branch: base_branch,
             base_commit_sha: base_commit_sha,
             permissions: permissions,
             status: :passed
           }}
        else
          fake_health_error(settings, base_branch, permissions)
        end

      _scenario ->
        {:error, :not_found}
    end
  end

  @impl true
  def resolve_baseline(config, branch) when is_map(config) and is_binary(branch) do
    settings = value(config, :settings) || %{}

    with repository when is_binary(repository) <- value(settings, :repository),
         true <- nonempty_string?(branch) do
      sha = fake_sha([repository, branch, value(settings, :scenario) || "healthy"])

      {:ok,
       %Baseline{
         provider: :fixture,
         repository: repository,
         branch: branch,
         commit_sha: sha
       }}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def ensure_remote_branch(config, branch, opts)
      when is_map(config) and is_map(branch) and is_list(opts) do
    with {:ok, operation_id, dedupe_key} <- operation_identity(opts),
         settings when is_map(settings) <- value(config, :settings),
         repository when is_binary(repository) <- value(settings, :repository),
         name when is_binary(name) <- value(branch, :name),
         commit_sha when is_binary(commit_sha) <- value(branch, :commit_sha),
         true <- nonempty_string?(name) and valid_sha?(commit_sha),
         :ok <- claim_operation(repository, :ensure_remote_branch, operation_id, dedupe_key, [name, commit_sha]),
         :ok <- reconcile_branch(repository, name, commit_sha) do
      {:ok, branch(repository, name, commit_sha, :reconciled)}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def push_branch(config, name, commit_sha, opts)
      when is_map(config) and is_binary(name) and is_binary(commit_sha) and is_list(opts) do
    with {:ok, operation_id, dedupe_key} <- operation_identity(opts),
         expected_sha when is_binary(expected_sha) <- Keyword.get(opts, :expected_remote_sha),
         true <- nonempty_string?(name) and valid_sha?(commit_sha) and valid_sha?(expected_sha),
         settings when is_map(settings) <- value(config, :settings),
         repository when is_binary(repository) <- value(settings, :repository),
         :ok <-
           claim_operation(repository, :push_branch, operation_id, dedupe_key, [
             name,
             commit_sha,
             expected_sha
           ]),
         {:ok, disposition} <- push_branch_cas(settings, repository, name, commit_sha, expected_sha) do
      {:ok, branch(repository, name, commit_sha, disposition)}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def ensure_change_request(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, operation_id, dedupe_key} <- operation_identity(opts),
         repo when is_map(repo) <- value(attrs, :repo),
         settings when is_map(settings) <- value(repo, :settings),
         repository when is_binary(repository) <- value(settings, :repository),
         head when is_binary(head) <- value(attrs, :head),
         base when is_binary(base) <- value(attrs, :base) || value(settings, :base_branch),
         title when is_binary(title) <- value(attrs, :title),
         body when is_binary(body) <- value(attrs, :body) || "",
         draft when is_boolean(draft) <- value(attrs, :draft),
         :ok <-
           claim_operation(repository, :ensure_change_request, operation_id, dedupe_key, [
             head,
             base,
             title,
             body,
             draft
           ]),
         :ok <- claim_change_request_identity(repository, head, base, dedupe_key) do
      external_id = deterministic_id([:ensure_change_request, repository, dedupe_key])

      {:ok,
       %ChangeRequest{
         provider: :fixture,
         external_id: external_id,
         number: :erlang.phash2(external_id, 1_000_000),
         url: "https://fixture.invalid/#{repository}/changes/#{external_id}",
         repository: repository,
         head_branch: head,
         base_branch: base,
         title: title,
         draft?: draft,
         disposition: :reconciled
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def state(config, %ChangeRequest{} = change_request) when is_map(config) do
    settings = value(config, :settings) || %{}
    metadata = value(settings, :observed_state) || %{}
    checks = normalize_checks(value(metadata, :required_checks) || [])

    {:ok,
     %State{
       provider: :fixture,
       external_id: change_request.external_id,
       status: fake_status(metadata),
       base_branch: change_request.base_branch,
       head_branch: change_request.head_branch,
       head_sha: value(metadata, :head_sha),
       base_sha: value(metadata, :base_sha),
       merge_sha: value(metadata, :merge_sha),
       draft?: change_request.draft?,
       ready?: not change_request.draft?,
       merged?: value(metadata, :merged?) == true,
       closed?: value(metadata, :closed?) == true,
       required_checks: checks,
       checks_status: checks_status(checks),
       mergeability: normalize_mergeability(value(metadata, :mergeability)),
       observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
     }}
  end

  @impl true
  def set_draft(config, %ChangeRequest{} = change_request, opts)
      when is_map(config) and is_list(opts) do
    with {:ok, operation_id, dedupe_key} <- operation_identity(opts),
         draft when is_boolean(draft) <- Keyword.get(opts, :draft),
         :ok <-
           claim_operation(
             change_request.repository,
             :set_draft,
             operation_id,
             dedupe_key,
             [change_request.external_id, draft]
           ) do
      {:ok, %{change_request | draft?: draft, disposition: :updated}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def close_or_comment(config, %ChangeRequest{} = change_request, opts)
      when is_map(config) and is_list(opts) do
    with {:ok, operation_id, dedupe_key} <- operation_identity(opts),
         {:ok, action, body} <- close_or_comment_intent(opts),
         :ok <-
           claim_operation(
             change_request.repository,
             :close_or_comment,
             operation_id,
             dedupe_key,
             [change_request.external_id, action, body]
           ) do
      fake_close_or_comment(action, change_request, dedupe_key)
    end
  end

  defp fake_close_or_comment(:close, change_request, _dedupe_key) do
    {:ok, %{action: :closed, external_id: change_request.external_id}}
  end

  defp fake_close_or_comment(:comment, change_request, dedupe_key) do
    {:ok,
     %{
       action: :commented,
       external_id: deterministic_id([:fixture_comment, change_request.external_id, dedupe_key])
     }}
  end

  defp close_or_comment_intent(opts) do
    case Keyword.get(opts, :action) do
      :close ->
        {:ok, :close, nil}

      :comment ->
        body = Keyword.get(opts, :body)
        if nonempty_string?(body), do: {:ok, :comment, body}, else: {:error, :invalid_configuration}

      _other ->
        {:error, :invalid_configuration}
    end
  end

  defp operation_identity(opts) do
    operation_id = Keyword.get(opts, :operation_id)
    dedupe_key = Keyword.get(opts, :dedupe_key)

    if nonempty_string?(operation_id) and nonempty_string?(dedupe_key) do
      {:ok, operation_id, dedupe_key}
    else
      {:error, :missing_operation_identity}
    end
  end

  defp branch(repository, name, commit_sha, disposition) do
    %Branch{
      provider: :fixture,
      repository: repository,
      name: name,
      commit_sha: commit_sha,
      remote_ref: "refs/heads/#{name}",
      disposition: disposition
    }
  end

  defp reconcile_branch(repository, name, commit_sha) do
    key = branch_key(repository, name)

    state_transaction(fn state ->
      case Map.get(state, key) do
        nil -> {:ok, Map.put(state, key, commit_sha)}
        ^commit_sha -> {:ok, state}
        _different -> {{:error, :conflict}, state}
      end
    end)
  end

  defp push_branch_cas(settings, repository, name, desired_sha, expected_sha) do
    key = branch_key(repository, name)

    state_transaction(fn state ->
      observed_sha = Map.get(state, key) || configured_remote_sha(settings, name)

      case observed_sha do
        ^desired_sha ->
          {{:ok, :reconciled}, Map.put(state, key, desired_sha)}

        ^expected_sha ->
          {{:ok, :updated}, Map.put(state, key, desired_sha)}

        nil ->
          {{:error, :not_found}, state}

        _different ->
          {{:error, :conflict}, state}
      end
    end)
  end

  defp configured_remote_sha(settings, name) do
    case value(settings, :remote_branches) do
      branches when is_map(branches) -> Map.get(branches, name)
      _missing -> nil
    end
  end

  defp claim_change_request_identity(repository, head, base, dedupe_key) do
    key = {__MODULE__, :change_request, repository, head, base}

    state_transaction(fn state ->
      case Map.get(state, key) do
        nil -> {:ok, Map.put(state, key, dedupe_key)}
        ^dedupe_key -> {:ok, state}
        _different -> {{:error, :conflict}, state}
      end
    end)
  end

  defp claim_operation(repository, action, operation_id, dedupe_key, intent_parts) do
    fingerprint = deterministic_id([:intent | intent_parts])
    operation_key = {__MODULE__, :operation, repository, action, operation_id}
    dedupe_registry_key = {__MODULE__, :dedupe, repository, action, dedupe_key}
    expected_operation = {dedupe_key, fingerprint}

    state_transaction(fn state ->
      case {Map.get(state, operation_key), Map.get(state, dedupe_registry_key)} do
        {operation, dedupe}
        when operation in [nil, expected_operation] and dedupe in [nil, fingerprint] ->
          next_state =
            state
            |> Map.put(operation_key, expected_operation)
            |> Map.put(dedupe_registry_key, fingerprint)

          {:ok, next_state}

        _changed_identity_or_intent ->
          {{:error, :idempotency_conflict}, state}
      end
    end)
  end

  defp branch_key(repository, name), do: {__MODULE__, :branch, repository, name}

  defp fake_permissions(settings) do
    configured = value(settings, :permissions) || %{}

    %{
      repository_read: normalize_permission(value(configured, :repository_read), :allowed),
      branch_write: normalize_permission(value(configured, :branch_write), :allowed),
      change_request_write: normalize_permission(value(configured, :change_request_write), :allowed)
    }
  end

  defp normalize_permission(nil, default), do: default
  defp normalize_permission(value, _default) when value in [:allowed, :denied, :unknown], do: value
  defp normalize_permission("allowed", _default), do: :allowed
  defp normalize_permission("denied", _default), do: :denied
  defp normalize_permission(_unknown, _default), do: :unknown

  defp required_permissions_allowed?(permissions) do
    permissions.repository_read == :allowed and permissions.branch_write == :allowed and
      permissions.change_request_write == :allowed
  end

  defp fake_health_error(settings, base_branch, permissions) do
    if nonempty_string?(value(settings, :repository)) and nonempty_string?(base_branch) and
         not required_permissions_allowed?(permissions),
       do: {:error, :forbidden},
       else: {:error, :invalid_configuration}
  end

  defp state_transaction(fun) do
    Agent.get_and_update(state_owner(), fn state ->
      {result, next_state} = fun.(state)
      {result, next_state}
    end)
  end

  defp state_owner do
    :global.trans({{__MODULE__, :start_state_owner}, self()}, fn ->
      Process.whereis(@state_owner) || start_state_owner()
    end)
  end

  defp start_state_owner do
    {:ok, pid} = Agent.start(fn -> %{} end, name: @state_owner)
    pid
  end

  defp fake_sha(parts) do
    parts
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha, &1))
    |> Base.encode16(case: :lower)
  end

  defp deterministic_id(parts) do
    parts
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 20)
  end

  defp normalize_checks(checks) do
    checks
    |> Enum.flat_map(fn
      %{name: name, status: status}
      when is_binary(name) and status in [:passed, :pending, :failed, :unknown] ->
        [%{name: name, status: status, url: nil}]

      %{"name" => name, "status" => status} = check when is_binary(name) ->
        [%{name: name, status: normalize_check_status(status), url: check["url"]}]

      _other ->
        []
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_check_status(status) when status in ["passed", "success"], do: :passed
  defp normalize_check_status(status) when status in ["pending", "running"], do: :pending
  defp normalize_check_status(status) when status in ["failed", "failure"], do: :failed
  defp normalize_check_status(_status), do: :unknown

  defp checks_status([]), do: :passed

  defp checks_status(checks) do
    failed? = Enum.any?(checks, &(&1.status == :failed))
    pending? = Enum.any?(checks, &(&1.status in [:pending, :unknown]))

    case {failed?, pending?} do
      {true, _pending?} -> :failed
      {false, true} -> :pending
      {false, false} -> :passed
    end
  end

  defp normalize_mergeability(value) when value in [:mergeable, :conflicting, :unknown], do: value
  defp normalize_mergeability(_value), do: :unknown

  defp fake_status(metadata) do
    case {value(metadata, :merged?) == true, value(metadata, :closed?) == true} do
      {true, _closed?} -> :merged
      {false, true} -> :closed
      {false, false} -> :open
    end
  end

  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_string?(_value), do: false

  defp valid_sha?(sha) when is_binary(sha), do: Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, sha)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
