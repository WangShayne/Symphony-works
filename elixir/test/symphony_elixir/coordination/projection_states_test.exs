defmodule SymphonyElixir.Coordination.ProjectionStatesTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Coordination

  @task_events [
    :planning_started,
    :execution_started,
    :task_blocked,
    :task_recovery_needed,
    :integration_started,
    :task_validation_started,
    :task_acceptance_passed,
    :change_request_merged,
    :task_failed,
    :task_cancelled,
    :effect_succeeded,
    :effect_unknown
  ]

  @task_paths %{
    queued: [],
    planning: [:planning_started],
    running: [:planning_started, :execution_started],
    awaiting_intervention: [:task_recovery_needed],
    integrating: [:planning_started, :execution_started, :integration_started],
    validating: [
      :planning_started,
      :execution_started,
      :integration_started,
      :task_validation_started
    ],
    review_ready: [
      :planning_started,
      :execution_started,
      :integration_started,
      :task_validation_started,
      :task_acceptance_passed
    ],
    completed: [
      :planning_started,
      :execution_started,
      :integration_started,
      :task_validation_started,
      :task_acceptance_passed,
      :change_request_merged
    ],
    failed: [:task_failed],
    cancelled: [:task_cancelled]
  }

  @task_allowed %{
    queued: %{
      planning_started: :planning,
      task_recovery_needed: :awaiting_intervention,
      task_failed: :failed,
      task_cancelled: :cancelled,
      effect_succeeded: :queued,
      effect_unknown: :queued
    },
    planning: %{
      execution_started: :running,
      task_recovery_needed: :awaiting_intervention,
      task_failed: :failed,
      task_cancelled: :cancelled,
      effect_succeeded: :planning,
      effect_unknown: :planning
    },
    running: %{
      task_blocked: :awaiting_intervention,
      task_recovery_needed: :awaiting_intervention,
      integration_started: :integrating,
      task_failed: :failed,
      task_cancelled: :cancelled,
      effect_succeeded: :running,
      effect_unknown: :running
    },
    awaiting_intervention: %{
      planning_started: :planning,
      task_recovery_needed: :awaiting_intervention,
      task_failed: :failed,
      task_cancelled: :cancelled,
      effect_succeeded: :awaiting_intervention,
      effect_unknown: :awaiting_intervention
    },
    integrating: %{
      task_recovery_needed: :awaiting_intervention,
      task_validation_started: :validating,
      task_failed: :failed,
      task_cancelled: :cancelled,
      effect_succeeded: :integrating,
      effect_unknown: :integrating
    },
    validating: %{
      task_recovery_needed: :awaiting_intervention,
      task_acceptance_passed: :review_ready,
      task_failed: :failed,
      task_cancelled: :cancelled,
      effect_succeeded: :validating,
      effect_unknown: :validating
    },
    review_ready: %{
      task_recovery_needed: :awaiting_intervention,
      change_request_merged: :completed,
      task_failed: :failed,
      task_cancelled: :cancelled,
      effect_succeeded: :review_ready,
      effect_unknown: :review_ready
    },
    completed: %{effect_succeeded: :completed, effect_unknown: :completed},
    failed: %{effect_succeeded: :failed, effect_unknown: :failed},
    cancelled: %{effect_succeeded: :cancelled, effect_unknown: :cancelled}
  }

  @unit_events [
    :unit_runnable,
    :unit_started,
    :unit_blocked,
    :unit_awaiting_approval,
    :unit_accepted,
    :unit_failed,
    :unit_cancelled,
    :unit_progress
  ]

  @unit_paths %{
    pending: [],
    runnable: [:unit_runnable],
    running: [:unit_runnable, :unit_started],
    blocked: [:unit_runnable, :unit_blocked],
    awaiting_approval: [:unit_runnable, :unit_started, :unit_awaiting_approval],
    accepted: [:unit_runnable, :unit_started, :unit_accepted],
    failed: [:unit_failed],
    cancelled: [:unit_cancelled]
  }

  @unit_allowed %{
    pending: %{
      unit_runnable: :runnable,
      unit_failed: :failed,
      unit_cancelled: :cancelled,
      unit_progress: :pending
    },
    runnable: %{
      unit_started: :running,
      unit_blocked: :blocked,
      unit_failed: :failed,
      unit_cancelled: :cancelled,
      unit_progress: :runnable
    },
    running: %{
      unit_blocked: :blocked,
      unit_awaiting_approval: :awaiting_approval,
      unit_accepted: :accepted,
      unit_failed: :failed,
      unit_cancelled: :cancelled,
      unit_progress: :running
    },
    blocked: %{
      unit_runnable: :runnable,
      unit_failed: :failed,
      unit_cancelled: :cancelled,
      unit_progress: :blocked
    },
    awaiting_approval: %{
      unit_accepted: :accepted,
      unit_failed: :failed,
      unit_cancelled: :cancelled,
      unit_progress: :awaiting_approval
    },
    accepted: %{},
    failed: %{},
    cancelled: %{}
  }

  test "task state transitions exhaustively allow only the service-defined graph" do
    for {source, path} <- @task_paths, event <- @task_events do
      task = task_in_state(source, path, event)

      case get_in(@task_allowed, [source, event]) do
        nil ->
          assert {:error, {:invalid_task_transition, ^source, ^event}} =
                   Coordination.append(task.id, task.version, [task_event(event)])

          assert {:ok, %{status: ^source, version: version}} = Coordination.snapshot(task.id)
          assert version == task.version

        target ->
          assert {:ok, next_version} =
                   Coordination.append(task.id, task.version, [task_event(event)])

          assert {:ok, %{status: ^target, version: ^next_version}} =
                   Coordination.snapshot(task.id)
      end
    end

    task = task_in_state(:review_ready, @task_paths.review_ready, :task_completed)

    assert {:error, {:unknown_event_type, :task_completed}} =
             Coordination.append(task.id, task.version, [%{type: :task_completed, data: %{}}])
  end

  test "unit state transitions exhaustively reject terminal regressions and invented completion" do
    for {source, path} <- @unit_paths, event <- @unit_events do
      task = unit_in_state(source, path, event)

      case get_in(@unit_allowed, [source, event]) do
        nil ->
          assert {:error, {:invalid_unit_transition, "unit-1", ^source, ^event}} =
                   Coordination.append(task.id, task.version, [unit_event(event)])

          assert {:ok, %{units: [%{status: ^source}], version: version}} =
                   Coordination.snapshot(task.id)

          assert version == task.version

        target ->
          assert {:ok, next_version} =
                   Coordination.append(task.id, task.version, [unit_event(event)])

          assert {:ok, %{units: [%{status: ^target}], version: ^next_version}} =
                   Coordination.snapshot(task.id)
      end
    end

    task = unit_in_state(:running, @unit_paths.running, :unit_completed)

    assert {:error, {:unknown_event_type, :unit_completed}} =
             Coordination.append(task.id, task.version, [unit_event(:unit_completed)])

    pending = unit_in_state(:pending, [], :duplicate_unit_planned)

    assert {:error, {:invalid_unit_transition, "unit-1", :pending, :unit_planned}} =
             Coordination.append(pending.id, pending.version, [unit_event(:unit_planned)])
  end

  test "terminal tasks reject new and continuing unit work" do
    for source <- [:completed, :failed, :cancelled], event <- [:unit_planned, :unit_progress] do
      {:ok, task} = start_task("terminal-task-#{source}-#{event}")
      task = append_events(task, [unit_event(:unit_planned)])
      task = append_events(task, Enum.map(Map.fetch!(@task_paths, source), &task_event/1))

      assert {:error, {:invalid_task_transition, ^source, ^event}} =
               Coordination.append(task.id, task.version, [unit_event(event)])

      assert {:ok, %{status: ^source, version: version}} = Coordination.snapshot(task.id)
      assert version == task.version
    end
  end

  defp task_in_state(source, path, candidate) do
    {:ok, task} = start_task("task-#{source}-#{candidate}")
    task = append_events(task, Enum.map(path, &task_event/1))
    assert task.status == source
    task
  end

  defp unit_in_state(source, path, candidate) do
    {:ok, task} = start_task("unit-#{source}-#{candidate}")
    task = append_events(task, [unit_event(:unit_planned)])
    task = append_events(task, Enum.map(path, &unit_event/1))
    assert [%{status: ^source}] = task.units
    task
  end

  defp append_events(task, []), do: task

  defp append_events(task, events) do
    assert {:ok, _version} = Coordination.append(task.id, task.version, events)
    assert {:ok, updated} = Coordination.snapshot(task.id)
    updated
  end

  defp task_event(event) when event in [:effect_succeeded, :effect_unknown] do
    %{type: event, data: %{operation_id: "op-#{event}"}}
  end

  defp task_event(event), do: %{type: event, data: %{}}

  defp unit_event(:unit_planned) do
    %{
      type: :unit_planned,
      data: %{
        unit_id: "unit-1",
        task_type: "backend",
        execution_profile: "backend-default",
        dependencies: []
      }
    }
  end

  defp unit_event(event), do: %{type: event, data: %{unit_id: "unit-1"}}

  defp start_task(suffix) do
    Coordination.start_task(%{
      idempotency_key: "state-machine:#{suffix}:#{Ecto.UUID.generate()}",
      external_id: "TASK-#{suffix}",
      config_revision_id: Ecto.UUID.generate(),
      baseline: "0123456789abcdef"
    })
  end
end
