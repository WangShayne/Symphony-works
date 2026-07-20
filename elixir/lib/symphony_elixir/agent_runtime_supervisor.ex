defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    lifecycle_enabled =
      Keyword.get_lazy(opts, :lifecycle_enabled, fn ->
        SymphonyElixir.Config.orchestrator_lifecycle_enabled?()
      end)

    lifecycle_name =
      Keyword.get(opts, :lifecycle_name, SymphonyElixir.OrchestratorLifecycle)

    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    lifecycle_opts =
      opts
      |> Keyword.take([
        :owner_id,
        :lease_ttl_ms,
        :heartbeat_interval_ms,
        :recovery_batch_size,
        :recovery_now,
        :effect_adapter_resolver,
        :projection_rebuilder,
        :startup_heartbeat_stop_timeout_ms
      ])
      |> Keyword.put(:name, lifecycle_name)

    lifecycle_children =
      if lifecycle_enabled do
        [
          Supervisor.child_spec(
            {SymphonyElixir.OrchestratorLifecycle, lifecycle_opts},
            id: lifecycle_name
          )
        ]
      else
        []
      end

    children =
      lifecycle_children ++
        [
          Supervisor.child_spec(
            {Task.Supervisor, name: task_supervisor_name},
            id: task_supervisor_name
          ),
          Supervisor.child_spec(
            {SymphonyElixir.Orchestrator, name: orchestrator_name, task_supervisor: task_supervisor_name},
            id: orchestrator_name
          )
        ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
