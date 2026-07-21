defmodule SymphonyElixir.Coordination.RebuildTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.{Coordination, Repo}
  alias SymphonyElixir.Coordination.Event

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

  test "rebuild fails closed on unsupported event versions" do
    task_id = Ecto.UUID.generate()
    insert_task_started!(task_id, stream_version: 1, event_version: 2)

    assert {:error, :unsupported_event_version} = Coordination.rebuild_projection(task_id)
    assert {:error, :not_found} = Coordination.snapshot(task_id)
  end

  test "rebuild fails closed on non-contiguous stream versions" do
    task_id = Ecto.UUID.generate()
    insert_task_started!(task_id, stream_version: 1)
    insert_event!(task_id, stream_version: 3, event_type: "planning_started")

    assert {:error, {:non_contiguous_stream_version, 2, 3}} =
             Coordination.rebuild_projection(task_id)
  end

  defp insert_task_started!(task_id, opts) do
    data = %{
      "idempotency_key" => "rebuild-corrupt:#{task_id}",
      "idempotency_hash" => Ecto.UUID.generate(),
      "external_id" => "TASK-corrupt",
      "baseline" => "0123456789abcdef",
      "attributes" => %{}
    }

    insert_event!(
      task_id,
      Keyword.merge([stream_version: 1, event_type: "task_started", data: data], opts)
    )
  end

  defp insert_event!(task_id, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      opts
      |> Keyword.put_new(:event_version, 1)
      |> Keyword.put_new(:data, %{})

    %Event{}
    |> Event.changeset(%{
      task_id: task_id,
      stream_version: Keyword.fetch!(attrs, :stream_version),
      event_type: Keyword.fetch!(attrs, :event_type),
      event_version: Keyword.fetch!(attrs, :event_version),
      actor_kind: "system",
      actor_id: "fault-injection",
      correlation_id: Ecto.UUID.generate(),
      data: Keyword.fetch!(attrs, :data),
      occurred_at: now
    })
    |> Repo.insert!()
  end
end
