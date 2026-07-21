defmodule SymphonyElixir.OrchestratorLifecycleTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.{AgentRuntimeSupervisor, Configuration, Coordination, Effects, OrchestratorLifecycle, Repo}
  alias SymphonyElixir.Configuration.{Document, Revision}
  alias SymphonyElixir.Coordination.Lease
  alias SymphonyElixir.Effects.OperationId

  @active_name SymphonyElixir.TestActiveOrchestratorLifecycle
  @competing_name SymphonyElixir.TestCompetingOrchestratorLifecycle
  @runtime_name SymphonyElixir.TestLeaseLossRuntimeSupervisor
  @task_supervisor_name SymphonyElixir.TestLeaseLossTaskSupervisor
  @orchestrator_name SymphonyElixir.TestLeaseLossOrchestrator
  @probe_name SymphonyElixir.TestOrchestratorLifecycleProbe

  defmodule BlockingAdapter do
    @moduledoc false

    @spec execute(Effects.Record.t()) :: {:ok, map()}
    def execute(_record) do
      send(Process.whereis(SymphonyElixir.TestOrchestratorLifecycleProbe), {
        :adapter_started,
        self()
      })

      receive do
        :finish -> {:ok, %{"finished" => true}}
      end
    end

    @spec reconcile(Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule BlockingResolver do
    @moduledoc false

    @spec resolve(Effects.Record.t()) :: {:ok, module()}
    def resolve(_record) do
      send(Process.whereis(SymphonyElixir.TestOrchestratorLifecycleProbe), {
        :resolver_started,
        self()
      })

      receive do
        :continue -> {:ok, SymphonyElixir.Effects.SimulatedAdapter}
      end
    end
  end

  defmodule MissingAdapterResolver do
    @moduledoc false

    @spec resolve(Effects.Record.t()) :: {:ok, module()}
    def resolve(_record), do: {:ok, SymphonyElixir.MissingEffectAdapter}
  end

  defmodule InvalidResolver do
    @moduledoc false

    @spec resolve(Effects.Record.t()) :: :invalid_resolver_result
    def resolve(_record), do: :invalid_resolver_result
  end

  test "a competing orchestrator owner cannot acquire the active runtime lease" do
    on_exit(fn ->
      stop_named_process(@competing_name)
      stop_named_process(@active_name)
    end)

    assert {:ok, _active_pid} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "active-orchestrator",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000
             )

    assert {:error, {:orchestrator_startup_failed, :acquire_lease, {:owned_by, active_owner}}} =
             OrchestratorLifecycle.start_link(
               name: @competing_name,
               owner_id: "competing-orchestrator",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000
             )

    assert active_owner == "active-orchestrator"
    refute active_owner == "competing-orchestrator"
    refute Process.whereis(@competing_name)
  end

  test "default startup options acquire and release lifecycle authority" do
    on_exit(fn -> stop_named_process(OrchestratorLifecycle) end)

    assert {:ok, lifecycle} = OrchestratorLifecycle.start_link()
    assert Process.whereis(OrchestratorLifecycle) == lifecycle
    assert :ok = GenServer.stop(lifecycle)
  end

  test "invalid lifecycle options fail before acquiring authority" do
    assert {:error, {:orchestrator_startup_failed, :configuration, :invalid_lease_options}} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000
             )

    assert {:ok, replacement} =
             Coordination.acquire_lease("valid-after-invalid-options", ttl_ms: 30_000)

    assert :ok = Coordination.release_lease(replacement)
  end

  test "invalid recovery time fails closed and releases startup authority" do
    assert {:error, {:orchestrator_startup_failed, :recover_effects, :invalid_now}} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "invalid-recovery-time",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000,
               recovery_now: :not_a_datetime
             )

    assert {:ok, replacement} =
             Coordination.acquire_lease("valid-after-invalid-recovery-time",
               ttl_ms: 30_000
             )

    assert :ok = Coordination.release_lease(replacement)
  end

  test "projection rebuild errors are sanitized and release startup authority" do
    for projection_rebuilder <- [
          fn -> {:error, {:storage_failed, "must-not-leak"}} end,
          fn -> raise "must-not-leak" end,
          fn -> throw("must-not-leak") end,
          fn -> :invalid_rebuild_result end
        ] do
      owner_id = "failing-rebuilder-#{System.unique_integer([:positive])}"

      assert {:error, {:orchestrator_startup_failed, :rebuild_projections, :projection_rebuild_failed}} =
               OrchestratorLifecycle.start_link(
                 name: @active_name,
                 owner_id: owner_id,
                 lease_ttl_ms: 30_000,
                 heartbeat_interval_ms: 10_000,
                 projection_rebuilder: projection_rebuilder
               )

      assert {:ok, replacement} =
               Coordination.acquire_lease("replacement-#{owner_id}", ttl_ms: 30_000)

      assert :ok = Coordination.release_lease(replacement)
    end
  end

  test "bounded startup heartbeat handoff fails closed when no grace is allowed" do
    assert {:error, {:orchestrator_startup_failed, :heartbeat, :startup_heartbeat_stop_timeout}} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "zero-grace-startup",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000,
               startup_heartbeat_stop_timeout_ms: 0
             )

    assert {:ok, replacement} =
             Coordination.acquire_lease("after-zero-grace-startup", ttl_ms: 30_000)

    assert :ok = Coordination.release_lease(replacement)
  end

  test "orderly lifecycle termination releases the durable lease" do
    assert {:ok, lifecycle} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "stopping-orchestrator",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000
             )

    assert :ok = GenServer.stop(lifecycle)

    assert {:ok, replacement} =
             Coordination.acquire_lease("replacement-orchestrator", ttl_ms: 30_000)

    assert :ok = Coordination.release_lease(replacement)
  end

  test "heartbeat keeps the active lease beyond its original expiry" do
    on_exit(fn ->
      stop_named_process(@competing_name)
      stop_named_process(@active_name)
    end)

    assert {:ok, _lifecycle} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "heartbeating-orchestrator",
               lease_ttl_ms: 300,
               heartbeat_interval_ms: 50
             )

    Process.sleep(450)

    assert {:error, {:orchestrator_startup_failed, :acquire_lease, {:owned_by, "heartbeating-orchestrator"}}} =
             OrchestratorLifecycle.start_link(
               name: @competing_name,
               owner_id: "late-competitor",
               lease_ttl_ms: 300,
               heartbeat_interval_ms: 50
             )
  end

  test "startup reconciles a foreign started effect before becoming ready" do
    Process.register(self(), @probe_name)

    on_exit(fn ->
      if Process.whereis(@probe_name) == self(), do: Process.unregister(@probe_name)
      stop_named_process(@active_name)
    end)

    operation_id = OperationId.generate()

    orphan =
      orphan_started(%{
        operation_id: operation_id,
        task_id: "startup-recovery-task",
        plan_revision: 1,
        unit_id: "startup-recovery-unit",
        action: :create_change_request,
        provider: :simulated,
        target: "repository#startup-recovery",
        intent: %{"reconcile" => "already_applied"}
      })

    assert orphan.status == :started

    source_control_operation_id = OperationId.generate()
    source_control_task_id = "startup-source-control-recovery-task"

    source_control_integration = %{
      "id" => "startup-source-control",
      "kind" => "source_control",
      "provider" => "fixture",
      "settings" => %{
        "repository" => "acme/startup-recovery",
        "base_branch" => "main"
      }
    }

    pin_integrations(source_control_task_id, [source_control_integration])

    source_control_orphan =
      orphan_started(%{
        operation_id: source_control_operation_id,
        task_id: source_control_task_id,
        plan_revision: 1,
        unit_id: "startup-source-control-recovery-unit",
        action: :ensure_change_request,
        provider: :fixture,
        target: "acme/startup-recovery",
        intent: %{
          "attrs" => %{
            "repo" => source_control_integration,
            "head" => "task/startup-recovery",
            "base" => "main",
            "title" => "Recover source-control effect",
            "body" => "Reconcile before retry",
            "draft" => true
          }
        }
      })

    assert source_control_orphan.status == :started

    assert {:ok, _lifecycle} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "orchestrator-after-restart",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000
             )

    recovered = Effects.get!(operation_id)
    assert recovered.status == :succeeded
    assert recovered.error == nil

    source_control_recovered = Effects.get!(source_control_operation_id)
    assert source_control_recovered.status == :succeeded
    assert source_control_recovered.result["repository"] == "acme/startup-recovery"
  end

  test "startup waits for an unexpired crashed effect lease before recovery" do
    register_probe!()
    operation_id = OperationId.generate()

    orphan =
      orphan_started(
        %{
          operation_id: operation_id,
          task_id: "unexpired-startup-recovery-task",
          plan_revision: 1,
          unit_id: "unexpired-startup-recovery-unit",
          action: :create_change_request,
          provider: :simulated,
          target: "repository#unexpired-startup-recovery",
          intent: %{"reconcile" => "already_applied"}
        },
        lease_ttl_ms: 250,
        expire?: false
      )

    assert orphan.status == :started
    assert DateTime.compare(orphan.lease_expires_at, DateTime.utc_now()) == :gt

    starter =
      Task.async(fn ->
        OrchestratorLifecycle.start_link(
          name: @active_name,
          owner_id: "orchestrator-after-unexpired-crash",
          lease_ttl_ms: 1_000,
          heartbeat_interval_ms: 100
        )
      end)

    assert nil == Task.yield(starter, 30)
    assert {:ok, _lifecycle} = Task.await(starter, 2_000)
    assert Effects.get!(operation_id).status == :succeeded
  end

  test "startup does not take over a live foreign effect that keeps heartbeating" do
    register_probe!()
    operation_id = OperationId.generate()

    effect_caller =
      Task.async(fn ->
        Effects.execute(
          %{
            operation_id: operation_id,
            task_id: "live-foreign-effect-task",
            plan_revision: 1,
            unit_id: "live-foreign-effect-unit",
            action: :create_change_request,
            provider: :simulated,
            target: "repository#live-foreign-effect",
            intent: %{"reconcile" => "already_applied"}
          },
          BlockingAdapter,
          owner_id: "live-foreign-effect-owner",
          lease_ttl_ms: 120
        )
      end)

    assert_receive {:adapter_started, adapter_process}, 1_000
    original = Repo.get!(Effects.Record, operation_id)

    starter =
      Task.async(fn ->
        OrchestratorLifecycle.start_link(
          name: @active_name,
          owner_id: "waiting-orchestrator",
          lease_ttl_ms: 1_000,
          heartbeat_interval_ms: 100
        )
      end)

    assert nil == Task.yield(starter, 30)
    Process.sleep(300)
    assert nil == Task.yield(starter, 0)

    current = Repo.get!(Effects.Record, operation_id)
    assert current.status == :started
    assert current.lease_owner == "live-foreign-effect-owner"
    assert current.fencing_token == original.fencing_token
    assert DateTime.compare(current.lease_expires_at, original.lease_expires_at) == :gt

    send(adapter_process, :finish)
    assert {:ok, completed} = Task.await(effect_caller, 1_000)
    assert completed.status == :succeeded
    assert {:ok, _lifecycle} = Task.await(starter, 2_000)
  end

  test "lease loss stops the supervised orchestrator and prevents work from restarting" do
    on_exit(fn ->
      stop_named_process(@runtime_name)

      case Coordination.acquire_lease("lease-loss-cleanup", ttl_ms: 30_000) do
        {:ok, lease} -> release_lease_with_retry(lease)
        {:error, _reason} -> :ok
      end
    end)

    assert {:ok, runtime} =
             AgentRuntimeSupervisor.start_link(
               name: @runtime_name,
               lifecycle_enabled: true,
               lifecycle_name: @active_name,
               task_supervisor_name: @task_supervisor_name,
               orchestrator_name: @orchestrator_name,
               owner_id: "lease-losing-orchestrator",
               lease_ttl_ms: 1_000,
               heartbeat_interval_ms: 50
             )

    Process.unlink(runtime)
    orchestrator = Process.whereis(@orchestrator_name)
    assert is_pid(orchestrator)
    orchestrator_monitor = Process.monitor(orchestrator)

    assert :ok = Coordination.release_lease(active_lease!())

    assert {:ok, takeover_lease} =
             Coordination.acquire_lease("takeover-orchestrator", ttl_ms: 30_000)

    assert_receive {:DOWN, ^orchestrator_monitor, :process, ^orchestrator, _reason}, 1_000
    refute Process.whereis(@orchestrator_name)
    assert :ok = release_lease_with_retry(takeover_lease)
  end

  test "unresolved startup recovery prevents the orchestrator sibling from starting" do
    Process.register(self(), @probe_name)

    on_exit(fn ->
      if Process.whereis(@probe_name) == self(), do: Process.unregister(@probe_name)
    end)

    orphan =
      orphan_started(%{
        operation_id: OperationId.generate(),
        task_id: "unsupported-provider-task",
        plan_revision: 1,
        unit_id: "unsupported-provider-unit",
        action: :create_change_request,
        provider: :unsupported_provider,
        target: "repository#unsupported-provider",
        intent: %{"reconcile" => "already_applied"}
      })

    assert orphan.status == :started

    start_result =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        AgentRuntimeSupervisor.start_link(
          name: @runtime_name,
          lifecycle_enabled: true,
          lifecycle_name: @active_name,
          task_supervisor_name: @task_supervisor_name,
          orchestrator_name: @orchestrator_name,
          owner_id: "unsupported-provider-orchestrator",
          lease_ttl_ms: 30_000,
          heartbeat_interval_ms: 10_000
        )
      end)
      |> Task.await()

    startup_failure =
      {:orchestrator_startup_failed, :resolve_effect_adapter, :unsupported_provider}

    expected_error = {:error, {:shutdown, {:failed_to_start_child, @active_name, startup_failure}}}

    assert expected_error == start_result

    refute Process.whereis(@orchestrator_name)
    refute Process.whereis(@task_supervisor_name)

    assert {:ok, replacement} =
             Coordination.acquire_lease("post-failure-orchestrator", ttl_ms: 30_000)

    assert :ok = Coordination.release_lease(replacement)
  end

  test "heartbeat protects the lease throughout bounded startup recovery" do
    Process.register(self(), @probe_name)

    on_exit(fn ->
      if Process.whereis(@probe_name) == self(), do: Process.unregister(@probe_name)
      stop_named_process(@competing_name)
      stop_named_process(@active_name)
    end)

    for index <- 1..75 do
      operation_id = OperationId.generate()

      assert %{status: :started} =
               orphan_started(%{
                 operation_id: operation_id,
                 task_id: "long-startup-task-#{index}",
                 plan_revision: 1,
                 unit_id: "long-startup-unit-#{index}",
                 action: :create_change_request,
                 provider: :simulated,
                 target: "repository#long-startup-#{index}",
                 intent: %{"reconcile" => "already_applied"}
               })
    end

    assert {:ok, _lifecycle} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "long-startup-orchestrator",
               lease_ttl_ms: 100,
               heartbeat_interval_ms: 20,
               recovery_batch_size: 1
             )

    Process.sleep(2)

    assert {:error, {:orchestrator_startup_failed, :acquire_lease, {:owned_by, "long-startup-orchestrator"}}} =
             OrchestratorLifecycle.start_link(
               name: @competing_name,
               owner_id: "long-startup-competitor",
               lease_ttl_ms: 100,
               heartbeat_interval_ms: 20
             )
  end

  test "startup heartbeat loss aborts blocked recovery before lifecycle readiness" do
    Process.register(self(), @probe_name)

    on_exit(fn ->
      if Process.whereis(@probe_name) == self(), do: Process.unregister(@probe_name)
      stop_named_process(@active_name)

      case Coordination.acquire_lease("blocked-recovery-cleanup", ttl_ms: 30_000) do
        {:ok, lease} -> Coordination.release_lease(lease)
        {:error, _reason} -> :ok
      end
    end)

    operation_id = OperationId.generate()

    assert %{status: :started} =
             orphan_started(%{
               operation_id: operation_id,
               task_id: "blocked-recovery-task",
               plan_revision: 1,
               unit_id: "blocked-recovery-unit",
               action: :create_change_request,
               provider: :simulated,
               target: "repository#blocked-recovery",
               intent: %{"reconcile" => "already_applied"}
             })

    starter =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        OrchestratorLifecycle.start_link(
          name: @active_name,
          owner_id: "blocked-recovery-orchestrator",
          lease_ttl_ms: 200,
          heartbeat_interval_ms: 20,
          recovery_batch_size: 1,
          effect_adapter_resolver: &BlockingResolver.resolve/1
        )
      end)

    assert_receive {:resolver_started, lifecycle}, 1_000
    assert lifecycle == Process.whereis(@active_name)

    assert :ok = Coordination.release_lease(active_lease!())

    assert {:ok, takeover_lease} =
             Coordination.acquire_lease("blocked-recovery-takeover", ttl_ms: 30_000)

    assert {:error, {:orchestrator_startup_failed, :heartbeat, :lease_lost}} =
             Task.await(starter)

    refute Process.whereis(@active_name)
    assert :ok = Coordination.release_lease(takeover_lease)
  end

  test "unresolved reconciliation fails startup and releases authority" do
    register_probe!()
    operation_id = OperationId.generate()

    assert %{status: :started} =
             orphan_started(%{
               operation_id: operation_id,
               task_id: "unresolved-reconciliation-task",
               plan_revision: 1,
               unit_id: "unresolved-reconciliation-unit",
               action: :create_change_request,
               provider: :simulated,
               target: "repository#unresolved-reconciliation",
               intent: %{}
             })

    assert {:error, {:orchestrator_startup_failed, :reconcile_effects, {^operation_id, :not_observed}}} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "unresolved-reconciliation-owner",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000
             )

    assert {:ok, replacement} =
             Coordination.acquire_lease("after-unresolved-reconciliation",
               ttl_ms: 30_000
             )

    assert :ok = Coordination.release_lease(replacement)
  end

  test "resolver rejects a missing adapter before lifecycle readiness" do
    register_probe!()
    orphan = resolvable_orphan("missing-adapter")

    assert {:error, {:orchestrator_startup_failed, :resolve_effect_adapter, :adapter_unavailable}} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "missing-adapter-owner",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000,
               effect_adapter_resolver: &MissingAdapterResolver.resolve/1
             )

    assert Effects.get!(orphan.operation_id).status == :unknown
  end

  test "resolver rejects malformed results before lifecycle readiness" do
    register_probe!()
    orphan = resolvable_orphan("invalid-resolver-result")

    assert {:error, {:orchestrator_startup_failed, :resolve_effect_adapter, :invalid_resolver_result}} =
             OrchestratorLifecycle.start_link(
               name: @active_name,
               owner_id: "invalid-resolver-result-owner",
               lease_ttl_ms: 30_000,
               heartbeat_interval_ms: 10_000,
               effect_adapter_resolver: &InvalidResolver.resolve/1
             )

    assert Effects.get!(orphan.operation_id).status == :unknown
  end

  defp orphan_started(attrs, opts \\ []) do
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, 60_000)
    expire? = Keyword.get(opts, :expire?, true)

    caller =
      spawn(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: "orchestrator-before-restart",
          lease_ttl_ms: lease_ttl_ms
        )
      end)

    caller_monitor = Process.monitor(caller)

    adapter_process =
      receive do
        {:adapter_started, adapter_process} ->
          adapter_process

        {:DOWN, ^caller_monitor, :process, ^caller, reason} ->
          flunk("effect caller exited before adapter start: #{inspect(reason)}")
      after
        1_000 ->
          flunk("effect adapter did not start")
      end

    adapter_monitor = Process.monitor(adapter_process)
    :erlang.suspend_process(caller)
    Process.exit(adapter_process, :kill)
    assert_receive {:DOWN, ^adapter_monitor, :process, ^adapter_process, :killed}, 1_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000

    if expire? do
      Effects.Record
      |> Repo.get!(attrs.operation_id)
      |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()
    end

    Effects.get!(attrs.operation_id)
  end

  defp resolvable_orphan(label) do
    operation_id = OperationId.generate()

    orphan_started(%{
      operation_id: operation_id,
      task_id: "#{label}-task",
      plan_revision: 1,
      unit_id: "#{label}-unit",
      action: :create_change_request,
      provider: :simulated,
      target: "repository##{label}",
      intent: %{"reconcile" => "already_applied"}
    })
  end

  defp register_probe! do
    Process.register(self(), @probe_name)

    on_exit(fn ->
      if Process.whereis(@probe_name) == self(), do: Process.unregister(@probe_name)
      stop_named_process(@active_name)
    end)
  end

  defp pin_integrations(task_id, integrations) do
    document = %{"integrations" => integrations}
    content_hash = Document.content_hash(document)
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, revision} =
             %Revision{}
             |> Revision.draft_changeset(%{
               document: document,
               schema_version: 1,
               content_hash: content_hash,
               created_by: "test"
             })
             |> Repo.insert()

    assert {:ok, revision} =
             revision
             |> Revision.activation_changeset(%{
               validated_by: "test",
               validation_evidence: %{"source" => "test"},
               validated_at: timestamp,
               activated_by: "test",
               activated_at: timestamp
             })
             |> Ecto.Changeset.put_change(:status, :superseded)
             |> Repo.update()

    assert {:ok, _pin} =
             Configuration.pin_for_task(task_id, revision_id: revision.id, actor: "test")
  end

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  defp release_lease_with_retry(lease, attempts \\ 5)

  defp release_lease_with_retry(lease, attempts) when attempts > 1 do
    Coordination.release_lease(lease)
  catch
    :exit, _reason ->
      Process.sleep(20)
      release_lease_with_retry(lease, attempts - 1)
  end

  defp release_lease_with_retry(lease, _attempts), do: Coordination.release_lease(lease)

  defp active_lease!, do: Repo.get!(Lease, "orchestrator")
end
