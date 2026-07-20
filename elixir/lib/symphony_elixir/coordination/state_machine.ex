defmodule SymphonyElixir.Coordination.StateMachine do
  @moduledoc false

  @task_transitions %{
    "queued" => %{
      "planning_started" => "planning",
      "task_recovery_needed" => "awaiting_intervention",
      "task_failed" => "failed",
      "task_cancelled" => "cancelled",
      "effect_succeeded" => "queued",
      "effect_unknown" => "queued"
    },
    "planning" => %{
      "execution_started" => "running",
      "task_recovery_needed" => "awaiting_intervention",
      "task_failed" => "failed",
      "task_cancelled" => "cancelled",
      "effect_succeeded" => "planning",
      "effect_unknown" => "planning"
    },
    "running" => %{
      "task_blocked" => "awaiting_intervention",
      "task_recovery_needed" => "awaiting_intervention",
      "integration_started" => "integrating",
      "task_failed" => "failed",
      "task_cancelled" => "cancelled",
      "effect_succeeded" => "running",
      "effect_unknown" => "running"
    },
    "awaiting_intervention" => %{
      "planning_started" => "planning",
      "task_recovery_needed" => "awaiting_intervention",
      "task_failed" => "failed",
      "task_cancelled" => "cancelled",
      "effect_succeeded" => "awaiting_intervention",
      "effect_unknown" => "awaiting_intervention"
    },
    "integrating" => %{
      "task_recovery_needed" => "awaiting_intervention",
      "task_validation_started" => "validating",
      "task_failed" => "failed",
      "task_cancelled" => "cancelled",
      "effect_succeeded" => "integrating",
      "effect_unknown" => "integrating"
    },
    "validating" => %{
      "task_recovery_needed" => "awaiting_intervention",
      "task_acceptance_passed" => "review_ready",
      "task_failed" => "failed",
      "task_cancelled" => "cancelled",
      "effect_succeeded" => "validating",
      "effect_unknown" => "validating"
    },
    "review_ready" => %{
      "task_recovery_needed" => "awaiting_intervention",
      "change_request_merged" => "completed",
      "task_failed" => "failed",
      "task_cancelled" => "cancelled",
      "effect_succeeded" => "review_ready",
      "effect_unknown" => "review_ready"
    },
    "completed" => %{
      "effect_succeeded" => "completed",
      "effect_unknown" => "completed"
    },
    "failed" => %{
      "effect_succeeded" => "failed",
      "effect_unknown" => "failed"
    },
    "cancelled" => %{
      "effect_succeeded" => "cancelled",
      "effect_unknown" => "cancelled"
    }
  }

  @unit_transitions %{
    "pending" => %{
      "unit_runnable" => "runnable",
      "unit_failed" => "failed",
      "unit_cancelled" => "cancelled",
      "unit_progress" => "pending"
    },
    "runnable" => %{
      "unit_started" => "running",
      "unit_blocked" => "blocked",
      "unit_failed" => "failed",
      "unit_cancelled" => "cancelled",
      "unit_progress" => "runnable"
    },
    "running" => %{
      "unit_blocked" => "blocked",
      "unit_awaiting_approval" => "awaiting_approval",
      "unit_accepted" => "accepted",
      "unit_failed" => "failed",
      "unit_cancelled" => "cancelled",
      "unit_progress" => "running"
    },
    "blocked" => %{
      "unit_runnable" => "runnable",
      "unit_failed" => "failed",
      "unit_cancelled" => "cancelled",
      "unit_progress" => "blocked"
    },
    "awaiting_approval" => %{
      "unit_accepted" => "accepted",
      "unit_failed" => "failed",
      "unit_cancelled" => "cancelled",
      "unit_progress" => "awaiting_approval"
    },
    "accepted" => %{},
    "failed" => %{},
    "cancelled" => %{}
  }

  @task_events @task_transitions
               |> Map.values()
               |> Enum.flat_map(&Map.keys/1)
               |> MapSet.new()

  @unit_events @unit_transitions
               |> Map.values()
               |> Enum.flat_map(&Map.keys/1)
               |> Kernel.++(["unit_planned"])
               |> MapSet.new()

  @terminal_task_states MapSet.new(["completed", "failed", "cancelled"])

  @event_identifiers %{
    "task_started" => :task_started,
    "planning_started" => :planning_started,
    "execution_started" => :execution_started,
    "task_blocked" => :task_blocked,
    "task_recovery_needed" => :task_recovery_needed,
    "integration_started" => :integration_started,
    "task_validation_started" => :task_validation_started,
    "task_acceptance_passed" => :task_acceptance_passed,
    "change_request_merged" => :change_request_merged,
    "task_failed" => :task_failed,
    "task_cancelled" => :task_cancelled,
    "effect_succeeded" => :effect_succeeded,
    "effect_unknown" => :effect_unknown,
    "unit_planned" => :unit_planned,
    "unit_runnable" => :unit_runnable,
    "unit_started" => :unit_started,
    "unit_blocked" => :unit_blocked,
    "unit_awaiting_approval" => :unit_awaiting_approval,
    "unit_accepted" => :unit_accepted,
    "unit_failed" => :unit_failed,
    "unit_cancelled" => :unit_cancelled,
    "unit_progress" => :unit_progress,
    "task_completed" => :task_completed,
    "unit_created" => :unit_created,
    "unit_completed" => :unit_completed
  }

  @spec transition_task(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def transition_task(status, event_type) do
    cond do
      MapSet.member?(@unit_events, event_type) and
          MapSet.member?(@terminal_task_states, status) ->
        {:error, {:invalid_task_transition, status_identifier(status), event_identifier(event_type)}}

      MapSet.member?(@unit_events, event_type) ->
        {:ok, status}

      not MapSet.member?(@task_events, event_type) ->
        {:error, {:unknown_event_type, event_identifier(event_type)}}

      target = get_in(@task_transitions, [status, event_type]) ->
        {:ok, target}

      true ->
        {:error, {:invalid_task_transition, status_identifier(status), event_identifier(event_type)}}
    end
  end

  @spec transition_unit(map() | nil, String.t() | nil, String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def transition_unit(unit, unit_id, event_type) do
    cond do
      MapSet.member?(@task_events, event_type) ->
        {:ok, unit && unit.status}

      not MapSet.member?(@unit_events, event_type) ->
        {:error, {:unknown_event_type, event_identifier(event_type)}}

      true ->
        transition_known_unit(unit, unit_id, event_type)
    end
  end

  defp transition_known_unit(unit, unit_id, event_type) do
    cond do
      is_nil(unit) and event_type == "unit_planned" ->
        {:ok, "pending"}

      is_nil(unit) ->
        {:error, {:invalid_unit_transition, unit_id, :missing, event_identifier(event_type)}}

      event_type == "unit_planned" ->
        invalid_unit_transition(unit, unit_id, event_type)

      target = get_in(@unit_transitions, [unit.status, event_type]) ->
        {:ok, target}

      true ->
        invalid_unit_transition(unit, unit_id, event_type)
    end
  end

  @spec unit_event?(String.t()) :: boolean()
  def unit_event?(event_type), do: MapSet.member?(@unit_events, event_type)

  defp invalid_unit_transition(unit, unit_id, event_type) do
    {:error, {:invalid_unit_transition, unit_id, status_identifier(unit.status), event_identifier(event_type)}}
  end

  defp status_identifier(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp event_identifier(value) do
    Map.get_lazy(@event_identifiers, value, fn -> status_identifier(value) end)
  end
end
