defmodule SymphonyElixir.EffectsTest do
  use SymphonyElixir.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Exqlite.Sqlite3
  alias SymphonyElixir.Effects
  alias SymphonyElixir.Effects.{OperationId, SimulatedAdapter}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore

  @adapter_state :symphony_effects_test_adapter_state

  setup do
    if :ets.whereis(@adapter_state) != :undefined, do: :ets.delete(@adapter_state)
    :ets.new(@adapter_state, [:named_table, :public, :set])

    on_exit(fn ->
      if :ets.whereis(@adapter_state) != :undefined, do: :ets.delete(@adapter_state)
    end)

    :ok
  end

  defmodule AdapterState do
    @moduledoc false
    @table :symphony_effects_test_adapter_state

    @spec record(atom()) :: :ok
    def record(event) do
      sequence = :ets.update_counter(@table, :event_sequence, {2, 1}, {:event_sequence, 0})
      true = :ets.insert(@table, {{:event, sequence}, event})
      :ok
    end

    @spec events() :: [atom()]
    def events do
      @table
      |> :ets.match_object({{:event, :_}, :_})
      |> Enum.sort_by(fn {{:event, sequence}, _event} -> sequence end)
      |> Enum.map(fn {_key, event} -> event end)
    end
  end

  defmodule PersistedIntentAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(record) do
      persisted = Effects.get!(record.operation_id)

      {:ok,
       %{
         "callback_fence" => record.fencing_token,
         "lookup_fence" => persisted.fencing_token,
         "persisted_status" => Atom.to_string(persisted.status)
       }}
    end

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule CountingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(record) do
      count =
        :ets.update_counter(
          :symphony_effects_test_adapter_state,
          :execute_count,
          {2, 1},
          {:execute_count, 0}
        )

      Process.sleep(25)
      {:ok, %{"count" => count, "operation_id" => record.operation_id}}
    end

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule CrashingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: no_return()
    def execute(_record) do
      AdapterState.record(:execute)
      raise "simulated interruption after mutation"
    end

    @spec reconcile(Effects.Record.t()) :: {:unknown, :not_observed}
    def reconcile(_record), do: {:unknown, :not_observed}
  end

  defmodule ReconcileAsAppliedAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(_record) do
      AdapterState.record(:unexpected_execute)
      {:ok, %{"unexpected" => true}}
    end

    @spec reconcile(Effects.Record.t()) :: {:ok, :already_applied}
    def reconcile(_record) do
      AdapterState.record(:reconcile)
      {:ok, :already_applied}
    end
  end

  defmodule ReconcileAsMissingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(_record) do
      AdapterState.record(:retry_execute)
      {:ok, %{"created" => true}}
    end

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record) do
      AdapterState.record(:reconcile_missing)
      {:ok, :not_applied}
    end
  end

  defmodule FenceObservingReconcileAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(_record), do: {:ok, %{"unexpected" => true}}

    @spec reconcile(Effects.Record.t()) :: {:ok, :already_applied}
    def reconcile(record) do
      [{:test_pid, test_pid}] = :ets.lookup(:symphony_effects_test_adapter_state, :test_pid)
      send(test_pid, {:reconcile_fencing_token, record.fencing_token})
      {:ok, :already_applied}
    end
  end

  defmodule BlockingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(_record) do
      [{:test_pid, test_pid}] = :ets.lookup(:symphony_effects_test_adapter_state, :test_pid)
      send(test_pid, {:adapter_started, self()})

      receive do
        :finish -> {:ok, %{"finished" => true}}
        {:finish, result} -> result
      end
    end

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule TerminalBoundaryAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(_record) do
      [{:test_pid, test_pid}] = :ets.lookup(:symphony_effects_test_adapter_state, :test_pid)
      send(test_pid, {:boundary_adapter_started, self()})

      receive do
        :finish ->
          send(test_pid, {:boundary_adapter_returned, self()})
          {:ok, %{"finished" => true}}
      end
    end

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule SecretCrashingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: no_return()
    def execute(_record) do
      [{:plaintext, plaintext}] = :ets.lookup(:symphony_effects_test_adapter_state, :plaintext)
      raise "provider failed with #{plaintext}"
    end

    @spec reconcile(Effects.Record.t()) :: {:unknown, :not_observed}
    def reconcile(_record), do: {:unknown, :not_observed}
  end

  defmodule FailingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:error, :provider_rejected}
    def execute(_record), do: {:error, :provider_rejected}

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule SecretAtomErrorAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:error, :registered_error_secret}
    def execute(_record), do: {:error, :registered_error_secret}

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule ReconciliationCoverageAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:unknown, :interrupted} | :invalid_execute_result
    def execute(record) do
      case record.intent["execute_mode"] do
        "invalid" -> :invalid_execute_result
        _mode -> {:unknown, :interrupted}
      end
    end

    @spec reconcile(Effects.Record.t()) :: term()
    def reconcile(record) do
      case record.intent["reconcile_mode"] do
        "bare_applied" -> :already_applied
        "applied" -> {:applied, %{"observed" => true}}
        "bare_missing" -> :not_applied
        "unknown" -> {:unknown, :still_unknown}
        "error" -> {:error, :reconcile_error}
        "raise" -> raise "reconciliation failed"
        "throw" -> throw(:reconciliation_failed)
        _mode -> :invalid_reconciliation_result
      end
    end
  end

  defmodule KillingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: no_return()
    def execute(_record), do: Process.exit(self(), :kill)

    @spec reconcile(Effects.Record.t()) :: {:unknown, :not_observed}
    def reconcile(_record), do: {:unknown, :not_observed}
  end

  defmodule ThrowingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: no_return()
    def execute(_record), do: throw(:adapter_threw)

    @spec reconcile(Effects.Record.t()) :: {:unknown, :not_observed}
    def reconcile(_record), do: {:unknown, :not_observed}
  end

  test "intent is persisted before an external mutation starts" do
    operation_id = OperationId.generate()
    hidden_token = Ecto.UUID.generate()

    fence = %Effects.Fence{
      operation_id: operation_id,
      owner_id: "orchestrator-inspect",
      token: hidden_token,
      ttl_ms: 60_000
    }

    assert inspect(fence) =~ operation_id
    refute inspect(fence) =~ hidden_token

    assert {:ok, executed} = Effects.execute(effect_attrs(operation_id), PersistedIntentAdapter)

    assert executed.result == %{
             "callback_fence" => nil,
             "lookup_fence" => nil,
             "persisted_status" => "started"
           }

    assert {:ok, already_reconciled} = Effects.reconcile(operation_id, PersistedIntentAdapter)
    assert already_reconciled.operation_id == operation_id

    record = Effects.get!(operation_id)
    assert record.status == :succeeded
    assert record.fencing_token == nil
    refute inspect(record) =~ "fencing_token"

    assert record.result == %{
             "callback_fence" => nil,
             "lookup_fence" => nil,
             "persisted_status" => "started"
           }
  end

  test "operation identity is UUIDv7 and dedupe covers the stable mutation tuple" do
    first = effect_attrs(OperationId.generate())
    second = %{first | operation_id: OperationId.generate(), intent: %{"different" => true}}

    assert OperationId.valid?(first.operation_id)
    assert String.at(first.operation_id, 14) == "7"
    assert OperationId.dedupe_hash(first) == OperationId.dedupe_hash(second)

    refute OperationId.dedupe_hash(first) ==
             OperationId.dedupe_hash(%{second | target: "repo#different-head"})

    refute OperationId.valid?(:not_a_uuid)

    typed = %{
      task_id: nil,
      plan_revision: true,
      unit_id: false,
      action: 1.25,
      provider: [1, "provider"],
      target: %{z: self(), a: [nil, false, 2.5]}
    }

    reordered = %{typed | target: %{a: [nil, false, 2.5], z: self()}}
    assert OperationId.dedupe_hash(typed) == OperationId.dedupe_hash(reordered)
  end

  test "invalid effects and operation collisions fail through the public boundary" do
    assert {:error, :invalid_effect} = Effects.execute(:invalid, PersistedIntentAdapter)
    assert {:error, :invalid_effect} = Effects.execute(%{}, PersistedIntentAdapter, :invalid_opts)

    missing_operation_id = OperationId.generate()

    assert {:error, :invalid_operation_id} =
             Effects.reconcile("not-a-uuid", PersistedIntentAdapter, [])

    assert {:error, :not_found} =
             Effects.reconcile(missing_operation_id, PersistedIntentAdapter, [])

    assert {:error, :invalid_owner_id} =
             Effects.reconcile(missing_operation_id, PersistedIntentAdapter, owner_id: :invalid)

    assert {:error, :invalid_effect} = Effects.reconcile(:invalid, PersistedIntentAdapter, [])

    assert {:error, :invalid_owner_id} =
             Effects.execute(effect_attrs(OperationId.generate()), PersistedIntentAdapter, owner_id: :invalid)

    assert {:error, :invalid_lease_ttl} =
             Effects.execute(effect_attrs(OperationId.generate()), PersistedIntentAdapter, lease_ttl_ms: 0)

    assert {:error, :invalid_now} =
             Effects.execute(effect_attrs(OperationId.generate()), PersistedIntentAdapter, now: :invalid)

    assert {:error, :invalid_recovery_options} = Effects.recover_orphans([:invalid])
    assert {:error, :invalid_recovery_options} = Effects.recover_orphans(:invalid)
    assert {:error, :invalid_owner_id} = Effects.recover_orphans(owner_id: :invalid)
    assert {:error, :invalid_now} = Effects.recover_orphans(owner_id: "owner", now: :invalid)

    assert {:error, :invalid_recovery_options} =
             Effects.recover_orphans(owner_id: "owner", limit: 0)

    assert {:error, :invalid_operation_id} =
             Effects.execute(effect_attrs("not-a-uuid"), PersistedIntentAdapter)

    assert {:error, :invalid_effect} =
             OperationId.generate()
             |> effect_attrs()
             |> Map.put(:task_id, " ")
             |> Effects.execute(PersistedIntentAdapter)

    assert {:error, :invalid_effect} =
             OperationId.generate()
             |> effect_attrs()
             |> Map.put(:plan_revision, "not-an-integer")
             |> Effects.execute(PersistedIntentAdapter)

    assert {:error, :invalid_effect} =
             OperationId.generate()
             |> effect_attrs()
             |> Map.put(:plan_revision, :not_an_integer)
             |> Map.put(:provider, 123)
             |> Effects.execute(PersistedIntentAdapter)

    assert {:error, :invalid_effect} =
             OperationId.generate()
             |> effect_attrs()
             |> Map.put(:task_id, String.duplicate("t", 256))
             |> Effects.execute(PersistedIntentAdapter)

    operation_id = OperationId.generate()
    assert {:ok, _record} = Effects.execute(effect_attrs(operation_id), PersistedIntentAdapter)

    assert {:error, :operation_id_conflict} =
             operation_id
             |> effect_attrs()
             |> Map.put(:target, "repo#different-operation")
             |> Effects.execute(PersistedIntentAdapter)

    string_revision_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:plan_revision, "2")
      |> Map.put(:target, "repo#string-revision")

    assert {:ok, string_revision} = Effects.execute(string_revision_attrs, PersistedIntentAdapter)
    assert string_revision.plan_revision == 2
  end

  test "public execution without owner id generates and reuses a runtime owner" do
    runtime_owner_key = {Effects, :runtime_owner}
    :persistent_term.erase(runtime_owner_key)
    on_exit(fn -> :persistent_term.erase(runtime_owner_key) end)

    assert {:ok, first} =
             Effects.execute(effect_attrs(OperationId.generate()), PersistedIntentAdapter)

    owner_id = :persistent_term.get(runtime_owner_key)
    assert first.status == :succeeded
    assert is_binary(owner_id)
    assert String.starts_with?(owner_id, "runtime:")

    assert {:ok, second} =
             Effects.execute(effect_attrs(OperationId.generate()), PersistedIntentAdapter)

    assert second.status == :succeeded
    assert :persistent_term.get(runtime_owner_key) == owner_id
  end

  test "effect persistence failures return a stable domain error" do
    assert {:ok, locker} = Sqlite3.open(Repo.config()[:database], mode: :readwrite)

    try do
      assert :ok = Sqlite3.execute(locker, "PRAGMA busy_timeout = 0")
      assert :ok = Sqlite3.execute(locker, "BEGIN IMMEDIATE")

      assert {:error, :effect_persistence_failed} =
               Effects.execute(effect_attrs(OperationId.generate()), PersistedIntentAdapter)
    after
      _rollback = Sqlite3.execute(locker, "ROLLBACK")
      assert :ok = Sqlite3.close(locker)
    end

    assert Effects.list() == []
  end

  test "effect listing accepts supported map/keyword filters and ignores unknown filters" do
    first_attrs = effect_attrs(OperationId.generate())

    second_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:task_id, "task-2")
      |> Map.put(:target, "repo#task-2")

    assert {:ok, first} = Effects.execute(first_attrs, PersistedIntentAdapter)
    assert {:ok, second} = Effects.execute(second_attrs, PersistedIntentAdapter)

    assert Effects.list() |> Enum.map(& &1.operation_id) |> MapSet.new() ==
             MapSet.new([first.operation_id, second.operation_id])

    assert Enum.map(Effects.list(%{task_id: "task-2"}), & &1.operation_id) == [second.operation_id]

    assert Effects.list(status: :succeeded) |> Enum.map(& &1.operation_id) |> MapSet.new() ==
             MapSet.new([first.operation_id, second.operation_id])

    assert Enum.map(Effects.list(dedupe_hash: first.dedupe_hash), & &1.operation_id) == [first.operation_id]
    assert length(Effects.list(unknown: "ignored")) == 2
    assert length(Effects.list(:invalid_filters)) == 2
  end

  test "optional values and invalid wait options normalize without bypassing journaling" do
    nil_intent_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "repo#nil-intent")
      |> Map.put(:unit_id, nil)
      |> Map.put(:intent, nil)

    assert {:ok, nil_intent} =
             Effects.execute(nil_intent_attrs, PersistedIntentAdapter, wait_timeout: :invalid)

    assert nil_intent.unit_id == nil
    assert nil_intent.intent == %{}

    scalar_intent_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "repo#scalar-intent")
      |> Map.put(:intent, 42)

    assert {:ok, scalar_intent} = Effects.execute(scalar_intent_attrs, PersistedIntentAdapter)
    assert scalar_intent.intent == %{"value" => 42}
  end

  test "an available adapter is loaded before callback discovery" do
    adapter = Module.concat(__MODULE__, "FreshLoadAdapter")
    directory = Path.join(System.tmp_dir!(), "symphony-fresh-adapter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    [{^adapter, beam}] =
      Code.compile_string("""
      defmodule #{inspect(adapter)} do
        def execute(record), do: {:ok, %{"fresh" => record.operation_id}}
        def reconcile(_record), do: {:ok, :not_applied}
      end
      """)

    beam_path = Path.join(directory, "#{adapter}.beam")
    File.write!(beam_path, beam)
    :code.purge(adapter)
    :code.delete(adapter)
    true = Code.prepend_path(String.to_charlist(directory))

    on_exit(fn ->
      :code.purge(adapter)
      :code.delete(adapter)
      Code.delete_path(String.to_charlist(directory))
      File.rm(beam_path)
      File.rmdir(directory)
    end)

    assert :code.is_loaded(adapter) == false

    attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "repo#fresh-adapter")

    assert {:ok, record} = Effects.execute(attrs, adapter)
    assert record.status == :succeeded
    assert record.result["fresh"] == record.operation_id
  end

  test "simulated adapter covers deterministic success, failure, and reconciliation outcomes" do
    assert {:ok, success} =
             OperationId.generate()
             |> effect_attrs()
             |> Map.put(:target, "simulated#success")
             |> Effects.execute(SimulatedAdapter)

    assert success.result["status"] == "simulated"

    failure_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "simulated#failure")
      |> put_in([:intent], %{"simulate" => "failure"})

    assert {:error, :simulated_failure} = Effects.execute(failure_attrs, SimulatedAdapter)

    applied_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "simulated#applied")
      |> put_in([:intent], %{"simulate" => "unknown", "reconcile" => "already_applied"})

    assert {:error, :interrupted} = Effects.execute(applied_attrs, SimulatedAdapter)
    assert {:ok, applied} = Effects.execute(applied_attrs, SimulatedAdapter)
    assert applied.result == %{"value" => "already_applied"}

    missing_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "simulated#missing")
      |> put_in([:intent], %{"simulate" => "unknown", "reconcile" => "not_applied"})

    assert {:error, :interrupted} = Effects.execute(missing_attrs, SimulatedAdapter)
    assert {:error, :interrupted} = Effects.execute(missing_attrs, SimulatedAdapter)

    unobserved_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "simulated#unobserved")
      |> put_in([:intent], %{"simulate" => "unknown"})

    assert {:error, :interrupted} = Effects.execute(unobserved_attrs, SimulatedAdapter)
    assert {:error, :not_observed} = Effects.execute(unobserved_attrs, SimulatedAdapter)
  end

  test "concurrent identical dedupe keys invoke the adapter once" do
    attrs = effect_attrs(OperationId.generate())

    records =
      1..8
      |> Task.async_stream(
        fn _index ->
          attrs
          |> Map.put(:operation_id, OperationId.generate())
          |> Effects.execute(CountingAdapter)
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, record}} -> record end)

    assert records |> Enum.map(& &1.operation_id) |> Enum.uniq() |> length() == 1
    assert :ets.lookup(@adapter_state, :execute_count) == [{:execute_count, 1}]
  end

  test "concurrent callers coalesce while retrying a definitively failed effect" do
    attrs = effect_attrs(OperationId.generate()) |> Map.put(:target, "repo#failed-retry")
    assert {:error, :provider_rejected} = Effects.execute(attrs, FailingAdapter)

    records =
      1..8
      |> Task.async_stream(
        fn _index -> Effects.execute(attrs, CountingAdapter) end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, record}} -> record end)

    assert records |> Enum.map(& &1.operation_id) |> Enum.uniq() |> length() == 1
    assert :ets.lookup(@adapter_state, :execute_count) == [{:execute_count, 1}]
  end

  test "unknown external outcome is reconciled before retry" do
    operation_id = OperationId.generate()
    attrs = effect_attrs(operation_id)

    assert {:error, :interrupted} = Effects.execute(attrs, CrashingAdapter)
    assert Effects.get!(operation_id).status == :unknown

    assert {:ok, record} = Effects.execute(attrs, ReconcileAsAppliedAdapter)
    assert record.status == :succeeded
    assert record.result == %{"value" => "already_applied"}
    assert AdapterState.events() == [:execute, :reconcile]
  end

  test "concurrent retries of one unknown outcome reconcile once" do
    attrs = effect_attrs(OperationId.generate()) |> Map.put(:target, "repo#concurrent-reconcile")
    assert {:error, :interrupted} = Effects.execute(attrs, CrashingAdapter)

    records =
      1..8
      |> Task.async_stream(
        fn _index -> Effects.execute(attrs, ReconcileAsAppliedAdapter) end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, record}} -> record end)

    assert records |> Enum.map(& &1.operation_id) |> Enum.uniq() |> length() == 1
    assert AdapterState.events() == [:execute, :reconcile]
  end

  test "startup recovers a foreign-owner started orphan and reconciles without executing again" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "repo#restart-orphan")

    orphan = orphan_started(attrs, "orchestrator-before-restart")
    assert orphan.status == :started
    assert orphan.lease_owner == "orchestrator-before-restart"

    now = DateTime.utc_now()

    assert {:ok, %{recovered: [^operation_id], pending: [pending], remaining: 0}} =
             Effects.recover_orphans(
               owner_id: "orchestrator-after-restart",
               now: now,
               limit: 10
             )

    assert pending.status == :unknown
    assert pending.error == %{"code" => "orphaned"}

    assert {:ok, reconciled} =
             Effects.reconcile(
               operation_id,
               ReconcileAsAppliedAdapter,
               owner_id: "orchestrator-after-restart",
               now: now
             )

    assert reconciled.status == :succeeded
    assert AdapterState.events() == [:reconcile]

    next_operation_id = OperationId.generate()

    caller =
      Task.async(fn ->
        next_operation_id
        |> effect_attrs()
        |> Map.put(:target, "repo#bound-owner")
        |> Effects.execute(BlockingAdapter)
      end)

    assert_receive {:adapter_started, adapter_process}
    assert Effects.get!(next_operation_id).lease_owner == "orchestrator-after-restart"
    send(adapter_process, :finish)
    assert {:ok, _completed} = Task.await(caller)
  end

  test "startup recovery cannot steal a live foreign-owner lease" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "repo#live-lease")

    caller =
      Task.async(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: "current-orchestrator",
          lease_ttl_ms: 60_000
        )
      end)

    assert_receive {:adapter_started, adapter_process}

    assert {:ok, %{recovered: [], pending: [], remaining: 0, next_check_at: next_check_at}} =
             Effects.recover_orphans(
               owner_id: "takeover-orchestrator",
               now: DateTime.utc_now(),
               limit: 10
             )

    assert DateTime.compare(next_check_at, DateTime.utc_now()) == :gt

    assert {:error, :in_progress} =
             Effects.reconcile(operation_id, ReconcileAsAppliedAdapter, owner_id: "takeover-orchestrator")

    send(adapter_process, :finish)
    assert {:ok, completed} = Task.await(caller)
    assert completed.status == :succeeded
  end

  test "direct execute and reconcile recover stranded started effects before retry" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})

    reconcile_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "repo#direct-reconcile-orphan")

    execute_attrs =
      OperationId.generate()
      |> effect_attrs()
      |> Map.put(:target, "repo#direct-execute-orphan")

    reconcile_orphan = orphan_started(reconcile_attrs, "old-direct-owner")
    assert %{status: :started} = orphan_started(execute_attrs, "old-direct-owner")

    assert {:ok, reconciled} =
             Effects.reconcile(reconcile_orphan.operation_id, ReconcileAsAppliedAdapter, owner_id: "new-direct-owner")

    assert reconciled.status == :succeeded

    assert {:ok, executed} =
             Effects.execute(execute_attrs, ReconcileAsAppliedAdapter, owner_id: "new-direct-owner")

    assert executed.status == :succeeded
    assert AdapterState.events() == [:reconcile, :reconcile]
  end

  test "startup orphan recovery is bounded, oldest-first, and reports remaining work" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    old_owner = "orchestrator-old-batch"

    records =
      Enum.map(1..3, fn index ->
        attrs =
          OperationId.generate()
          |> effect_attrs()
          |> Map.put(:target, "repo#orphan-batch-#{index}")

        orphan = orphan_started(attrs, old_owner)
        Process.sleep(2)
        orphan
      end)

    assert {:ok, %{recovered: recovered, pending: pending, remaining: 1}} =
             Effects.recover_orphans(owner_id: "orchestrator-new-batch", limit: 2)

    expected = records |> Enum.take(2) |> Enum.map(& &1.operation_id)
    assert recovered == expected
    assert Enum.map(pending, & &1.operation_id) == expected

    Enum.each(pending, fn record ->
      assert {:ok, reconciled} =
               Effects.reconcile(record.operation_id, ReconcileAsAppliedAdapter, owner_id: "orchestrator-new-batch")

      assert reconciled.status == :succeeded
    end)

    assert {:ok, %{recovered: [last_id], pending: [last], remaining: 0}} =
             Effects.recover_orphans(owner_id: "orchestrator-new-batch", limit: 2)

    assert last_id == List.last(records).operation_id
    assert last.operation_id == last_id
  end

  test "orphan recovery reports a stable error when durable storage is unavailable" do
    assert {:ok, _result} =
             SQL.query(Repo, "alter table effect_records rename to unavailable_effect_records", [])

    assert {:error, :recovery_failed} =
             Effects.recover_orphans(owner_id: "orchestrator-storage-failure")
  end

  test "all normalized reconciliation outcomes preserve reconcile-before-retry" do
    scenarios = [
      {"bare_applied", {:ok, :succeeded, %{"value" => "already_applied"}}},
      {"applied", {:ok, :succeeded, %{"observed" => true}}},
      {"bare_missing", {:error, :interrupted}},
      {"unknown", {:error, :still_unknown}},
      {"error", {:error, :reconcile_error}},
      {"invalid", {:error, :invalid_reconciliation}},
      {"raise", {:error, :reconciliation_failed}},
      {"throw", {:error, :reconciliation_failed}}
    ]

    Enum.each(scenarios, fn {mode, expected} ->
      attrs = reconciliation_attrs(mode)
      assert {:error, :interrupted} = Effects.execute(attrs, ReconciliationCoverageAdapter)

      case {Effects.execute(attrs, ReconciliationCoverageAdapter), expected} do
        {{:ok, record}, {:ok, status, result}} ->
          assert record.status == status
          assert record.result == result

        {actual, expected_error} ->
          assert actual == expected_error
      end
    end)
  end

  test "malformed adapter results become unknown without exposing the returned term" do
    attrs =
      "invalid-execute"
      |> reconciliation_attrs()
      |> put_in([:intent, "execute_mode"], "invalid")

    assert {:error, :invalid_adapter_result} =
             Effects.execute(attrs, ReconciliationCoverageAdapter)

    assert Effects.get!(attrs.operation_id).error == %{"code" => "invalid_adapter_result"}
  end

  test "an untrappable adapter exit records unknown through the monitor path" do
    operation_id = OperationId.generate()

    assert {:error, :interrupted} =
             operation_id
             |> effect_attrs()
             |> Map.put(:target, "adapter#killed")
             |> Effects.execute(KillingAdapter)

    assert Effects.get!(operation_id).status == :unknown
  end

  test "a thrown adapter term is sanitized by the execute catch path" do
    operation_id = OperationId.generate()

    assert {:error, :interrupted} =
             operation_id
             |> effect_attrs()
             |> Map.put(:target, "adapter#throw")
             |> Effects.execute(ThrowingAdapter)

    assert Effects.get!(operation_id).error == %{"code" => "interrupted"}
  end

  test "retry executes only after reconciliation proves the mutation is absent" do
    operation_id = OperationId.generate()
    attrs = effect_attrs(operation_id)

    assert {:error, :interrupted} = Effects.execute(attrs, CrashingAdapter)
    assert {:ok, record} = Effects.execute(attrs, ReconcileAsMissingAdapter)

    assert record.status == :succeeded
    assert record.result == %{"created" => true}
    assert AdapterState.events() == [:execute, :reconcile_missing, :retry_execute]
  end

  test "the started-to-recorded window survives caller cancellation" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = effect_attrs(operation_id)

    caller = spawn(fn -> Effects.execute(attrs, BlockingAdapter) end)

    assert_receive {:adapter_started, adapter_process}
    assert Effects.get!(operation_id).status == :started

    Process.exit(caller, :kill)
    send(adapter_process, :finish)

    assert eventually(fn -> Effects.get!(operation_id).status == :succeeded end)
    assert Effects.get!(operation_id).result == %{"finished" => true}
  end

  test "the non-interruptible worker heartbeats after its caller is lost" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "adapter#caller-loss-heartbeat")
    owner_id = "orchestrator-caller-loss"

    caller =
      spawn(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: owner_id,
          lease_ttl_ms: 60
        )
      end)

    assert_receive {:adapter_started, adapter_process}
    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

    Process.sleep(180)
    recovery = Effects.recover_orphans(owner_id: owner_id, now: DateTime.utc_now(), limit: 10)

    adapter_monitor = Process.monitor(adapter_process)
    send(adapter_process, :finish)
    assert_receive {:DOWN, ^adapter_monitor, :process, ^adapter_process, :normal}

    assert {:ok, %{recovered: [], pending: [], remaining: 0}} = recovery
    assert Effects.get!(operation_id).status == :succeeded
  end

  test "terminal recording waits for a synchronized heartbeat shutdown" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "adapter#terminal-boundary")

    caller =
      Task.async(fn ->
        Effects.execute(attrs, TerminalBoundaryAdapter,
          owner_id: "orchestrator-terminal-boundary",
          lease_ttl_ms: 60_000
        )
      end)

    assert_receive {:boundary_adapter_started, worker}
    assert {:links, [heartbeat]} = Process.info(worker, :links)
    true = :erlang.suspend_process(heartbeat)

    blocked_state =
      try do
        send(worker, :finish)
        assert_receive {:boundary_adapter_returned, ^worker}
        Process.sleep(20)
        {Effects.get!(operation_id).status, Process.alive?(worker)}
      after
        true = :erlang.resume_process(heartbeat)
      end

    assert blocked_state == {:started, true}
    assert {:ok, completed} = Task.await(caller)
    assert completed.status == :succeeded
  end

  test "a stale same-owner worker cannot overwrite a newer effect claim" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "adapter#fenced-claim")
    owner_id = "orchestrator-stable-owner"

    first_caller =
      Task.async(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: owner_id,
          lease_ttl_ms: 60_000,
          wait_timeout: 1
        )
      end)

    assert_receive {:adapter_started, stale_worker}
    assert {:error, :in_progress} = Task.await(first_caller)

    operation_id
    |> Effects.get!()
    |> Ecto.Changeset.change(status: :unknown, lease_owner: nil, lease_expires_at: nil)
    |> Repo.update!()

    current_caller =
      Task.async(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: owner_id,
          lease_ttl_ms: 60_000
        )
      end)

    assert_receive {:adapter_started, current_worker}
    stale_monitor = Process.monitor(stale_worker)
    send(stale_worker, :finish)
    assert_receive {:DOWN, ^stale_monitor, :process, ^stale_worker, :normal}

    record = Effects.get!(operation_id)
    assert record.status == :started
    assert record.lease_owner == owner_id

    send(current_worker, :finish)
    assert {:ok, completed} = Task.await(current_caller)
    assert completed.status == :succeeded
  end

  test "a worker with the wrong fence cannot record a terminal outcome" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    owner_id = "orchestrator-wrong-fence"

    outcomes = [
      {:ok, %{"finished" => true}},
      {:error, :provider_rejected},
      {:unknown, :interrupted}
    ]

    Enum.each(outcomes, fn outcome ->
      operation_id = OperationId.generate()
      target = "adapter#wrong-fence-#{elem(outcome, 0)}"
      attrs = operation_id |> effect_attrs() |> Map.put(:target, target)

      caller =
        Task.async(fn ->
          Effects.execute(attrs, BlockingAdapter,
            owner_id: owner_id,
            lease_ttl_ms: 60_000,
            wait_timeout: 1
          )
        end)

      assert_receive {:adapter_started, adapter_process}
      assert {:error, :in_progress} = Task.await(caller)

      Effects.Record
      |> Repo.get!(operation_id)
      |> Ecto.Changeset.change(fencing_token: Ecto.UUID.generate())
      |> Repo.update!()

      adapter_monitor = Process.monitor(adapter_process)
      send(adapter_process, {:finish, outcome})
      assert_receive {:DOWN, ^adapter_monitor, :process, ^adapter_process, :normal}

      stranded = Effects.get!(operation_id)
      assert stranded.status == :started
      assert stranded.result == nil

      assert {:ok, %{recovered: [^operation_id], pending: [unknown], remaining: 0}} =
               Effects.recover_orphans(
                 owner_id: owner_id,
                 now: DateTime.add(DateTime.utc_now(), 61, :second),
                 limit: 10
               )

      assert unknown.status == :unknown
      assert unknown.result == nil
    end)
  end

  test "heartbeat authority loss terminates the worker without writing through an expired fence" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "adapter#heartbeat-fence-loss")
    owner_id = "orchestrator-heartbeat-fence-loss"

    caller =
      Task.async(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: owner_id,
          lease_ttl_ms: 90,
          wait_timeout: 1
        )
      end)

    assert_receive {:adapter_started, adapter_process}
    assert {:error, :in_progress} = Task.await(caller)
    adapter_monitor = Process.monitor(adapter_process)

    Effects.Record
    |> Repo.get!(operation_id)
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert_receive {:DOWN, ^adapter_monitor, :process, ^adapter_process, :killed}

    Process.sleep(20)
    stranded = Effects.get!(operation_id)
    assert stranded.status == :started
    assert stranded.error == nil

    assert {:ok, %{recovered: [^operation_id], pending: [unknown], remaining: 0}} =
             Effects.recover_orphans(
               owner_id: "orchestrator-after-heartbeat-fence-loss",
               now: DateTime.utc_now(),
               limit: 10
             )

    assert unknown.status == :unknown
    assert unknown.error == %{"code" => "orphaned"}
  end

  test "reconciliation callbacks never receive a persisted fencing token" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "adapter#reconcile-fence-redaction")

    assert {:error, :interrupted} = Effects.execute(attrs, CrashingAdapter)
    persisted_token = Ecto.UUID.generate()

    Effects.Record
    |> Repo.get!(operation_id)
    |> Ecto.Changeset.change(fencing_token: persisted_token)
    |> Repo.update!()

    assert Repo.get!(Effects.Record, operation_id).fencing_token == persisted_token

    assert {:ok, completed} =
             Effects.reconcile(operation_id, FenceObservingReconcileAdapter, owner_id: "orchestrator-reconcile-fence-redaction")

    assert_receive {:reconcile_fencing_token, nil}
    assert completed.status == :succeeded
  end

  test "a waiting caller may time out without interrupting the effect worker" do
    true = :ets.insert(@adapter_state, {:test_pid, self()})
    operation_id = OperationId.generate()
    attrs = operation_id |> effect_attrs() |> Map.put(:target, "adapter#timeout")

    assert {:error, :in_progress} = Effects.execute(attrs, BlockingAdapter, wait_timeout: 1)
    assert_receive {:adapter_started, adapter_process}
    assert Effects.get!(operation_id).status == :started

    send(adapter_process, :finish)
    assert eventually(fn -> Effects.get!(operation_id).status == :succeeded end)
  end

  test "intent, adapter errors, stored rows, and logs never expose registered secrets or full prompts" do
    plaintext = "effect-secret-#{System.unique_integer([:positive])}"
    prompt = String.duplicate("sensitive prompt ", 1_000)
    {:ok, _reference} = SecretStore.put("effect-test-token", plaintext, actor: "admin-1")
    true = :ets.insert(@adapter_state, {:plaintext, plaintext})
    operation_id = OperationId.generate()

    attrs =
      operation_id
      |> effect_attrs()
      |> put_in([:intent], %{"note" => "Bearer #{plaintext}", "prompt" => prompt})

    log =
      capture_log(fn ->
        assert {:error, :interrupted} = Effects.execute(attrs, SecretCrashingAdapter)
      end)

    record = Effects.get!(operation_id)
    assert record.status == :unknown
    assert record.intent["prompt_truncated"] == true
    refute inspect(record) =~ plaintext
    refute inspect(record) =~ prompt
    refute log =~ plaintext
    refute log =~ prompt

    assert {:ok, %{rows: rows}} =
             SQL.query(
               Repo,
               "select intent, result, error from effect_records where operation_id = ?",
               [operation_id]
             )

    refute inspect(rows) =~ plaintext
    refute inspect(rows) =~ prompt
  end

  test "registered secret plaintext and references are rejected as mutation targets before insert" do
    plaintext = "target-secret-#{System.unique_integer([:positive])}"
    {:ok, reference} = SecretStore.put("effect-target-token", plaintext, actor: "admin-1")

    targets = ["repo/#{plaintext}/head", "secret-reference/#{reference.id}"]

    Enum.each(targets, fn target ->
      operation_id = OperationId.generate()
      attrs = operation_id |> effect_attrs() |> Map.put(:target, target)

      log =
        capture_log(fn ->
          assert {:error, :sensitive_target} = Effects.execute(attrs, PersistedIntentAdapter)
        end)

      error = assert_raise Ecto.NoResultsError, fn -> Effects.get!(operation_id) end
      refute Exception.message(error) =~ plaintext
      refute Exception.message(error) =~ reference.id
      refute log =~ plaintext
      refute log =~ reference.id
    end)

    assert Effects.list(task_id: "task-1") == []
    assert {:ok, %{rows: rows}} = SQL.query(Repo, "select target from effect_records", [])
    refute inspect(rows) =~ plaintext
    refute inspect(rows) =~ reference.id
  end

  test "target validation fails closed when the secret registry is unavailable" do
    operation_id = OperationId.generate()
    assert {:ok, _result} = SQL.query(Repo, "alter table secrets rename to unavailable_secrets", [])

    assert {:error, :sensitive_target} =
             operation_id
             |> effect_attrs()
             |> Map.put(:target, "repo#registry-unavailable")
             |> Effects.execute(PersistedIntentAdapter)

    assert_raise Ecto.NoResultsError, fn -> Effects.get!(operation_id) end
  end

  test "target validation fails closed when registered secret plaintext cannot be resolved" do
    operation_id = OperationId.generate()
    {:ok, reference} = SecretStore.put("effect-corrupt-token", "unreadable-secret", actor: "admin-1")

    assert {:ok, _result} =
             SQL.query(Repo, "update secrets set tag = ? where id = ?", [<<0::128>>, reference.id])

    assert {:error, :sensitive_target} =
             operation_id
             |> effect_attrs()
             |> Map.put(:target, "repo#credential-unavailable")
             |> Effects.execute(PersistedIntentAdapter)

    assert_raise Ecto.NoResultsError, fn -> Effects.get!(operation_id) end
  end

  test "registered secret validation restores an existing process log level" do
    {:ok, _reference} =
      SecretStore.put("effect-log-level-token", "log-level-secret", actor: "admin-1")

    :ok = Logger.put_process_level(self(), :warning)

    assert {:ok, _record} =
             OperationId.generate()
             |> effect_attrs()
             |> Map.put(:target, "repo#safe-log-level")
             |> Effects.execute(PersistedIntentAdapter)

    assert Logger.get_process_level(self()) == :warning
    :ok = Logger.delete_process_level(self())
  end

  test "a definite adapter failure is recorded without an untrusted error payload" do
    operation_id = OperationId.generate()
    attrs = effect_attrs(operation_id)

    assert {:error, :provider_rejected} =
             Effects.execute(attrs, FailingAdapter)

    record = Effects.get!(operation_id)
    assert record.status == :failed
    assert record.error == %{"code" => "provider_rejected"}
    assert {:error, :not_reconcilable} = Effects.reconcile(operation_id, PersistedIntentAdapter)

    assert {:ok, retried} = Effects.execute(attrs, PersistedIntentAdapter)
    assert retried.status == :succeeded
  end

  test "even atom-shaped adapter errors cannot expose a registered secret" do
    {:ok, _reference} =
      SecretStore.put("effect-error-token", "registered_error_secret", actor: "admin-1")

    operation_id = OperationId.generate()

    assert {:error, :adapter_failed} =
             operation_id
             |> effect_attrs()
             |> Effects.execute(SecretAtomErrorAdapter)

    record = Effects.get!(operation_id)
    assert record.error == %{"code" => "adapter_failed"}
    refute inspect(record.error) =~ "registered_error_secret"
  end

  defp effect_attrs(operation_id) do
    %{
      operation_id: operation_id,
      task_id: "task-1",
      plan_revision: 1,
      unit_id: "unit-1",
      action: :create_change_request,
      provider: :simulated,
      target: "repo#head",
      intent: %{"title" => "Draft change request"}
    }
  end

  defp reconciliation_attrs(mode) do
    OperationId.generate()
    |> effect_attrs()
    |> Map.put(:target, "reconcile##{mode}")
    |> put_in([:intent], %{"execute_mode" => "unknown", "reconcile_mode" => mode})
  end

  defp orphan_started(attrs, owner_id) do
    caller =
      spawn(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: owner_id,
          lease_ttl_ms: 60_000
        )
      end)

    assert_receive {:adapter_started, adapter_process}
    adapter_monitor = Process.monitor(adapter_process)
    caller_monitor = Process.monitor(caller)
    :erlang.suspend_process(caller)
    Process.exit(adapter_process, :kill)
    assert_receive {:DOWN, ^adapter_monitor, :process, ^adapter_process, :killed}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

    Effects.Record
    |> Repo.get!(attrs.operation_id)
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    Effects.get!(attrs.operation_id)
  end

  defp eventually(assertion, attempts \\ 50)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end
end
