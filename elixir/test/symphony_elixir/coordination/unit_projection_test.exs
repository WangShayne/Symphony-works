defmodule SymphonyElixir.Coordination.UnitProjectionTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Coordination

  test "projects execution units from task stream events" do
    {:ok, task} =
      Coordination.start_task(%{
        idempotency_key: "unit-projection:task-1",
        external_id: "TASK-1",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef"
      })

    assert {:ok, 4} =
             Coordination.append(task.id, 1, [
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "backend-1",
                   task_type: "backend",
                   execution_profile: "backend-default",
                   dependencies: ["schema-1"]
                 }
               },
               %{type: :unit_runnable, data: %{unit_id: "backend-1"}},
               %{type: :unit_started, data: %{unit_id: "backend-1", worker_id: "worker-7"}}
             ])

    assert {:ok, 5} =
             Coordination.append(task.id, 4, [
               %{type: :unit_progress, data: %{unit_id: "backend-1", percent: 25}}
             ])

    assert {:ok, snapshot} = Coordination.snapshot(task.id)

    assert [unit] = snapshot.units
    assert unit.id == "backend-1"
    assert unit.task_id == task.id
    assert unit.version == 5
    assert unit.status == :running
    assert unit.task_type == "backend"
    assert unit.execution_profile == "backend-default"
    assert unit.dependencies == ["schema-1"]
    assert unit.data["worker_id"] == "worker-7"
    assert unit.data["percent"] == 25
  end

  test "keeps default unit dependencies when planning event omits them" do
    {:ok, task} =
      Coordination.start_task(%{
        idempotency_key: "unit-projection:missing-dependencies",
        external_id: "TASK-MISSING-DEPS",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef"
      })

    assert {:ok, 2} =
             Coordination.append(task.id, 1, [
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "docs-1",
                   task_type: "documentation",
                   execution_profile: "docs-default"
                 }
               }
             ])

    assert {:ok, snapshot} = Coordination.snapshot(task.id)

    assert [
             %{
               id: "docs-1",
               task_type: "documentation",
               execution_profile: "docs-default",
               dependencies: [],
               data: %{}
             }
           ] = snapshot.units
  end
end
