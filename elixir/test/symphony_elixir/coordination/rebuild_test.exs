defmodule SymphonyElixir.Coordination.RebuildTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Coordination

  test "rebuilds the same task and unit snapshot from immutable events" do
    {:ok, task} =
      Coordination.start_task(%{
        idempotency_key: "rebuild:task-1",
        external_id: "TASK-1",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef",
        plan_revision: "plan-1"
      })

    assert {:ok, 5} =
             Coordination.append(task.id, 1, [
               %{type: :planning_started, plan_revision: "plan-2", data: %{phase: "routing"}},
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "frontend-1",
                   task_type: "frontend",
                   execution_profile: "frontend-default",
                   dependencies: []
                 }
               },
               %{type: :unit_runnable, data: %{unit_id: "frontend-1"}},
               %{type: :unit_started, data: %{unit_id: "frontend-1", worker_id: "worker-1"}}
             ])

    assert {:ok, before} = Coordination.snapshot(task.id)
    assert :ok = Coordination.rebuild_projection(task.id)
    assert {:ok, ^before} = Coordination.snapshot(task.id)
  end

  test "does not invent a projection for an unknown task" do
    assert {:error, :not_found} = Coordination.rebuild_projection(Ecto.UUID.generate())
  end
end
