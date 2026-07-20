defmodule SymphonyElixir.TaskCreationTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.{Audit, Configuration, Coordination, Effects, TaskCreation}
  alias SymphonyElixir.Configuration.{Document, Revision}
  alias SymphonyElixir.Effects.Record
  alias SymphonyElixir.Identity.Principal

  defmodule FailingAdapter do
    @moduledoc false

    @spec execute(Record.t()) :: {:error, :provider_down}
    def execute(_record), do: {:error, :provider_down}

    @spec reconcile(Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule InterruptedAdapter do
    @moduledoc false

    @spec execute(Record.t()) :: {:unknown, :interrupted}
    def execute(_record), do: {:unknown, :interrupted}

    @spec reconcile(Record.t()) :: {:unknown, :interrupted}
    def reconcile(_record), do: {:unknown, :interrupted}
  end

  defmodule StaleProjectionAdapter do
    @moduledoc false

    alias SymphonyElixir.Coordination

    @spec execute(Record.t()) :: {:error, :provider_down}
    def execute(record) do
      {:ok, task} = Coordination.snapshot(record.task_id)
      {:ok, _version} = Coordination.append(task.id, task.version, [%{type: :planning_started, data: %{}}])
      {:error, :provider_down}
    end

    @spec reconcile(Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule MissingProjectionAdapter do
    @moduledoc false

    import Ecto.Query

    alias SymphonyElixir.{Coordination, Repo}
    alias SymphonyElixir.Coordination.{TaskProjection, UnitProjection}

    @spec execute(Record.t()) :: {:error, :provider_down}
    def execute(record) do
      {:ok, task} = Coordination.snapshot(record.task_id)
      {:ok, _version} = Coordination.append(task.id, task.version, [%{type: :planning_started, data: %{}}])

      Repo.delete_all(from(unit in UnitProjection, where: unit.task_id == ^record.task_id))
      Repo.delete_all(from(task in TaskProjection, where: task.task_id == ^record.task_id))

      {:error, :provider_down}
    end

    @spec reconcile(Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  defmodule MissingInterruptedProjectionAdapter do
    @moduledoc false

    import Ecto.Query

    alias SymphonyElixir.Coordination.{TaskProjection, UnitProjection}
    alias SymphonyElixir.Repo

    @spec execute(Record.t()) :: {:unknown, :interrupted}
    def execute(record) do
      Repo.delete_all(from(unit in UnitProjection, where: unit.task_id == ^record.task_id))
      Repo.delete_all(from(task in TaskProjection, where: task.task_id == ^record.task_id))

      {:unknown, :interrupted}
    end

    @spec reconcile(Record.t()) :: {:unknown, :interrupted}
    def reconcile(_record), do: {:unknown, :interrupted}
  end

  defmodule TerminalProjectionAdapter do
    @moduledoc false

    alias SymphonyElixir.Coordination

    @spec execute(Record.t()) :: {:error, :provider_down}
    def execute(record) do
      {:ok, task} = Coordination.snapshot(record.task_id)
      {:ok, _version} = Coordination.append(task.id, task.version, [%{type: :task_failed, data: %{}}])
      {:error, :provider_down}
    end

    @spec reconcile(Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  setup do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")

    principal = %Principal{
      id: Ecto.UUID.generate(),
      subject: "task-creation-test",
      roles: [:operator]
    }

    %{active: active, principal: principal}
  end

  test "task intent validation rejects ambiguous or unsafe shapes", %{principal: principal} do
    valid = valid_intent()

    assert {:error, :invalid_task} = TaskCreation.create(valid, %{}, "invalid-actor")
    assert {:error, :invalid_idempotency_key} = TaskCreation.create(valid, principal, nil)
    assert {:error, :invalid_idempotency_key} = TaskCreation.create(valid, principal, " ")

    invalid_intents = [
      Map.delete(valid, "external_id"),
      Map.put(valid, "summary", String.duplicate("x", 501)),
      Map.put(valid, "baseline_commit", "not-a-commit"),
      Map.put(valid, "plan_revision", "revision-one"),
      Map.put(valid, "plan_revision", 0),
      Map.put(valid, "units", []),
      Map.put(valid, "units", Enum.map(1..101, &unit("unit-#{&1}"))),
      Map.put(valid, "units", [%{"id" => "unit-missing-type"}]),
      Map.put(valid, "units", ["not-a-unit"]),
      Map.put(valid, "units", [unit("duplicate"), unit("duplicate")]),
      Map.put(valid, "units", [unit("invalid-profile", %{"execution_profile_id" => 123})]),
      Map.put(valid, "units", [
        unit("invalid-dependency", %{"dependencies" => ["valid-unit", %{id: "not-a-string"}]})
      ])
    ]

    invalid_intents
    |> Enum.with_index()
    |> Enum.each(fn {intent, index} ->
      assert {:error, {:invalid_task, _field}} =
               TaskCreation.create(intent, principal, "invalid-intent-#{index}")
    end)
  end

  test "task creation accepts a numeric plan reference and normalizes optional unit dependencies", %{
    active: active,
    principal: principal
  } do
    intent =
      valid_intent()
      |> Map.put("plan_revision", "001")
      |> Map.put("units", [
        unit("normalized-unit", %{
          "dependencies" => ["unit-a", ""],
          "execution_profile_id" => "backend-profile"
        }),
        unit("defaulted-unit", %{
          "execution_profile_id" => " ",
          "model_reference_id" => " "
        })
      ])

    assert {:ok, task, :created} =
             TaskCreation.create(intent, principal, "normalized-task")

    assert task.plan_revision == "1"
    assert task.configuration_revision == active.id

    assert [
             %{id: "normalized-unit", dependencies: ["unit-a"]},
             %{id: "defaulted-unit", execution_profile: "profile-backend"}
           ] = task.units
  end

  test "task input, profile, model, and dependency references stay bounded", %{
    principal: principal
  } do
    bounded_reference = String.duplicate("r", 200)

    bounded =
      valid_intent()
      |> Map.put("units", [
        unit("bounded-unit", %{
          "execution_profile_id" => bounded_reference,
          "model_reference_id" => bounded_reference,
          "dependencies" => [bounded_reference]
        })
      ])

    assert {:ok, task, :created} =
             TaskCreation.create(bounded, principal, "bounded-task-input")

    assert [unit] = task.units
    assert unit.execution_profile == bounded_reference
    assert unit.dependencies == [bounded_reference]

    invalid_intents = [
      Map.put(valid_intent(), "metadata", %{"blob" => String.duplicate("x", 65_536)}),
      Map.put(valid_intent(), "units", [unit("profile-too-large", %{"execution_profile_id" => bounded_reference <> "x"})]),
      Map.put(valid_intent(), "units", [unit("model-too-large", %{"model_reference_id" => bounded_reference <> "x"})]),
      Map.put(valid_intent(), "units", [unit("dependency-too-large", %{"dependencies" => [bounded_reference <> "x"]})]),
      Map.put(valid_intent(), "units", [unit("too-many-dependencies", %{"dependencies" => Enum.map(1..101, &"unit-#{&1}")})])
    ]

    invalid_intents
    |> Enum.with_index()
    |> Enum.each(fn {intent, index} ->
      assert {:error, {:invalid_task, _field}} =
               TaskCreation.create(intent, principal, "bounded-invalid-#{index}")
    end)
  end

  test "missing active configuration blocks task creation before coordination state exists", %{
    principal: principal
  } do
    Repo.delete_all(Revision)

    assert {:error, :active_configuration_required} =
             TaskCreation.create(valid_intent(), principal, "missing-active-config")

    assert Coordination.list(idempotency_key: "missing-active-config") == []
  end

  test "failed external effect leaves an explicit recovery-needed projection", %{
    principal: principal
  } do
    assert {:error, {:effect_failed, :provider_down}} =
             TaskCreation.create(valid_intent(), principal, "failed-task-effect", effect_adapter: FailingAdapter)

    assert [task] = Coordination.list(idempotency_key: "failed-task-effect")
    assert task.status == :awaiting_intervention
    assert task.effect_status == :recovery_needed
    assert task.effect.operation_id == nil
  end

  test "interrupted external effects leave an explicit unknown projection", %{
    principal: principal
  } do
    assert {:error, :effect_interrupted} =
             TaskCreation.create(valid_intent(), principal, "interrupted-task-effect", effect_adapter: InterruptedAdapter)

    assert [task] = Coordination.list(idempotency_key: "interrupted-task-effect")
    assert task.status == :queued
    assert task.effect_status == :unknown
    assert task.effect.operation_id == nil
  end

  test "effect recovery retries after a concurrent projection update", %{principal: principal} do
    assert {:error, {:effect_failed, :provider_down}} =
             TaskCreation.create(valid_intent(), principal, "stale-effect-projection", effect_adapter: StaleProjectionAdapter)

    assert [task] = Coordination.list(idempotency_key: "stale-effect-projection")
    assert task.status == :awaiting_intervention
    assert task.effect_status == :recovery_needed
  end

  test "effect recovery reports a missing projection after a stale append", %{principal: principal} do
    assert {:error, {:recovery_record_failed, :not_found}} =
             TaskCreation.create(valid_intent(), principal, "missing-effect-projection", effect_adapter: MissingProjectionAdapter)
  end

  test "effect recovery reports a terminal-state persistence conflict", %{principal: principal} do
    assert {:error, {:recovery_record_failed, {:invalid_task_transition, :failed, :task_recovery_needed}}} =
             TaskCreation.create(valid_intent(), principal, "terminal-effect-projection", effect_adapter: TerminalProjectionAdapter)

    assert [task] = Coordination.list(idempotency_key: "terminal-effect-projection")
    assert task.status == :failed
  end

  test "interrupted effect reports a missing projection append failure", %{principal: principal} do
    assert {:error, :not_found} =
             TaskCreation.create(valid_intent(), principal, "missing-interrupted-projection", effect_adapter: MissingInterruptedProjectionAdapter)
  end

  test "audit dedupe conflicts preserve the existing effect identity for recovery", %{
    active: active,
    principal: principal
  } do
    key = "conflicting-task-audit"
    operation_id = Ecto.UUID.generate()
    intent = valid_intent()

    assert {:ok, started} = prestart_task(intent, principal, active, key)

    assert {:ok, 2} =
             Coordination.append(started.id, started.version, [
               %{
                 type: :effect_succeeded,
                 actor: %{kind: :principal, id: principal.id},
                 correlation_id: key,
                 data: %{operation_id: operation_id, status: :succeeded}
               }
             ])

    assert {:ok, _conflict} =
             Audit.record(
               :conflicting_task_event,
               %{
                 dedupe_key: "task_created:#{started.id}",
                 task_id: started.id,
                 correlation_id: key,
                 outcome: :succeeded
               },
               principal
             )

    assert {:error, :audit_unavailable} = TaskCreation.create(intent, principal, key)
    assert {:ok, recovered} = Coordination.snapshot(started.id)
    assert recovered.status == :awaiting_intervention
    assert recovered.effect_status == :recovery_needed
    assert recovered.effect.operation_id == operation_id
  end

  test "concurrent resumptions retry unit planning from the latest projection", %{
    active: active,
    principal: principal
  } do
    key = "stale-unit-projection"
    intent = valid_intent()
    assert {:ok, started} = prestart_task(intent, principal, active, key)

    barrier_ref = make_ref()
    attach_unit_snapshot_barrier(barrier_ref, self())

    contenders =
      for _index <- 1..2 do
        Task.async(fn ->
          Process.put({__MODULE__, :unit_snapshot_barrier}, {barrier_ref, 0, 1})
          TaskCreation.create(intent, principal, key)
        end)
      end

    contender_pids = MapSet.new(contenders, & &1.pid)

    arrived_pids =
      for _index <- 1..2 do
        assert_receive {:unit_snapshot_loaded, ^barrier_ref, pid}, 5_000
        pid
      end

    assert MapSet.new(arrived_pids) == contender_pids

    [first, second] = contenders
    send(first.pid, {:release_unit_snapshot, barrier_ref})
    assert {:ok, first_task, :resumed} = Task.await(first, 10_000)

    send(second.pid, {:release_unit_snapshot, barrier_ref})
    assert {:ok, second_task, :resumed} = Task.await(second, 10_000)

    assert first_task.id == started.id
    assert second_task.id == started.id
    assert [%{id: "unit-task-creation"}] = second_task.units
  end

  test "unit planning stops after bounded repeated version conflicts", %{
    active: active,
    principal: principal
  } do
    key = "exhausted-unit-projection"
    intent = valid_intent()
    assert {:ok, started} = prestart_task(intent, principal, active, key)

    barrier_ref = make_ref()
    attach_unit_snapshot_barrier(barrier_ref, self())

    contender =
      Task.async(fn ->
        Process.put({__MODULE__, :unit_snapshot_barrier}, {barrier_ref, 0, 3})
        TaskCreation.create(intent, principal, key)
      end)

    force_stale_snapshots(started.id, barrier_ref, 3)
    assert {:error, :coordination_conflict} = Task.await(contender, 10_000)
  end

  test "effect recovery stops after bounded repeated version conflicts", %{
    active: active,
    principal: principal
  } do
    key = "exhausted-effect-projection"
    intent = valid_intent()
    assert {:ok, started} = prestart_task(intent, principal, active, key)
    assert {:ok, _planned} = preplan_unit(started, intent, principal, key)

    barrier_ref = make_ref()
    attach_unit_snapshot_barrier(barrier_ref, self())

    contender =
      Task.async(fn ->
        Process.put({__MODULE__, :unit_snapshot_barrier}, {barrier_ref, 1, 2})

        TaskCreation.create(intent, principal, key, effect_adapter: StaleProjectionAdapter)
      end)

    force_stale_snapshots(started.id, barrier_ref, 2)

    assert {:error, {:recovery_record_failed, :coordination_conflict}} =
             Task.await(contender, 10_000)
  end

  test "terminal tasks reject newly planned units", %{
    active: active,
    principal: principal
  } do
    key = "terminal-unit-projection"
    intent = valid_intent()
    assert {:ok, started} = prestart_task(intent, principal, active, key)

    assert {:ok, _version} =
             Coordination.append(started.id, started.version, [%{type: :task_failed, data: %{}}])

    assert {:error, {:invalid_task_transition, :failed, :unit_planned}} =
             TaskCreation.create(intent, principal, key)
  end

  test "concurrent identical task creation produces one task, audit, and external invocation", %{
    principal: principal
  } do
    key = "concurrent-task-creation"

    results =
      1..8
      |> Task.async_stream(
        fn _index -> TaskCreation.create(valid_intent(), principal, key) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _task, _kind}, &1))

    ids = Enum.map(results, fn {:ok, task, _kind} -> task.id end) |> Enum.uniq()
    assert [task_id] = ids
    assert Enum.count(Audit.list(task_id: task_id), &(&1.action == "task_created")) == 1
    assert Enum.count(Effects.list(task_id: task_id)) == 1
  end

  defp valid_intent do
    %{
      "external_id" => "GH-TASK-CREATION",
      "summary" => "Create a durable task",
      "baseline_commit" => String.duplicate("d", 40),
      "plan_revision" => 1,
      "units" => [unit("unit-task-creation")]
    }
  end

  defp unit(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "task_type" => "backend",
        "model_reference_id" => "model-backend-primary"
      },
      overrides
    )
  end

  defp prestart_task(intent, principal, active, key) do
    [unit] = intent["units"]
    {plan_revision, ""} = intent["plan_revision"] |> to_string() |> Integer.parse()

    Coordination.start_task(%{
      idempotency_key: key,
      external_id: intent["external_id"],
      configuration_revision: active.id,
      plan_revision: Integer.to_string(plan_revision),
      baseline: intent["baseline_commit"],
      correlation_id: key,
      actor: %{kind: :principal, id: principal.id},
      data: %{
        "summary" => intent["summary"],
        "units" => [
          %{
            "id" => unit["id"],
            "task_type" => unit["task_type"],
            "execution_profile" => unit["execution_profile_id"] || "profile-#{unit["task_type"]}",
            "model_reference_id" => unit["model_reference_id"],
            "dependencies" => Enum.filter(unit["dependencies"] || [], &(is_binary(&1) and &1 != ""))
          }
        ]
      }
    })
  end

  defp preplan_unit(started, intent, principal, key) do
    [unit] = intent["units"]

    with {:ok, _version} <-
           Coordination.append(started.id, started.version, [
             %{
               type: :unit_planned,
               actor: %{kind: :principal, id: principal.id},
               correlation_id: key,
               data: %{
                 unit_id: unit["id"],
                 task_type: unit["task_type"],
                 execution_profile: unit["execution_profile_id"] || "profile-#{unit["task_type"]}",
                 model_reference_id: unit["model_reference_id"],
                 dependencies: unit["dependencies"] || []
               }
             }
           ]) do
      Coordination.snapshot(started.id)
    end
  end

  defp attach_unit_snapshot_barrier(barrier_ref, parent) do
    handler_id = {__MODULE__, barrier_ref}
    telemetry_prefix = Keyword.get(Repo.config(), :telemetry_prefix, [:symphony_elixir, :repo])

    :ok =
      :telemetry.attach(
        handler_id,
        telemetry_prefix ++ [:query],
        fn _event, _measurements, metadata, %{parent: parent, ref: ref} ->
          marker = Process.get({__MODULE__, :unit_snapshot_barrier})

          if unit_snapshot_query?(metadata), do: handle_snapshot_marker(marker, ref, parent)
        end,
        %{parent: parent, ref: barrier_ref}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp handle_snapshot_marker({ref, skip, remaining}, ref, _parent) when skip > 0 do
    Process.put({__MODULE__, :unit_snapshot_barrier}, {ref, skip - 1, remaining})
  end

  defp handle_snapshot_marker({ref, 0, remaining}, ref, parent) when remaining > 0 do
    if remaining == 1 do
      Process.delete({__MODULE__, :unit_snapshot_barrier})
    else
      Process.put({__MODULE__, :unit_snapshot_barrier}, {ref, 0, remaining - 1})
    end

    send(parent, {:unit_snapshot_loaded, ref, self()})

    receive do
      {:release_unit_snapshot, ^ref} -> :ok
    end
  end

  defp handle_snapshot_marker(_marker, _ref, _parent), do: :ok

  defp force_stale_snapshots(task_id, barrier_ref, count) do
    for _index <- 1..count do
      assert_receive {:unit_snapshot_loaded, ^barrier_ref, contender}, 5_000
      assert {:ok, current} = Coordination.snapshot(task_id)

      assert {:ok, _version} =
               Coordination.append(current.id, current.version, [
                 %{
                   type: :effect_unknown,
                   data: %{operation_id: Ecto.UUID.generate(), status: :unknown}
                 }
               ])

      send(contender, {:release_unit_snapshot, barrier_ref})
    end
  end

  defp unit_snapshot_query?(metadata) do
    query =
      case Map.get(metadata, :query) do
        query when is_binary(query) -> String.downcase(query)
        query when is_list(query) -> query |> IO.iodata_to_binary() |> String.downcase()
        _other -> ""
      end

    source = Map.get(metadata, :source)

    (source == "coordination_unit_projections" or
       String.contains?(query, "coordination_unit_projections")) and
      String.contains?(query, "unit_id") and
      not String.contains?(query, "count(")
  end

  defp valid_document do
    Document.for_project(%{
      "id" => "symphony",
      "name" => "Symphony",
      "tracker" => %{"kind" => "github", "scope" => "WangShayne/Symphony-works"},
      "repository" => %{
        "url" => "git@github.com:WangShayne/Symphony-works.git",
        "target_branch" => "main"
      }
    })
  end
end
