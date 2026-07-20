defmodule SymphonyElixir.TaskCreation do
  @moduledoc """
  Resumable authenticated task-creation tracer across configuration, coordination,
  audit, and external-effect boundaries.
  """

  alias SymphonyElixir.{Audit, Config, Configuration, Coordination, Effects}
  alias SymphonyElixir.Identity.Principal

  @max_summary_bytes 500
  @max_serialized_bytes 65_536
  @max_units 100
  @max_reference_bytes 200
  @max_dependencies 100

  @type result_kind :: :created | :resumed

  @spec create(map(), Principal.t() | map(), String.t()) ::
          {:ok, map(), result_kind()} | {:error, term()}
  def create(params, actor, idempotency_key), do: create(params, actor, idempotency_key, [])

  @spec create(map(), Principal.t() | map(), String.t(), keyword()) ::
          {:ok, map(), result_kind()} | {:error, term()}
  def create(params, actor, idempotency_key, opts) do
    case actor do
      %{id: actor_id} when is_map(params) and is_binary(actor_id) and is_list(opts) ->
        do_create(params, actor, actor_id, idempotency_key, opts)

      _other ->
        {:error, :invalid_task}
    end
  end

  defp do_create(params, actor, actor_id, idempotency_key, opts) do
    with {:ok, key} <- normalize_idempotency_key(idempotency_key),
         {:ok, intent} <- normalize_intent(params),
         {existing, configuration_revision} <- captured_configuration(key),
         {:ok, task} <- start_task(intent, actor, key, configuration_revision),
         {:ok, task} <- ensure_units(task, intent.units, actor),
         {:ok, _pin} <-
           Configuration.pin_for_task(task.id,
             actor: actor_id,
             revision_id: task.configuration_revision
           ),
         {:ok, task} <- ensure_audit(task, actor),
         {:ok, task} <- ensure_effect(task, actor, opts) do
      {:ok, task, if(existing, do: :resumed, else: :created)}
    end
  end

  defp captured_configuration(key) do
    case Coordination.list(idempotency_key: key) do
      [task | _rest] -> {true, task.configuration_revision}
      [] -> {false, active_configuration_revision()}
    end
  end

  defp active_configuration_revision do
    case Configuration.active() do
      {:ok, revision} -> revision.id
      {:error, :not_found} -> nil
    end
  end

  defp start_task(_intent, _actor, _key, nil), do: {:error, :active_configuration_required}

  defp start_task(intent, actor, key, configuration_revision) do
    Coordination.start_task(%{
      idempotency_key: key,
      external_id: intent.external_id,
      configuration_revision: configuration_revision,
      plan_revision: intent.plan_revision,
      baseline: intent.baseline,
      correlation_id: key,
      actor: actor_reference(actor),
      data: %{
        "summary" => intent.summary,
        "units" => Enum.map(intent.units, &unit_intent_data/1)
      }
    })
  end

  defp ensure_units(task, intended_units, actor, attempts \\ 3)

  defp ensure_units(task, intended_units, actor, attempts) when attempts > 0 do
    existing_ids = MapSet.new(task.units, & &1.id)
    missing = Enum.reject(intended_units, &MapSet.member?(existing_ids, &1.id))

    if missing == [] do
      {:ok, task}
    else
      events = Enum.map(missing, &unit_event(&1, task, actor))

      case Coordination.append(task.id, task.version, events) do
        {:ok, _version} ->
          Coordination.snapshot(task.id)

        {:error, :stale_stream} ->
          retry_ensure_units(task.id, intended_units, actor, attempts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_units(_task, _intended_units, _actor, 0), do: {:error, :coordination_conflict}

  defp retry_ensure_units(task_id, intended_units, actor, attempts) do
    with {:ok, latest} <- Coordination.snapshot(task_id) do
      ensure_units(latest, intended_units, actor, attempts - 1)
    end
  end

  defp ensure_audit(task, actor) do
    if Enum.any?(Audit.list(task_id: task.id), &task_created_audit?(&1, task.correlation_id)) do
      {:ok, task}
    else
      attrs = %{
        dedupe_key: "task_created:#{task.id}",
        task_id: task.id,
        target: %{type: "task", id: task.id},
        configuration_revision: task.configuration_revision,
        plan_revision: task.plan_revision,
        correlation_id: task.correlation_id,
        outcome: :succeeded,
        summary: %{
          event: "task_created",
          external_id: task.external_id,
          unit_count: length(task.units)
        }
      }

      case Audit.record(:task_created, attrs, actor) do
        {:ok, _event} -> {:ok, task}
        {:error, _reason} -> recovery_error(task, actor, :audit_unavailable)
      end
    end
  end

  defp ensure_effect(task, actor, opts) do
    adapter =
      Keyword.get_lazy(opts, :effect_adapter, fn ->
        Config.task_creation_effect_adapter()
      end)

    effect = %{
      task_id: task.id,
      plan_revision: task.plan_revision,
      unit_id: "task-intake",
      action: :register_task,
      provider: :simulated,
      target: task.id,
      intent: %{
        "task_id" => task.id,
        "external_id" => task.external_id,
        "correlation_id" => task.correlation_id
      }
    }

    case Effects.execute(effect, adapter) do
      {:ok, record} ->
        append_effect_outcome(task, actor, :effect_succeeded, record.operation_id)

      {:error, :interrupted} ->
        append_unknown_effect(task, actor)

      {:error, reason} ->
        recovery_error(task, actor, {:effect_failed, reason})
    end
  end

  defp append_effect_outcome(task, actor, type, operation_id, attempts \\ 3)

  defp append_effect_outcome(task, _actor, :effect_succeeded, operation_id, _attempts)
       when not is_nil(operation_id) and
              task.effect_status == :succeeded and
              is_map(task.effect) and task.effect.operation_id == operation_id do
    {:ok, task}
  end

  defp append_effect_outcome(task, actor, type, operation_id, attempts) when attempts > 0 do
    event = %{
      type: type,
      actor: actor_reference(actor),
      plan_revision: task.plan_revision,
      configuration_revision: task.configuration_revision,
      correlation_id: task.correlation_id,
      data: %{operation_id: operation_id, status: effect_status(type)}
    }

    case Coordination.append(task.id, task.version, [event]) do
      {:ok, _version} ->
        Coordination.snapshot(task.id)

      {:error, :stale_stream} ->
        retry_append_effect_outcome(task.id, actor, type, operation_id, attempts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_effect_outcome(_task, _actor, _type, _operation_id, 0),
    do: {:error, :coordination_conflict}

  defp append_unknown_effect(task, actor) do
    case append_effect_outcome(task, actor, :effect_unknown, nil) do
      {:ok, _snapshot} -> {:error, :effect_interrupted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_append_effect_outcome(task_id, actor, type, operation_id, attempts) do
    with {:ok, latest} <- Coordination.snapshot(task_id) do
      append_effect_outcome(latest, actor, type, operation_id, attempts - 1)
    end
  end

  defp recovery_error(task, actor, reason) do
    case append_effect_outcome(task, actor, :task_recovery_needed, current_operation_id(task)) do
      {:ok, _snapshot} -> {:error, reason}
      {:error, append_reason} -> {:error, {:recovery_record_failed, append_reason}}
    end
  end

  defp current_operation_id(%{effect: %{operation_id: operation_id}}), do: operation_id
  defp current_operation_id(_task), do: nil

  defp task_created_audit?(event, correlation_id) do
    event.action in [:task_created, "task_created"] and event.correlation_id == correlation_id
  end

  defp unit_event(unit, task, actor) do
    %{
      type: :unit_planned,
      actor: actor_reference(actor),
      plan_revision: task.plan_revision,
      configuration_revision: task.configuration_revision,
      correlation_id: task.correlation_id,
      data: %{
        unit_id: unit.id,
        task_type: unit.task_type,
        execution_profile: unit.execution_profile,
        dependencies: unit.dependencies,
        model_reference_id: unit.model_reference_id
      }
    }
  end

  defp actor_reference(%{id: id}), do: %{kind: :principal, id: id}

  defp normalize_idempotency_key(key) when is_binary(key) do
    normalized = String.trim(key)

    if normalized != "" and byte_size(normalized) <= 200 do
      {:ok, normalized}
    else
      {:error, :invalid_idempotency_key}
    end
  end

  defp normalize_idempotency_key(_key), do: {:error, :invalid_idempotency_key}

  defp normalize_intent(params) do
    with :ok <- validate_serialized_size(params),
         {:ok, external_id} <- required_string(params, "external_id", 200),
         {:ok, summary} <- required_string(params, "summary", @max_summary_bytes),
         {:ok, baseline} <- baseline(params),
         {:ok, plan_revision} <- plan_revision(params),
         {:ok, units} <- units(params) do
      {:ok,
       %{
         external_id: external_id,
         summary: summary,
         baseline: baseline,
         plan_revision: plan_revision,
         units: units
       }}
    end
  end

  defp baseline(params) do
    with {:ok, value} <- required_string(params, "baseline_commit", 64),
         true <- Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, value) do
      {:ok, value}
    else
      _error -> {:error, {:invalid_task, "baseline_commit"}}
    end
  end

  defp plan_revision(params) do
    case value(params, "plan_revision") do
      revision when is_integer(revision) and revision > 0 ->
        {:ok, Integer.to_string(revision)}

      revision when is_binary(revision) ->
        case Integer.parse(revision) do
          {parsed, ""} when parsed > 0 -> {:ok, Integer.to_string(parsed)}
          _error -> {:error, {:invalid_task, "plan_revision"}}
        end

      _other ->
        {:error, {:invalid_task, "plan_revision"}}
    end
  end

  defp units(params) do
    case value(params, "units") do
      units when is_list(units) and units != [] and length(units) <= @max_units ->
        with {:ok, normalized} <- normalize_units(units),
             true <- unique_unit_ids?(normalized) do
          {:ok, normalized}
        else
          _error -> {:error, {:invalid_task, "units"}}
        end

      _other ->
        {:error, {:invalid_task, "units"}}
    end
  end

  defp normalize_units(units) do
    Enum.reduce_while(units, {:ok, []}, fn unit, {:ok, acc} ->
      case normalize_unit(unit) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_unit(unit) when is_map(unit) do
    with {:ok, id} <- required_string(unit, "id", 200),
         {:ok, task_type} <- required_string(unit, "task_type", 100),
         {:ok, execution_profile} <-
           optional_string(
             unit,
             "execution_profile_id",
             "profile-#{task_type}",
             @max_reference_bytes
           ),
         {:ok, model_reference_id} <-
           optional_string(unit, "model_reference_id", nil, @max_reference_bytes),
         {:ok, dependencies} <- optional_string_list(unit, "dependencies") do
      {:ok,
       %{
         id: id,
         task_type: task_type,
         execution_profile: execution_profile,
         model_reference_id: model_reference_id,
         dependencies: dependencies
       }}
    end
  end

  defp normalize_unit(_unit), do: {:error, :invalid_unit}

  defp unique_unit_ids?(units) do
    ids = Enum.map(units, & &1.id)
    length(ids) == MapSet.size(MapSet.new(ids))
  end

  defp required_string(map, key, max_bytes) do
    case value(map, key) do
      value when is_binary(value) ->
        normalized = String.trim(value)

        if normalized != "" and byte_size(normalized) <= max_bytes do
          {:ok, normalized}
        else
          {:error, {:invalid_task, key}}
        end

      _other ->
        {:error, {:invalid_task, key}}
    end
  end

  defp validate_serialized_size(params) do
    case Jason.encode(params) do
      {:ok, encoded} when byte_size(encoded) <= @max_serialized_bytes -> :ok
      _invalid_or_too_large -> {:error, {:invalid_task, "task"}}
    end
  end

  defp optional_string(map, key, default, max_bytes) do
    case value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          normalized when byte_size(normalized) <= max_bytes -> {:ok, normalized}
          _too_large -> {:error, {:invalid_task, key}}
        end

      nil ->
        {:ok, default}

      _invalid ->
        {:error, {:invalid_task, key}}
    end
  end

  defp optional_string_list(map, key) do
    case value(map, key) do
      values when is_list(values) and length(values) <= @max_dependencies ->
        normalize_optional_strings(values, key)

      nil ->
        {:ok, []}

      _invalid ->
        {:error, {:invalid_task, key}}
    end
  end

  defp normalize_optional_strings(values, key) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        case String.trim(value) do
          "" ->
            {:cont, {:ok, acc}}

          normalized when byte_size(normalized) <= @max_reference_bytes ->
            {:cont, {:ok, [normalized | acc]}}

          _too_large ->
            {:halt, {:error, {:invalid_task, key}}}
        end

      _invalid, {:ok, _acc} ->
        {:halt, {:error, {:invalid_task, key}}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp value(map, "external_id"), do: Map.get(map, "external_id", Map.get(map, :external_id))
  defp value(map, "summary"), do: Map.get(map, "summary", Map.get(map, :summary))

  defp value(map, "baseline_commit"),
    do: Map.get(map, "baseline_commit", Map.get(map, :baseline_commit))

  defp value(map, "plan_revision"),
    do: Map.get(map, "plan_revision", Map.get(map, :plan_revision))

  defp value(map, "units"), do: Map.get(map, "units", Map.get(map, :units))
  defp value(map, "id"), do: Map.get(map, "id", Map.get(map, :id))
  defp value(map, "task_type"), do: Map.get(map, "task_type", Map.get(map, :task_type))

  defp value(map, "execution_profile_id"),
    do: Map.get(map, "execution_profile_id", Map.get(map, :execution_profile_id))

  defp value(map, "model_reference_id"),
    do: Map.get(map, "model_reference_id", Map.get(map, :model_reference_id))

  defp value(map, "dependencies"),
    do: Map.get(map, "dependencies", Map.get(map, :dependencies))

  defp unit_intent_data(unit) do
    %{
      "id" => unit.id,
      "task_type" => unit.task_type,
      "execution_profile" => unit.execution_profile,
      "model_reference_id" => unit.model_reference_id,
      "dependencies" => unit.dependencies
    }
  end

  defp effect_status(:effect_succeeded), do: :succeeded
  defp effect_status(:effect_unknown), do: :unknown
  defp effect_status(:task_recovery_needed), do: :recovery_needed
end
