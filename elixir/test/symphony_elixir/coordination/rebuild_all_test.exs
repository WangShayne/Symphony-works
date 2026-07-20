defmodule SymphonyElixir.Coordination.RebuildAllTest do
  use SymphonyElixir.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.{Coordination, Repo}
  alias SymphonyElixir.Coordination.Event

  test "rebuilds every durable stream without consulting projections" do
    {:ok, first} = start_task("first")
    {:ok, second} = start_task("second")

    assert {:ok, 2} =
             Coordination.append(first.id, 1, [
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "unit-1",
                   task_type: "backend",
                   execution_profile: "backend-default",
                   dependencies: []
                 }
               }
             ])

    assert {:ok, before_first} = Coordination.snapshot(first.id)
    assert {:ok, before_second} = Coordination.snapshot(second.id)

    task_ids = [first.id, second.id]
    placeholders = Enum.map_join(task_ids, ",", fn _id -> "?" end)

    assert {:ok, _result} =
             SQL.query(
               Repo,
               "DELETE FROM coordination_unit_projections WHERE task_id IN (#{placeholders})",
               task_ids
             )

    assert {:ok, _result} =
             SQL.query(
               Repo,
               "DELETE FROM coordination_task_projections WHERE task_id IN (#{placeholders})",
               task_ids
             )

    assert {:error, :not_found} = Coordination.snapshot(first.id)
    assert {:error, :not_found} = Coordination.snapshot(second.id)

    assert :ok = Coordination.rebuild_all_projections()
    assert {:ok, ^before_first} = Coordination.snapshot(first.id)
    assert {:ok, ^before_second} = Coordination.snapshot(second.id)
    assert :ok = Coordination.rebuild_all_projections()
  end

  test "rejects an invalid event discovered during replay without replacing projections" do
    {:ok, task} = start_task("invalid-replay")
    event_type = "invalid-replay-#{System.unique_integer([:positive])}"

    insert_event!(task.id, 2, event_type)

    assert {:error, {:unknown_event_type, ^event_type}} =
             Coordination.rebuild_projection(task.id)

    assert {:ok, ^task} = Coordination.snapshot(task.id)
  end

  test "reports a malformed durable stream while rebuilding all projections" do
    task_id = Ecto.UUID.generate()
    event_type = "orphan-event-#{System.unique_integer([:positive])}"

    insert_event!(task_id, 1, event_type)

    assert {:error, {:invalid_task_transition, :missing, ^event_type}} =
             Coordination.rebuild_all_projections()

    assert {:error, :not_found} = Coordination.snapshot(task_id)
  end

  defp start_task(suffix) do
    Coordination.start_task(%{
      idempotency_key: "rebuild-all:#{suffix}",
      external_id: "TASK-#{suffix}",
      config_revision_id: Ecto.UUID.generate(),
      baseline: "0123456789abcdef"
    })
  end

  defp insert_event!(task_id, stream_version, event_type) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Event{}
    |> Event.changeset(%{
      task_id: task_id,
      stream_version: stream_version,
      event_type: event_type,
      event_version: 1,
      actor_kind: "system",
      actor_id: "fault-injection",
      correlation_id: Ecto.UUID.generate(),
      data: %{},
      occurred_at: now
    })
    |> Repo.insert!()
  end
end
