defmodule SymphonyElixir.OrchestratorApplicationRestartTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.{Coordination, Effects, Repo}
  alias SymphonyElixir.Coordination.{TaskProjection, UnitProjection}
  alias SymphonyElixir.Effects.{OperationId, Record}

  @probe_name SymphonyElixir.TestApplicationRestartEffectProbe

  defmodule BlockingAdapter do
    @moduledoc false

    @spec execute(Record.t()) :: {:ok, map()}
    def execute(_record) do
      send(Process.whereis(SymphonyElixir.TestApplicationRestartEffectProbe), {
        :adapter_started,
        self()
      })

      receive do
        :finish -> {:ok, %{"finished" => true}}
      end
    end

    @spec reconcile(Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  setup do
    lifecycle_enabled =
      Application.get_env(:symphony_elixir, :orchestrator_lifecycle_enabled, false)

    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      restart_application(lifecycle_enabled)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "full application restart rebuilds projections and reconciles an orphan before polling" do
    Process.register(self(), @probe_name)
    operation_id = OperationId.generate()

    {:ok, task} =
      Coordination.start_task(%{
        idempotency_key: "application-restart-#{operation_id}",
        external_id: "RESTART-1",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef",
        actor: %{kind: :service, id: "restart-test"},
        plan_revision: "plan-restart",
        correlation_id: Ecto.UUID.generate()
      })

    orphan =
      orphan_started(%{
        operation_id: operation_id,
        task_id: task.id,
        plan_revision: 1,
        unit_id: "restart-unit",
        action: :create_change_request,
        provider: :simulated,
        target: "repository#application-restart",
        intent: %{"reconcile" => "already_applied"}
      })

    assert orphan.status == :started
    assert {1, nil} = Repo.delete_all(from(projection in TaskProjection, where: projection.task_id == ^task.id))
    assert {:error, :not_found} = Coordination.snapshot(task.id)

    on_exit(fn ->
      restart_application(false)
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(record in Record, where: record.operation_id == ^operation_id))
      Repo.delete_all(from(unit in UnitProjection, where: unit.task_id == ^task.id))
      Repo.delete_all(from(projection in TaskProjection, where: projection.task_id == ^task.id))

      if Process.whereis(@probe_name) == self(), do: Process.unregister(@probe_name)
    end)

    restart_application(true)

    assert is_pid(Process.whereis(SymphonyElixir.OrchestratorLifecycle))
    assert is_pid(Process.whereis(SymphonyElixir.Orchestrator))
    assert {:ok, restored} = Coordination.snapshot(task.id)
    assert restored.id == task.id
    assert restored.version == task.version
    assert Effects.get!(operation_id).status == :succeeded

    first_lifecycle = Process.whereis(SymphonyElixir.OrchestratorLifecycle)
    restart_application(true)
    second_lifecycle = Process.whereis(SymphonyElixir.OrchestratorLifecycle)

    assert is_pid(second_lifecycle)
    refute second_lifecycle == first_lifecycle
    assert {:ok, %{id: restored_task_id}} = Coordination.snapshot(task.id)
    assert restored_task_id == task.id
    assert Effects.get!(operation_id).status == :succeeded
  end

  defp orphan_started(attrs) do
    caller =
      spawn(fn ->
        Effects.execute(attrs, BlockingAdapter,
          owner_id: "orchestrator-before-application-restart",
          lease_ttl_ms: 60_000
        )
      end)

    assert_receive {:adapter_started, adapter_process}, 1_000
    adapter_monitor = Process.monitor(adapter_process)
    caller_monitor = Process.monitor(caller)
    :erlang.suspend_process(caller)
    Process.exit(adapter_process, :kill)
    assert_receive {:DOWN, ^adapter_monitor, :process, ^adapter_process, :killed}, 1_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    Effects.get!(attrs.operation_id)
  end

  defp restart_application(lifecycle_enabled) do
    case Application.stop(:symphony_elixir) do
      :ok -> :ok
      {:error, {:not_started, :symphony_elixir}} -> :ok
    end

    Application.put_env(
      :symphony_elixir,
      :orchestrator_lifecycle_enabled,
      lifecycle_enabled
    )

    assert {:ok, _started} = Application.ensure_all_started(:symphony_elixir)
    Sandbox.mode(Repo, :auto)
    :ok
  end
end
