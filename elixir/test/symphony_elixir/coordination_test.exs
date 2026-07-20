defmodule SymphonyElixir.CoordinationTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Coordination

  test "starts a task with a durable public snapshot" do
    configuration_revision = Ecto.UUID.generate()
    correlation_id = Ecto.UUID.generate()

    attrs = %{
      idempotency_key: "github:WangShayne/Symphony-works:ABC-1",
      external_id: "ABC-1",
      config_revision_id: configuration_revision,
      baseline: "0123456789abcdef",
      actor: %{kind: :service, id: "scheduler"},
      plan_revision: "plan-1",
      correlation_id: correlation_id
    }

    assert {:ok, task} = Coordination.start_task(attrs)

    assert %{
             id: task_id,
             idempotency_key: "github:WangShayne/Symphony-works:ABC-1",
             external_id: "ABC-1",
             version: 1,
             status: :queued,
             configuration_revision: ^configuration_revision,
             plan_revision: "plan-1",
             correlation_id: ^correlation_id,
             units: []
           } = task

    assert {:ok, ^task} = Coordination.snapshot(task_id)

    assert [summary] = Coordination.list(idempotency_key: attrs.idempotency_key)
    assert summary == task |> Map.delete(:units) |> Map.put(:unit_count, 0)
  end

  test "appends events optimistically and projects task progress atomically" do
    {:ok, task} = Coordination.start_task(task_attrs("optimistic"))

    event = %{
      type: :planning_started,
      version: 1,
      actor: %{kind: :model, id: "routing-model"},
      plan_revision: "plan-2",
      configuration_revision: task.configuration_revision,
      correlation_id: Ecto.UUID.generate(),
      data: %{phase: "routing"}
    }

    assert {:ok, 2} = Coordination.append(task.id, 1, [event])

    assert {:ok, projected} = Coordination.snapshot(task.id)
    assert projected.version == 2
    assert projected.status == :planning
    assert projected.plan_revision == "plan-2"
    assert projected.data["phase"] == "routing"

    assert {:error, :stale_stream} =
             Coordination.append(task.id, 1, [%{type: :task_cancelled, data: %{}}])

    assert {:ok, ^projected} = Coordination.snapshot(task.id)
  end

  test "projects explicit effect outcomes and recovery-needed state" do
    {:ok, task} = Coordination.start_task(task_attrs("effect-outcome"))

    assert {:ok, 2} =
             Coordination.append(task.id, 1, [
               %{type: :effect_succeeded, data: %{operation_id: "op-1"}}
             ])

    assert {:ok, succeeded} = Coordination.snapshot(task.id)
    assert succeeded.effect == %{operation_id: "op-1", status: :succeeded}
    assert succeeded.effect_status == :succeeded

    assert {:ok, 3} =
             Coordination.append(task.id, 2, [
               %{type: :effect_unknown, data: %{operation_id: "op-2"}}
             ])

    assert {:ok, unknown} = Coordination.snapshot(task.id)
    assert unknown.effect == %{operation_id: "op-2", status: :unknown}
    assert unknown.effect_status == :unknown

    assert {:ok, 4} =
             Coordination.append(task.id, 3, [
               %{type: :task_recovery_needed, data: %{operation_id: "op-2"}}
             ])

    assert {:ok, recovery} = Coordination.snapshot(task.id)
    assert recovery.status == :awaiting_intervention
    assert recovery.effect == %{operation_id: "op-2", status: :recovery_needed}
    assert recovery.effect_status == :recovery_needed
  end

  test "replays equivalent task creation and rejects conflicting idempotency reuse" do
    attrs = task_attrs("idempotent")

    assert {:ok, first} = Coordination.start_task(attrs)
    assert {:ok, _other} = Coordination.start_task(task_attrs("idempotent-other"))

    replay_attrs = Map.put(attrs, :correlation_id, Ecto.UUID.generate())
    assert {:ok, ^first} = Coordination.start_task(replay_attrs)

    assert [summary] = Coordination.list(%{"idempotency_key" => attrs.idempotency_key})
    assert summary == first |> Map.delete(:units) |> Map.put(:unit_count, 0)

    conflicting_attrs = Map.put(attrs, :baseline, "different-baseline")

    assert {:error, {:idempotency_conflict, first.id}} ==
             Coordination.start_task(conflicting_attrs)
  end

  test "rejects secret-like task and event data before persistence" do
    unsafe_attrs = Map.put(task_attrs("unsafe-start"), :prompt, "complete private prompt")

    assert {:error, {:sensitive_data, ["prompt"]}} = Coordination.start_task(unsafe_attrs)
    assert [] = Coordination.list(idempotency_key: unsafe_attrs.idempotency_key)

    {:ok, task} = Coordination.start_task(task_attrs("unsafe-event"))

    assert {:error, {:sensitive_data, ["metadata", "api_key"]}} =
             Coordination.append(task.id, 1, [
               %{type: :planning_started, data: %{metadata: %{api_key: "must-not-persist"}}}
             ])

    assert {:ok, unchanged} = Coordination.snapshot(task.id)
    assert unchanged.version == 1
    refute inspect(unchanged) =~ "must-not-persist"
  end

  test "publishes committed task snapshots to subscribers" do
    task_id = Ecto.UUID.generate()
    assert :ok = Coordination.subscribe(task_id)

    assert {:ok, started} =
             "pubsub"
             |> task_attrs()
             |> Map.put(:id, task_id)
             |> Coordination.start_task()

    assert_receive {:coordination_updated, ^started}
    assert {:ok, ^started} = Coordination.snapshot(task_id)

    assert {:ok, 2} =
             Coordination.append(task_id, 1, [%{type: :planning_started, data: %{}}])

    assert_receive {:coordination_updated, updated}
    assert updated.id == task_id
    assert updated.version == 2
    assert updated.status == :planning

    assert {:error, :stale_stream} =
             Coordination.append(task_id, 1, [%{type: :task_cancelled, data: %{}}])

    refute_receive {:coordination_updated, _snapshot}
  end

  test "concurrent optimistic appends produce one winner" do
    {:ok, task} = Coordination.start_task(task_attrs("concurrent-append"))
    parent = self()

    contenders =
      for phase <- ["routing-a", "routing-b"] do
        Task.async(fn ->
          send(parent, {:append_ready, self()})

          receive do
            :append ->
              Coordination.append(task.id, 1, [
                %{type: :planning_started, data: %{phase: phase}}
              ])
          end
        end)
      end

    contender_pids =
      for _index <- 1..2 do
        assert_receive {:append_ready, pid}
        pid
      end

    Enum.each(contender_pids, &send(&1, :append))
    results = Enum.map(contenders, &Task.await/1)

    assert 1 == Enum.count(results, &(&1 == {:ok, 2}))
    assert 1 == Enum.count(results, &(&1 == {:error, :stale_stream}))
    assert {:ok, %{version: 2, status: :planning}} = Coordination.snapshot(task.id)
  end

  test "invalid task identifiers fail without raising database cast errors" do
    assert {:error, :not_found} = Coordination.snapshot("not-a-uuid")

    assert {:error, :not_found} =
             Coordination.append("not-a-uuid", 0, [%{type: :planning_started, data: %{}}])

    assert {:error, :not_found} = Coordination.rebuild_projection("not-a-uuid")

    attrs = task_attrs("invalid-id") |> Map.put(:id, "not-a-uuid")
    assert {:error, :invalid_task_id} = Coordination.start_task(attrs)
  end

  defp task_attrs(suffix) do
    %{
      idempotency_key: "github:WangShayne/Symphony-works:#{suffix}",
      external_id: "issue-#{suffix}",
      config_revision_id: Ecto.UUID.generate(),
      baseline: "0123456789abcdef",
      actor: %{kind: :service, id: "scheduler"},
      plan_revision: "plan-1",
      correlation_id: Ecto.UUID.generate()
    }
  end
end
