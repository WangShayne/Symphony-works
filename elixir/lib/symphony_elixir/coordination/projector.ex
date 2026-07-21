defmodule SymphonyElixir.Coordination.Projector do
  @moduledoc false

  alias SymphonyElixir.Coordination.StateMachine

  @spec reduce(map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def reduce(nil, %{event_type: "task_started"} = event) do
    data = event.data

    {:ok,
     %{
       task_id: event.task_id,
       idempotency_key: data["idempotency_key"],
       idempotency_hash: data["idempotency_hash"],
       external_id: data["external_id"],
       stream_version: event.stream_version,
       status: "queued",
       plan_revision: event.plan_revision,
       configuration_revision: event.configuration_revision,
       baseline: data["baseline"],
       correlation_id: event.correlation_id,
       data: data["attributes"] || %{},
       effect: nil,
       effect_status: nil,
       created_at: event.occurred_at,
       updated_at: event.occurred_at
     }}
  end

  def reduce(nil, event) do
    {:error, {:invalid_task_transition, :missing, event_identifier(event.event_type)}}
  end

  def reduce(task, event) when is_map(task) do
    with {:ok, status} <- StateMachine.transition_task(task.status, event.event_type) do
      projected =
        task
        |> Map.put(:stream_version, event.stream_version)
        |> Map.put(:status, status)
        |> Map.put(:updated_at, event.occurred_at)
        |> maybe_put_plan_revision(event)
        |> merge_task_data(event)
        |> project_task_effect(event)

      {:ok, projected}
    end
  end

  @spec reduce_unit(map() | nil, map()) :: {:ok, map() | nil} | {:error, term()}
  def reduce_unit(unit, %{event_type: "task_started"}), do: {:ok, unit}

  def reduce_unit(unit, event) do
    if StateMachine.unit_event?(event.event_type) do
      reduce_unit_event(unit, event)
    else
      with {:ok, _status} <- StateMachine.transition_unit(unit, nil, event.event_type) do
        {:ok, unit}
      end
    end
  end

  @spec replay([map()]) ::
          {:ok, {map(), %{optional(String.t()) => map()}}} | {:error, term()}
  def replay(events) do
    with :ok <- validate_replay_events(events) do
      replay_events(events)
    end
  end

  defp validate_replay_events(events) do
    Enum.reduce_while(events, 1, fn event, expected_version ->
      cond do
        event.event_version != 1 ->
          {:halt, {:error, :unsupported_event_version}}

        event.stream_version != expected_version ->
          {:halt, {:error, {:non_contiguous_stream_version, expected_version, event.stream_version}}}

        true ->
          {:cont, expected_version + 1}
      end
    end)
    |> case do
      next_version when is_integer(next_version) -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_events(events) do
    Enum.reduce_while(events, {:ok, {nil, %{}}}, fn event, {:ok, {task, units}} ->
      unit_id = event.data && event.data["unit_id"]
      current_unit = if is_binary(unit_id), do: Map.get(units, unit_id)

      with {:ok, projected_task} <- reduce(task, event),
           {:ok, projected_unit} <- reduce_unit(current_unit, event) do
        {:cont, {:ok, {projected_task, put_projected_unit(units, projected_unit)}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_projected_unit(units, nil), do: units
  defp put_projected_unit(units, projected), do: Map.put(units, projected.unit_id, projected)

  defp reduce_unit_event(unit, event) do
    data = event.data || %{}

    case data["unit_id"] do
      unit_id when is_binary(unit_id) and byte_size(unit_id) > 0 ->
        with {:ok, status} <- StateMachine.transition_unit(unit, unit_id, event.event_type) do
          projected =
            unit
            |> initialize_unit(event, unit_id)
            |> Map.put(:stream_version, event.stream_version)
            |> Map.put(:status, status)
            |> Map.put(:updated_at, event.occurred_at)
            |> Map.update!(:data, &Map.merge(&1 || %{}, projectable_unit_data(event.event_type, data)))
            |> maybe_put_unit_authority(event.event_type, data)

          {:ok, projected}
        end

      _other ->
        {:error, :invalid_unit_id}
    end
  end

  defp merge_task_data(task, %{event_type: "unit_" <> _rest}), do: task

  defp merge_task_data(task, event) do
    Map.update!(task, :data, &Map.merge(&1 || %{}, event.data || %{}))
  end

  defp project_task_effect(task, %{event_type: "effect_succeeded"} = event) do
    put_effect(task, event, "succeeded")
  end

  defp project_task_effect(task, %{event_type: "effect_unknown"} = event) do
    put_effect(task, event, "unknown")
  end

  defp project_task_effect(task, %{event_type: "task_recovery_needed"} = event) do
    put_effect(task, event, "recovery_needed")
  end

  defp project_task_effect(task, _event), do: task

  defp initialize_unit(nil, event, unit_id) do
    %{
      task_id: event.task_id,
      unit_id: unit_id,
      stream_version: event.stream_version,
      status: "pending",
      task_type: nil,
      execution_profile: nil,
      dependencies: %{"items" => []},
      data: %{},
      created_at: event.occurred_at,
      updated_at: event.occurred_at
    }
  end

  defp initialize_unit(unit, _event, _unit_id), do: unit

  defp maybe_put_dependencies(unit, %{"dependencies" => dependencies})
       when is_list(dependencies) do
    Map.put(unit, :dependencies, %{"items" => dependencies})
  end

  defp maybe_put_dependencies(unit, _data), do: unit

  defp maybe_put_plan_revision(task, %{event_type: "planning_started"} = event) do
    maybe_put(task, :plan_revision, event.plan_revision)
  end

  defp maybe_put_plan_revision(task, _event), do: task

  defp maybe_put_unit_authority(unit, "unit_planned", data) do
    unit
    |> maybe_put(:task_type, data["task_type"])
    |> maybe_put(:execution_profile, data["execution_profile"] || data["execution_profile_id"])
    |> maybe_put_dependencies(data)
  end

  defp maybe_put_unit_authority(unit, _event_type, _data), do: unit

  defp projectable_unit_data("unit_planned", data) do
    Map.drop(data, ["task_type", "execution_profile", "execution_profile_id", "dependencies"])
  end

  defp projectable_unit_data(_event_type, data) do
    Map.take(data, [
      "unit_id",
      "percent",
      "message",
      "summary",
      "worker_id",
      "blocked_reason",
      "approval_request_id",
      "artifact",
      "artifacts",
      "error",
      "metadata",
      "metrics"
    ])
  end

  defp put_effect(task, event, status) do
    operation_id = event.data["operation_id"] || get_in(task, [:effect, "operation_id"])

    task
    |> Map.put(:effect, %{"operation_id" => operation_id, "status" => status})
    |> Map.put(:effect_status, status)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp event_identifier(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
