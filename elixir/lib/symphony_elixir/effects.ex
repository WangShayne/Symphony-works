defmodule SymphonyElixir.Effects do
  @moduledoc """
  Journals external mutation intent before execution and reconciles unknown outcomes.
  """

  import Ecto.Query

  alias SymphonyElixir.Audit.Redactor
  alias SymphonyElixir.Effects.{OperationId, Reconciler, Record}
  alias SymphonyElixir.Repo

  @default_wait_timeout 5_000
  @default_lease_ttl_ms 60_000
  @default_recovery_limit 100
  @poll_interval 10
  @runtime_owner_key {__MODULE__, :runtime_owner}
  @max_owner_bytes 255

  @type execute_error :: atom()

  @spec execute(map(), module()) :: {:ok, Record.t()} | {:error, execute_error()}
  def execute(attrs, adapter), do: execute(attrs, adapter, [])

  @spec execute(map(), module(), keyword()) :: {:ok, Record.t()} | {:error, execute_error()}
  def execute(attrs, adapter, opts) when is_map(attrs) and is_atom(adapter) and is_list(opts) do
    with {:ok, context} <- execution_context(opts),
         {:ok, normalized} <- normalize_attrs(attrs),
         {:ok, record} <- ensure_record(normalized) do
      dispatch(record, adapter, context)
    end
  end

  def execute(_attrs, _adapter, _opts), do: {:error, :invalid_effect}

  @spec get!(Ecto.UUID.t()) :: Record.t()
  def get!(operation_id), do: Repo.get!(Record, operation_id)

  @spec reconcile(Ecto.UUID.t(), module()) :: {:ok, Record.t()} | {:error, execute_error()}
  def reconcile(operation_id, adapter), do: reconcile(operation_id, adapter, [])

  @spec reconcile(Ecto.UUID.t(), module(), keyword()) ::
          {:ok, Record.t()} | {:error, execute_error()}
  def reconcile(operation_id, adapter, opts)
      when is_binary(operation_id) and is_atom(adapter) and is_list(opts) do
    with true <- OperationId.valid?(operation_id),
         {:ok, context} <- execution_context(opts),
         %Record{} = record <- Repo.get(Record, operation_id) do
      reconcile_dispatch(record, adapter, context)
    else
      false -> {:error, :invalid_operation_id}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def reconcile(_operation_id, _adapter, _opts), do: {:error, :invalid_effect}

  @spec recover_orphans(keyword()) ::
          {:ok,
           %{
             recovered: [Ecto.UUID.t()],
             pending: [Record.t()],
             remaining: non_neg_integer()
           }}
          | {:error, atom()}
  def recover_orphans(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, owner_id} <- normalize_owner(Keyword.get(opts, :owner_id)),
         {:ok, recovery_now} <- normalize_recovery_now(Keyword.get(opts, :now)),
         {:ok, limit} <- normalize_recovery_limit(Keyword.get(opts, :limit, @default_recovery_limit)),
         {:ok, result} <- do_recover_orphans(owner_id, recovery_now, limit) do
      :persistent_term.put(@runtime_owner_key, owner_id)
      {:ok, result}
    else
      false -> {:error, :invalid_recovery_options}
      {:error, _reason} = error -> error
    end
  end

  def recover_orphans(_opts), do: {:error, :invalid_recovery_options}

  @spec list(keyword() | map()) :: [Record.t()]
  def list(filters \\ []) do
    filters
    |> normalize_filters()
    |> Enum.reduce(Record, &apply_filter/2)
    |> order_by([record], asc: record.inserted_at, asc: record.operation_id)
    |> Repo.all()
  end

  defp normalize_attrs(attrs) do
    operation_id = fetch(attrs, :operation_id) || OperationId.generate()

    normalized = %{
      operation_id: operation_id,
      task_id: normalize_string(fetch(attrs, :task_id)),
      plan_revision: normalize_revision(fetch(attrs, :plan_revision)),
      unit_id: normalize_optional_string(fetch(attrs, :unit_id)),
      action: normalize_string(fetch(attrs, :action)),
      provider: normalize_string(fetch(attrs, :provider)),
      target: normalize_string(fetch(attrs, :target)),
      intent: attrs |> fetch(:intent) |> normalize_intent()
    }

    cond do
      not OperationId.valid?(operation_id) ->
        {:error, :invalid_operation_id}

      Enum.any?([:task_id, :action, :provider, :target], &(Map.fetch!(normalized, &1) == nil)) ->
        {:error, :invalid_effect}

      normalized.plan_revision == nil ->
        {:error, :invalid_effect}

      Redactor.contains_registered_secret?(normalized.target) ->
        {:error, :sensitive_target}

      true ->
        {:ok, Map.put(normalized, :dedupe_hash, OperationId.dedupe_hash(normalized))}
    end
  end

  defp ensure_record(attrs) do
    changeset = Record.create_changeset(%Record{}, Map.put(attrs, :status, :planned))

    if changeset.valid? do
      persist_record(attrs, changeset)
    else
      {:error, :invalid_effect}
    end
  end

  defp persist_record(attrs, changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> {:ok, record}
      {:error, _changeset} -> resolve_insert_conflict(attrs)
    end
  catch
    kind, _reason when kind in [:error, :exit] -> {:error, :effect_persistence_failed}
  end

  defp resolve_insert_conflict(attrs) do
    case Repo.get(Record, attrs.operation_id) do
      %Record{dedupe_hash: dedupe_hash} = record when dedupe_hash == attrs.dedupe_hash ->
        {:ok, record}

      %Record{} ->
        {:error, :operation_id_conflict}

      nil ->
        case Repo.get_by(Record, dedupe_hash: attrs.dedupe_hash) do
          %Record{} = record -> {:ok, record}
        end
    end
  end

  defp dispatch(%Record{status: :planned} = record, adapter, context) do
    case claim(record, :planned, context) do
      {:ok, claimed} ->
        run_non_interruptible(claimed, context, &execute_and_record(&1, adapter, context))

      :lost ->
        record.operation_id |> get!() |> dispatch(adapter, context)
    end
  end

  defp dispatch(%Record{status: :unknown} = record, adapter, context) do
    case claim(record, :unknown, context) do
      {:ok, claimed} ->
        run_non_interruptible(claimed, context, fn current ->
          reconcile_and_record(current, record, adapter, context)
        end)

      :lost ->
        record.operation_id |> get!() |> dispatch(adapter, context)
    end
  end

  defp dispatch(%Record{status: :started} = record, adapter, context),
    do: wait_for_terminal(record.operation_id, adapter, context)

  defp dispatch(%Record{status: :succeeded} = record, _adapter, _context), do: {:ok, record}

  defp dispatch(%Record{status: :failed} = record, adapter, context) do
    transition_now = current_time(context)

    Record
    |> where([effect], effect.operation_id == ^record.operation_id and effect.status == :failed)
    |> Repo.update_all(
      set: [
        status: :planned,
        error: nil,
        completed_at: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        updated_at: transition_now
      ]
    )

    record.operation_id |> get!() |> dispatch(adapter, context)
  end

  defp claim(record, expected_status, context) do
    claim_now = current_time(context)
    lease_expires_at = DateTime.add(claim_now, context.lease_ttl_ms, :millisecond)

    {count, _rows} =
      Record
      |> where(
        [effect],
        effect.operation_id == ^record.operation_id and effect.status == ^expected_status
      )
      |> Repo.update_all(
        set: [
          status: :started,
          started_at: claim_now,
          completed_at: nil,
          error: nil,
          lease_owner: context.owner_id,
          lease_expires_at: lease_expires_at,
          updated_at: claim_now
        ]
      )

    if count == 1, do: {:ok, get!(record.operation_id)}, else: :lost
  end

  defp run_non_interruptible(record, context, operation) do
    caller = self()
    result_ref = make_ref()

    {_pid, monitor_ref} =
      spawn_monitor(fn ->
        result = operation.(record)
        send(caller, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        mark_unknown_if_started(record.operation_id, :interrupted, context)
        {:error, :interrupted}
    after
      context.wait_timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :in_progress}
    end
  end

  defp execute_and_record(record, adapter, context) do
    adapter
    |> safe_execute(record)
    |> case do
      {:ok, result} -> record_succeeded(record.operation_id, result, context)
      {:error, reason} -> record_failed(record.operation_id, reason, context)
      {:unknown, reason} -> record_unknown(record.operation_id, reason, context)
    end
  end

  defp reconcile_and_record(claimed, unknown_record, adapter, context) do
    case Reconciler.reconcile(adapter, unknown_record) do
      :already_applied -> record_succeeded(claimed.operation_id, :already_applied, context)
      {:applied, result} -> record_succeeded(claimed.operation_id, result, context)
      :not_applied -> execute_and_record(claimed, adapter, context)
      {:unknown, reason} -> record_unknown(claimed.operation_id, reason, context)
    end
  end

  defp safe_execute(adapter, record) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute, 1) do
      adapter.execute(record)
      |> normalize_execute_result()
    else
      {:unknown, :adapter_unavailable}
    end
  rescue
    _exception -> {:unknown, :interrupted}
  catch
    _kind, _reason -> {:unknown, :interrupted}
  end

  defp normalize_execute_result({:ok, result}), do: {:ok, result}
  defp normalize_execute_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_execute_result({:unknown, reason}) when is_atom(reason), do: {:unknown, reason}
  defp normalize_execute_result(_result), do: {:unknown, :invalid_adapter_result}

  defp record_succeeded(operation_id, result, context) do
    transition_now = current_time(context)

    update_status(operation_id,
      status: :succeeded,
      result: encode_result(result),
      error: nil,
      completed_at: transition_now,
      lease_owner: nil,
      lease_expires_at: nil,
      updated_at: transition_now
    )

    {:ok, get!(operation_id)}
  end

  defp record_failed(operation_id, reason, context) do
    transition_now = current_time(context)
    reason = safe_reason(reason, :adapter_failed)

    update_status(operation_id,
      status: :failed,
      result: nil,
      error: %{"code" => Atom.to_string(reason)},
      completed_at: transition_now,
      lease_owner: nil,
      lease_expires_at: nil,
      updated_at: transition_now
    )

    {:error, reason}
  end

  defp record_unknown(operation_id, reason, context) do
    reason = safe_reason(reason, :interrupted)

    update_status(operation_id,
      status: :unknown,
      result: nil,
      error: %{"code" => Atom.to_string(reason)},
      completed_at: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      updated_at: current_time(context)
    )

    {:error, reason}
  end

  defp mark_unknown_if_started(operation_id, reason, context) do
    reason = safe_reason(reason, :interrupted)

    Record
    |> where([effect], effect.operation_id == ^operation_id and effect.status == :started)
    |> Repo.update_all(
      set: [
        status: :unknown,
        error: %{"code" => Atom.to_string(reason)},
        lease_owner: nil,
        lease_expires_at: nil,
        updated_at: current_time(context)
      ]
    )

    :ok
  end

  defp update_status(operation_id, values) do
    Record
    |> where([effect], effect.operation_id == ^operation_id and effect.status == :started)
    |> Repo.update_all(set: values)
  end

  defp reconcile_dispatch(%Record{status: :unknown} = record, adapter, context),
    do: dispatch(record, adapter, context)

  defp reconcile_dispatch(%Record{status: :started} = record, adapter, context) do
    current = recover_started_if_orphan(record, context)

    if current.status == :started,
      do: {:error, :in_progress},
      else: reconcile_dispatch(current, adapter, context)
  end

  defp reconcile_dispatch(%Record{status: :succeeded} = record, _adapter, _context),
    do: {:ok, record}

  defp reconcile_dispatch(%Record{}, _adapter, _context), do: {:error, :not_reconcilable}

  defp recover_started_if_orphan(record, context) do
    recovery_now = current_time(context)

    context.owner_id
    |> orphaned_started_query(recovery_now)
    |> where([effect], effect.operation_id == ^record.operation_id)
    |> Repo.update_all(
      set: [
        status: :unknown,
        result: nil,
        error: %{"code" => "orphaned"},
        completed_at: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        updated_at: recovery_now
      ]
    )

    get!(record.operation_id)
  end

  defp do_recover_orphans(owner_id, recovery_now, limit) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          operation_ids =
            owner_id
            |> orphaned_started_query(recovery_now)
            |> order_by([effect], asc: effect.started_at, asc: effect.operation_id)
            |> limit(^limit)
            |> select([effect], effect.operation_id)
            |> Repo.all()

          recover_operation_ids(operation_ids, owner_id, recovery_now)

          pending =
            Record
            |> where([effect], effect.operation_id in ^operation_ids)
            |> order_by([effect], asc: effect.started_at, asc: effect.operation_id)
            |> Repo.all()

          remaining =
            owner_id
            |> orphaned_started_query(recovery_now)
            |> Repo.aggregate(:count, :operation_id)

          %{
            recovered: Enum.map(pending, & &1.operation_id),
            pending: pending,
            remaining: remaining
          }
        end,
        mode: :immediate
      )

    {:ok, result}
  rescue
    _exception -> {:error, :recovery_failed}
  end

  defp recover_operation_ids([], _owner_id, _recovery_now), do: :ok

  defp recover_operation_ids(operation_ids, owner_id, recovery_now) do
    owner_id
    |> orphaned_started_query(recovery_now)
    |> where([effect], effect.operation_id in ^operation_ids)
    |> Repo.update_all(
      set: [
        status: :unknown,
        result: nil,
        error: %{"code" => "orphaned"},
        completed_at: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        updated_at: recovery_now
      ]
    )

    :ok
  end

  defp orphaned_started_query(owner_id, recovery_now) do
    from(effect in Record,
      where:
        effect.status == :started and
          (is_nil(effect.lease_owner) or effect.lease_owner != ^owner_id or
             is_nil(effect.lease_expires_at) or effect.lease_expires_at <= ^recovery_now)
    )
  end

  defp wait_for_terminal(operation_id, adapter, context) do
    deadline = System.monotonic_time(:millisecond) + context.wait_timeout
    wait_for_terminal(operation_id, adapter, context, deadline)
  end

  defp wait_for_terminal(operation_id, adapter, context, deadline) do
    record = get!(operation_id)

    case record.status do
      :started ->
        record
        |> recover_started_if_orphan(context)
        |> continue_wait_or_dispatch(operation_id, adapter, context, deadline)

      _terminal_or_retryable ->
        dispatch(record, adapter, context)
    end
  end

  defp continue_wait_or_dispatch(%Record{status: :started}, operation_id, adapter, context, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@poll_interval)
      wait_for_terminal(operation_id, adapter, context, deadline)
    else
      {:error, :in_progress}
    end
  end

  defp continue_wait_or_dispatch(%Record{} = record, _operation_id, adapter, context, _deadline) do
    dispatch(record, adapter, context)
  end

  defp encode_result(result) do
    case Redactor.redact(result) do
      value when is_map(value) -> value
      value -> %{"value" => value}
    end
  end

  defp normalize_intent(nil), do: %{}

  defp normalize_intent(value) do
    case Redactor.redact(value) do
      map when is_map(map) -> map
      other -> %{"value" => other}
    end
  end

  defp safe_reason(reason, fallback) when is_atom(reason) do
    value = Atom.to_string(reason)
    if Redactor.redact(value) == value, do: reason, else: fallback
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: normalize_string(value)

  defp normalize_revision(value) when is_integer(value) and value >= 0, do: value

  defp normalize_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} when revision >= 0 -> revision
      _other -> nil
    end
  end

  defp normalize_revision(_value), do: nil

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp execution_context(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, owner_id} <- execution_owner(opts),
           {:ok, lease_ttl_ms} <- normalize_lease_ttl(Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)),
           {:ok, execution_now} <- normalize_execution_now(Keyword.get(opts, :now)) do
        {:ok,
         %{
           owner_id: owner_id,
           lease_ttl_ms: lease_ttl_ms,
           now: execution_now,
           wait_timeout: wait_timeout(opts)
         }}
      end
    else
      {:error, :invalid_effect}
    end
  end

  defp execution_owner(opts) do
    case Keyword.fetch(opts, :owner_id) do
      {:ok, owner_id} -> normalize_owner(owner_id)
      :error -> {:ok, runtime_owner()}
    end
  end

  defp runtime_owner do
    case :persistent_term.get(@runtime_owner_key, :unbound) do
      :unbound ->
        owner_id = generated_runtime_owner()
        :persistent_term.put(@runtime_owner_key, owner_id)
        owner_id

      owner_id ->
        owner_id
    end
  end

  defp generated_runtime_owner do
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary({node(), System.pid()}))
      |> Base.url_encode64(padding: false)

    "runtime:" <> digest
  end

  defp normalize_owner(owner_id) when is_binary(owner_id) do
    normalized = String.trim(owner_id)

    if normalized != "" and byte_size(normalized) <= @max_owner_bytes,
      do: {:ok, normalized},
      else: {:error, :invalid_owner_id}
  end

  defp normalize_owner(_owner_id), do: {:error, :invalid_owner_id}

  defp normalize_lease_ttl(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_lease_ttl(_value), do: {:error, :invalid_lease_ttl}

  defp normalize_execution_now(nil), do: {:ok, :runtime}
  defp normalize_execution_now(value), do: normalize_timestamp(value)

  defp normalize_recovery_now(nil), do: {:ok, now()}
  defp normalize_recovery_now(value), do: normalize_timestamp(value)

  defp normalize_timestamp(%DateTime{utc_offset: 0, std_offset: 0} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp normalize_timestamp(_value), do: {:error, :invalid_now}

  defp normalize_recovery_limit(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_recovery_limit(_value), do: {:error, :invalid_recovery_options}

  defp current_time(%{now: :runtime}), do: now()
  defp current_time(%{now: %DateTime{} = value}), do: value

  defp wait_timeout(opts) do
    case Keyword.get(opts, :wait_timeout, @default_wait_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> @default_wait_timeout
    end
  end

  defp normalize_filters(filters) when is_map(filters), do: Map.to_list(filters)
  defp normalize_filters(filters) when is_list(filters), do: filters
  defp normalize_filters(_filters), do: []

  defp apply_filter({key, value}, query) when key in [:task_id, "task_id"],
    do: where(query, [effect], effect.task_id == ^value)

  defp apply_filter({key, value}, query) when key in [:status, "status"],
    do: where(query, [effect], effect.status == ^value)

  defp apply_filter({key, value}, query) when key in [:dedupe_hash, "dedupe_hash"],
    do: where(query, [effect], effect.dedupe_hash == ^value)

  defp apply_filter(_filter, query), do: query

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
