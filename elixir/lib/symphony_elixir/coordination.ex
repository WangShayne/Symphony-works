defmodule SymphonyElixir.Coordination do
  @moduledoc """
  Durable coordination seam for task state, progress, and orchestrator ownership.

  Callers observe snapshots and optimistic versions. Event storage, projection
  updates, serialization, and delivery remain private to this module.
  """

  alias SymphonyElixir.Audit.Redactor
  alias SymphonyElixir.Coordination.{EventStore, Lease, Projector, TaskProjection}

  @statuses %{
    "queued" => :queued,
    "planning" => :planning,
    "running" => :running,
    "blocked" => :blocked,
    "awaiting_intervention" => :awaiting_intervention,
    "awaiting_approval" => :awaiting_approval,
    "integrating" => :integrating,
    "validating" => :validating,
    "review_ready" => :review_ready,
    "pending" => :pending,
    "runnable" => :runnable,
    "accepted" => :accepted,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled
  }
  @effect_statuses %{
    "succeeded" => :succeeded,
    "unknown" => :unknown,
    "recovery_needed" => :recovery_needed
  }
  @supported_event_version 1
  @derived_event_fields MapSet.new([
                          "id",
                          "task_id",
                          "stream_version",
                          "event_type",
                          "event_version",
                          "actor_kind",
                          "actor_id",
                          "occurred_at",
                          "inserted_at"
                        ])
  @unit_authority_fields MapSet.new([
                           "task_type",
                           "execution_profile",
                           "execution_profile_id",
                           "dependencies",
                           "model_reference",
                           "model_reference_id"
                         ])
  @unit_mutable_fields MapSet.new([
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
  @max_list_limit 101

  @type snapshot :: %{
          required(:id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          required(:external_id) => String.t() | nil,
          required(:version) => pos_integer(),
          required(:status) => atom(),
          required(:plan_revision) => String.t() | nil,
          required(:configuration_revision) => Ecto.UUID.t() | nil,
          required(:baseline) => String.t() | nil,
          required(:correlation_id) => String.t() | nil,
          required(:data) => map(),
          required(:effect) => map() | nil,
          required(:effect_status) => atom() | nil,
          required(:created_at) => DateTime.t() | nil,
          required(:updated_at) => DateTime.t() | nil,
          required(:units) => [map()]
        }

  @type summary :: %{
          required(:id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          required(:external_id) => String.t() | nil,
          required(:version) => pos_integer(),
          required(:status) => atom(),
          required(:plan_revision) => String.t() | nil,
          required(:configuration_revision) => Ecto.UUID.t() | nil,
          required(:baseline) => String.t() | nil,
          required(:correlation_id) => String.t() | nil,
          required(:data) => map(),
          required(:effect) => map() | nil,
          required(:effect_status) => atom() | nil,
          required(:created_at) => DateTime.t() | nil,
          required(:updated_at) => DateTime.t() | nil,
          required(:unit_count) => non_neg_integer()
        }

  @spec start_task(map()) :: {:ok, snapshot()} | {:error, term()}
  def start_task(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_map(attrs),
         {:ok, idempotency_key} <- required_string(attrs, "idempotency_key"),
         {:ok, task_id} <- task_id(attrs),
         :ok <- reject_sensitive(attrs),
         {:ok, _actor} <- event_actor(attrs),
         semantic_hash <- semantic_hash(attrs),
         result <- EventStore.task_by_idempotency_key(idempotency_key) do
      start_or_replay(result, attrs, task_id, idempotency_key, semantic_hash)
    end
  end

  def start_task(_attrs), do: {:error, :invalid_attributes}

  @spec append(Ecto.UUID.t(), non_neg_integer(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append(task_id, expected_version, events)
      when is_binary(task_id) and is_integer(expected_version) and expected_version >= 0 and
             is_list(events) and events != [] do
    with {:ok, task_id} <- canonical_task_id(task_id),
         %TaskProjection{} = projection <- EventStore.task(task_id),
         {:ok, event_attrs} <- normalize_events(events, projection, expected_version),
         {:ok, {new_version, stored, units}} <-
           EventStore.append(task_id, expected_version, event_attrs) do
      broadcast(task_id, public_snapshot(stored, units))
      {:ok, new_version}
    else
      {:error, :invalid_task_id} -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def append(_task_id, _expected_version, _events), do: {:error, :invalid_append}

  @spec snapshot(Ecto.UUID.t()) :: {:ok, snapshot()} | {:error, :not_found}
  def snapshot(task_id) when is_binary(task_id) do
    with {:ok, task_id} <- canonical_task_id(task_id),
         %TaskProjection{} = projection <- EventStore.task(task_id) do
      {:ok, public_snapshot(projection)}
    else
      _invalid_or_missing -> {:error, :not_found}
    end
  end

  def snapshot(_task_id), do: {:error, :not_found}

  @spec list(keyword() | map()) :: [summary()]
  def list(filters) when is_map(filters), do: filters |> Map.to_list() |> list()

  def list(filters) when is_list(filters) do
    case normalize_list_filters(filters) do
      {:ok, filters} ->
        {tasks, unit_counts} = EventStore.list_tasks(filters)

        Enum.map(tasks, fn task ->
          public_summary(task, Map.get(unit_counts, task.task_id, 0))
        end)

      {:error, _invalid_filter} ->
        []
    end
  end

  def list(_filters), do: []

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(task_id) when is_binary(task_id) do
    with {:ok, task_id} <- canonical_task_id(task_id) do
      Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "coordination:task:#{task_id}")
    end
  end

  def subscribe(_task_id), do: {:error, :invalid_task_id}

  @spec acquire_lease(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def acquire_lease(holder_id, opts)
      when is_binary(holder_id) and byte_size(holder_id) > 0 and is_list(opts) do
    case Keyword.get(opts, :ttl_ms) do
      ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 ->
        case Lease.acquire(holder_id, ttl_ms) do
          {:ok, lease} -> {:ok, public_lease(lease)}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_ttl}
    end
  end

  def acquire_lease(_holder_id, _opts), do: {:error, :invalid_lease}

  @spec heartbeat(map()) :: :ok | {:error, :lease_lost}
  def heartbeat(lease), do: Lease.heartbeat(lease)

  @spec release_lease(map()) :: :ok | {:error, :lease_lost}
  def release_lease(lease), do: Lease.release(lease)

  @spec rebuild_projection(Ecto.UUID.t()) :: :ok | {:error, term()}
  def rebuild_projection(task_id) when is_binary(task_id) do
    case canonical_task_id(task_id) do
      {:ok, task_id} ->
        case EventStore.rebuild(task_id) do
          {:ok, projection} ->
            broadcast(task_id, public_snapshot(projection))
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :invalid_task_id} ->
        {:error, :not_found}
    end
  end

  def rebuild_projection(_task_id), do: {:error, :not_found}

  @spec rebuild_all_projections() :: :ok | {:error, term()}
  def rebuild_all_projections do
    EventStore.stream_ids()
    |> Enum.reduce_while(:ok, fn task_id, :ok ->
      case rebuild_projection(task_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  rescue
    exception -> {:error, exception}
  end

  defp normalize_events(events, projection, expected_version) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {event, offset}, {:ok, acc} ->
      with {:ok, event} <- normalize_map(event),
           {:ok, type} <- required_string(event, "type"),
           data when is_map(data) <- Map.get(event, "data", %{}),
           {:ok, data} <- validate_event_fields(type, event, data),
           :ok <- reject_sensitive_event(event),
           {:ok, event_version} <- event_version(event),
           {:ok, actor} <- event_actor(event) do
        attrs = %{
          task_id: projection.task_id,
          stream_version: expected_version + offset,
          event_type: type,
          event_version: event_version,
          actor_kind: actor["kind"],
          actor_id: actor["id"],
          plan_revision: event_plan_revision(type, event, projection),
          configuration_revision: event_configuration_revision(type, event, projection),
          correlation_id: Map.get(event, "correlation_id") || projection.correlation_id,
          data: data,
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }

        {:cont, {:ok, [attrs | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _invalid_data -> {:halt, {:error, :invalid_event_data}}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, Enum.reverse(attrs)}
      error -> error
    end
  end

  defp event_version(event) do
    case Map.get(event, "version", 1) do
      @supported_event_version -> {:ok, @supported_event_version}
      version when is_integer(version) and version > 0 -> {:error, :unsupported_event_version}
      _ -> {:error, :invalid_event_version}
    end
  end

  defp event_plan_revision("planning_started", event, projection) do
    Map.get(event, "plan_revision") || projection.plan_revision
  end

  defp event_plan_revision(_type, _event, projection), do: projection.plan_revision

  defp event_configuration_revision("planning_started", event, projection) do
    Map.get(event, "configuration_revision") ||
      Map.get(event, "config_revision_id") ||
      projection.configuration_revision
  end

  defp event_configuration_revision(_type, _event, projection), do: projection.configuration_revision

  defp validate_event_fields(type, event, data) do
    case reject_derived_event_fields(type, event) do
      :ok -> validate_unit_data_fields(type, data)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_derived_event_fields(type, event) do
    event
    |> Map.keys()
    |> Enum.find(&MapSet.member?(@derived_event_fields, &1))
    |> case do
      nil -> :ok
      field -> {:error, {:forbidden_event_fields, event_identifier(type), [field]}}
    end
  end

  defp validate_unit_data_fields("unit_planned", data) do
    case Map.get(data, "dependencies", []) do
      dependencies when is_list(dependencies) -> {:ok, data}
      _invalid -> {:error, :invalid_event_data}
    end
  end

  defp validate_unit_data_fields("unit_progress", data) do
    {:ok, Map.take(data, MapSet.to_list(@unit_mutable_fields))}
  end

  defp validate_unit_data_fields("unit_" <> _rest = type, data) do
    data
    |> Map.keys()
    |> Enum.find(&(not MapSet.member?(@unit_mutable_fields, &1)))
    |> case do
      nil ->
        {:ok, data}

      field ->
        if MapSet.member?(@unit_authority_fields, field) do
          {:error, {:forbidden_event_fields, event_identifier(type), ["data", field]}}
        else
          {:error, {:unexpected_event_fields, event_identifier(type), ["data", field]}}
        end
    end
  end

  defp validate_unit_data_fields(_type, data), do: {:ok, data}

  defp event_actor(event) do
    case Map.get(event, "actor", %{"kind" => "system", "id" => "coordination"}) do
      %{"kind" => kind, "id" => id} when is_binary(kind) and is_binary(id) ->
        {:ok, %{"kind" => kind, "id" => id}}

      _ ->
        {:error, :invalid_actor}
    end
  end

  defp start_or_replay(nil, attrs, task_id, idempotency_key, semantic_hash) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    correlation_id = Map.get(attrs, "correlation_id") || Ecto.UUID.generate()
    actor = Map.get(attrs, "actor", %{})

    event = %{
      task_id: task_id,
      stream_version: 1,
      event_type: "task_started",
      event_version: 1,
      actor_kind: Map.get(actor, "kind", "system") |> to_string(),
      actor_id: Map.get(actor, "id", "coordination") |> to_string(),
      plan_revision: Map.get(attrs, "plan_revision"),
      configuration_revision: Map.get(attrs, "configuration_revision") || Map.get(attrs, "config_revision_id"),
      correlation_id: correlation_id,
      data: %{
        "idempotency_key" => idempotency_key,
        "idempotency_hash" => semantic_hash,
        "external_id" => Map.get(attrs, "external_id"),
        "baseline" => Map.get(attrs, "baseline"),
        "attributes" => semantic_attributes(attrs)
      },
      occurred_at: now
    }

    with {:ok, projection} <- Projector.reduce(nil, event) do
      case EventStore.insert_task(event, projection) do
        {:ok, stored} ->
          snapshot = public_snapshot(stored)
          broadcast(task_id, snapshot)
          {:ok, snapshot}

        {:error, _reason} ->
          replay_after_insert_race(idempotency_key, semantic_hash)
      end
    end
  end

  defp start_or_replay(%TaskProjection{} = existing, _attrs, _task_id, _key, semantic_hash) do
    replay(existing, semantic_hash)
  end

  defp task_id(%{"id" => value}) do
    canonical_task_id(value)
  end

  defp task_id(_attrs), do: {:ok, Ecto.UUID.generate()}

  defp replay_after_insert_race(idempotency_key, semantic_hash) do
    case EventStore.task_by_idempotency_key(idempotency_key) do
      %TaskProjection{} = existing -> replay(existing, semantic_hash)
      nil -> {:error, :task_start_failed}
    end
  end

  defp replay(%TaskProjection{idempotency_hash: hash} = projection, hash) do
    {:ok, public_snapshot(projection)}
  end

  defp replay(%TaskProjection{task_id: task_id}, _hash) do
    {:error, {:idempotency_conflict, task_id}}
  end

  defp public_snapshot(projection) do
    public_snapshot(projection, EventStore.units(projection.task_id))
  end

  defp public_snapshot(projection, units) do
    projection
    |> public_task()
    |> Map.put(:units, Enum.map(units, &public_unit/1))
  end

  defp public_summary(projection, unit_count) do
    projection
    |> public_task()
    |> Map.put(:unit_count, unit_count)
  end

  defp public_task(projection) do
    %{
      id: projection.task_id,
      idempotency_key: projection.idempotency_key,
      external_id: projection.external_id,
      version: projection.stream_version,
      status: status_atom(projection.status),
      plan_revision: projection.plan_revision,
      configuration_revision: projection.configuration_revision,
      baseline: projection.baseline,
      correlation_id: projection.correlation_id,
      data: projection.data || %{},
      effect: public_effect(projection.effect),
      effect_status: maybe_existing_atom(projection.effect_status),
      created_at: projection.created_at,
      updated_at: projection.updated_at
    }
  end

  defp public_unit(unit) do
    %{
      id: unit.unit_id,
      task_id: unit.task_id,
      version: unit.stream_version,
      status: status_atom(unit.status),
      task_type: unit.task_type,
      execution_profile: unit.execution_profile,
      dependencies: get_in(unit.dependencies || %{}, ["items"]) || [],
      data: unit.data || %{},
      created_at: unit.created_at,
      updated_at: unit.updated_at
    }
  end

  defp public_lease(lease) do
    %{
      name: lease.name,
      holder_id: lease.holder_id,
      token: lease.token,
      ttl_ms: lease.ttl_ms,
      heartbeat_at: lease.heartbeat_at,
      expires_at: lease.expires_at
    }
  end

  defp public_effect(nil), do: nil

  defp public_effect(effect) do
    %{
      operation_id: effect["operation_id"] || effect[:operation_id],
      status: maybe_existing_atom(effect["status"] || effect[:status])
    }
  end

  defp status_atom(value), do: Map.fetch!(@statuses, value)

  defp maybe_existing_atom(nil), do: nil
  defp maybe_existing_atom(value), do: Map.fetch!(@effect_statuses, value)

  defp event_identifier(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:required, key}}
    end
  end

  defp normalize_map(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, child}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key),
           {:ok, child} <- normalize_value(child) do
        {:cont, {:ok, Map.put(acc, key, child)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(_key), do: {:error, :invalid_attribute_key}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)

  defp normalize_value(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn child, {:ok, acc} ->
      case normalize_value(child) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_value(_value), do: {:error, :invalid_attribute_value}

  defp reject_sensitive(value) do
    redacted = Redactor.redact(value)

    case first_difference(value, redacted, []) do
      nil -> :ok
      path -> {:error, {:sensitive_data, path}}
    end
  end

  defp reject_sensitive_event(event) do
    case reject_sensitive(event) do
      {:error, {:sensitive_data, ["data" | path]}} ->
        {:error, {:sensitive_data, path}}

      result ->
        result
    end
  end

  defp first_difference(original, redacted, path)
       when is_map(original) and is_map(redacted) do
    Enum.find_value(original, fn {key, child} ->
      case Map.fetch(redacted, key) do
        {:ok, redacted_child} -> first_difference(child, redacted_child, [key | path])
        :error -> Enum.reverse([key | path])
      end
    end)
  end

  defp first_difference(original, redacted, path)
       when is_list(original) and is_list(redacted) do
    original
    |> Enum.zip(redacted)
    |> Enum.with_index()
    |> Enum.find_value(fn {{child, redacted_child}, index} ->
      first_difference(child, redacted_child, [index | path])
    end)
  end

  defp first_difference(value, value, _path), do: nil
  defp first_difference(_original, _redacted, path), do: Enum.reverse(path)

  defp canonical_task_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid_or_noncanonical -> {:error, :invalid_task_id}
    end
  end

  defp canonical_task_id(_value), do: {:error, :invalid_task_id}

  defp normalize_list_filters(filters) do
    cursor = filter_value(filters, :after, "after")
    status = filter_value(filters, :status, "status")
    idempotency_key = filter_value(filters, :idempotency_key, "idempotency_key")

    with {:ok, cursor} <- normalize_cursor(cursor),
         {:ok, status} <- normalize_status_filter(status),
         {:ok, idempotency_key} <- normalize_idempotency_filter(idempotency_key) do
      normalized =
        []
        |> maybe_put_filter(:status, status)
        |> maybe_put_filter(:idempotency_key, idempotency_key)
        |> Keyword.put(:limit, bounded_limit(filter_value(filters, :limit, "limit")))
        |> maybe_put_cursor(cursor)

      {:ok, normalized}
    end
  end

  defp normalize_cursor(nil), do: {:ok, nil}

  defp normalize_cursor(value) do
    case canonical_task_id(value) do
      {:ok, task_id} -> {:ok, task_id}
      {:error, :invalid_task_id} -> {:error, :invalid_cursor}
    end
  end

  defp normalize_status_filter(nil), do: {:ok, nil}

  defp normalize_status_filter(value) when is_atom(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_status_filter(value) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_status_filter(_value), do: {:error, :invalid_filter}

  defp normalize_idempotency_filter(nil), do: {:ok, nil}

  defp normalize_idempotency_filter(value) when is_binary(value) and value != "",
    do: {:ok, value}

  defp normalize_idempotency_filter(_value), do: {:error, :invalid_filter}

  defp bounded_limit(nil), do: @max_list_limit
  defp bounded_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_list_limit)
  defp bounded_limit(_value), do: @max_list_limit

  defp filter_value(filters, atom_key, string_key) do
    Enum.find_value(filters, fn
      {^atom_key, value} -> {:found, value}
      {^string_key, value} -> {:found, value}
      _filter -> nil
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp maybe_put_cursor(filters, nil), do: filters
  defp maybe_put_cursor(filters, cursor), do: Keyword.put(filters, :after, cursor)

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp semantic_hash(attrs) do
    attrs
    |> semantic_attributes()
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp semantic_attributes(attrs) do
    Map.drop(attrs, ["id", "idempotency_key", "actor", "correlation_id"])
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, child} -> {key, canonical_term(child)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp broadcast(task_id, snapshot) do
    Phoenix.PubSub.broadcast(
      SymphonyElixir.PubSub,
      "coordination:task:#{task_id}",
      {:coordination_updated, snapshot}
    )
  end
end
