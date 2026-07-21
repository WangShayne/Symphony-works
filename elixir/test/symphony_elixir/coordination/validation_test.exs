defmodule SymphonyElixir.Coordination.ValidationTest do
  use SymphonyElixir.DataCase, async: false

  import Ecto.Query

  alias SymphonyElixir.{Coordination, Repo}
  alias SymphonyElixir.Coordination.Event

  test "rejects malformed task creation attributes" do
    assert {:error, :invalid_attributes} = Coordination.start_task(nil)
    assert {:error, :invalid_attributes} = Coordination.start_task([])
    assert {:error, {:required, "idempotency_key"}} = Coordination.start_task(%{})

    assert {:error, {:required, "idempotency_key"}} =
             Coordination.start_task(%{idempotency_key: ""})

    assert {:error, :invalid_attribute_key} =
             Coordination.start_task(%{1 => "invalid", idempotency_key: "invalid-key"})

    assert {:error, :invalid_attribute_value} =
             Coordination.start_task(%{idempotency_key: "invalid-value", value: self()})

    assert {:error, :invalid_attribute_value} =
             Coordination.start_task(%{idempotency_key: "invalid-list", values: [self()]})

    assert {:error, {:sensitive_data, ["items", 0, "secret"]}} =
             Coordination.start_task(%{
               idempotency_key: "sensitive-list",
               items: [%{secret: "must-not-persist"}]
             })
  end

  test "accepts JSON string keys and list values deterministically" do
    attrs = %{
      "idempotency_key" => "string-keys",
      "external_id" => "STRING-1",
      "config_revision_id" => Ecto.UUID.generate(),
      "baseline" => "0123456789abcdef",
      "labels" => ["backend", "urgent"]
    }

    assert {:ok, first} = Coordination.start_task(attrs)
    assert first.data["labels"] == ["backend", "urgent"]
    assert {:ok, ^first} = Coordination.start_task(attrs)
  end

  test "rejects malformed task actors without persisting the task stream" do
    for {actor, suffix} <- [
          {"not-a-map", "string"},
          {%{kind: :service}, "missing-id"},
          {%{id: "scheduler"}, "missing-kind"}
        ] do
      task_id = Ecto.UUID.generate()

      assert {:error, :invalid_actor} =
               start_task("invalid-actor-#{suffix}", id: task_id, actor: actor)

      assert [] = Coordination.list(idempotency_key: "validation:invalid-actor-#{suffix}")

      assert 0 ==
               Repo.aggregate(
                 from(event in Event, where: event.task_id == ^task_id),
                 :count
               )
    end
  end

  test "rejects malformed append events without advancing the stream" do
    {:ok, task} = start_task("invalid-events")

    assert {:error, :invalid_append} = Coordination.append(task.id, 1, [])
    assert {:error, :invalid_append} = Coordination.append(task.id, -1, [%{}])
    assert {:error, :invalid_append} = Coordination.append(nil, 1, [%{}])

    assert {:error, {:required, "type"}} = Coordination.append(task.id, 1, [%{}])

    for data <- [nil, false, "not-a-map"] do
      assert {:error, :invalid_event_data} =
               Coordination.append(task.id, 1, [%{type: :planning_started, data: data}])
    end

    assert {:error, :invalid_event_version} =
             Coordination.append(task.id, 1, [
               %{type: :planning_started, version: 0, data: %{}}
             ])

    assert {:error, :unsupported_event_version} =
             Coordination.append(task.id, 1, [
               %{type: :planning_started, version: 2, data: %{}}
             ])

    for stream_version <- [1, 2] do
      assert {:error, {:forbidden_event_fields, :planning_started, ["stream_version"]}} =
               Coordination.append(task.id, 1, [
                 %{type: :planning_started, stream_version: stream_version, data: %{}}
               ])
    end

    assert {:error, :invalid_actor} =
             Coordination.append(task.id, 1, [
               %{type: :planning_started, actor: %{kind: :model}, data: %{}}
             ])

    assert {:error, :invalid_unit_id} =
             Coordination.append(task.id, 1, [%{type: :unit_planned, data: %{}}])

    unknown_type = "unknown-event-#{System.unique_integer([:positive])}"

    assert {:error, {:unknown_event_type, ^unknown_type}} =
             Coordination.append(task.id, 1, [%{type: unknown_type, data: %{}}])

    assert {:ok, %{version: 1}} = Coordination.snapshot(task.id)
  end

  test "rejects invalid subscription, rebuild, and lease inputs" do
    assert {:error, :invalid_task_id} = Coordination.subscribe(nil)
    assert {:error, :not_found} = Coordination.snapshot(nil)
    assert {:error, :not_found} = Coordination.rebuild_projection(nil)
    assert [] = Coordination.list(nil)
    assert {:error, :invalid_ttl} = Coordination.acquire_lease("holder-a", ttl_ms: 0)
    assert {:error, :invalid_ttl} = Coordination.acquire_lease("holder-a", [])
    assert {:error, :invalid_lease} = Coordination.acquire_lease("", ttl_ms: 1_000)
    assert {:error, :invalid_lease} = Coordination.acquire_lease("holder-a", %{})
  end

  test "a duplicate task id fails without leaking the persistence error" do
    task_id = Ecto.UUID.generate()
    {:ok, _task} = start_task("duplicate-id-a", id: task_id)

    assert {:error, :task_start_failed} = start_task("duplicate-id-b", id: task_id)
  end

  test "rejects non-string explicit task identifiers and missing canonical streams" do
    assert {:error, :invalid_task_id} = start_task("numeric-id", id: 123)

    missing_id = Ecto.UUID.generate()

    assert {:error, :not_found} =
             Coordination.append(missing_id, 0, [%{type: :planning_started, data: %{}}])
  end

  test "concurrent equivalent starts converge on one idempotent snapshot" do
    parent = self()
    idempotency_key = "concurrent-start:#{Ecto.UUID.generate()}"
    configuration_revision = Ecto.UUID.generate()

    contenders =
      for _index <- 1..12 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :start ->
              Coordination.start_task(%{
                id: Ecto.UUID.generate(),
                idempotency_key: idempotency_key,
                external_id: "CONCURRENT-1",
                config_revision_id: configuration_revision,
                baseline: "0123456789abcdef"
              })
          end
        end)
      end

    contender_pids =
      for _index <- contenders do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(contender_pids, &send(&1, :start))
    results = Enum.map(contenders, &Task.await/1)

    assert Enum.all?(results, &match?({:ok, _snapshot}, &1))
    assert 1 == results |> Enum.map(fn {:ok, snapshot} -> snapshot.id end) |> Enum.uniq() |> length()
  end

  defp start_task(suffix, extra \\ %{}) do
    %{
      idempotency_key: "validation:#{suffix}",
      external_id: "TASK-#{suffix}",
      config_revision_id: Ecto.UUID.generate(),
      baseline: "0123456789abcdef"
    }
    |> Map.merge(Map.new(extra))
    |> Coordination.start_task()
  end
end
