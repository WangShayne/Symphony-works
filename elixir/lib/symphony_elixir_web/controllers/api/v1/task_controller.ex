defmodule SymphonyElixirWeb.Api.V1.TaskController do
  @moduledoc """
  Authenticated task creation and durable task projection queries.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.{Coordination, TaskCreation}

  @default_limit 50
  @max_limit 100
  @default_unit_limit 50
  @max_unit_limit 100
  @max_unit_cursor_bytes 200

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"task" => task} = params) when is_map(task) do
    with {:ok, unit_page} <- unit_page(params),
         :ok <- validate_create_unit_cursor(unit_page.cursor, task),
         {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, snapshot, kind} <-
           TaskCreation.create(task, conn.assigns.current_principal, idempotency_key),
         {:ok, data, units_meta} <- serialize_with_unit_page(snapshot, unit_page) do
      conn
      |> put_status(if(kind == :created, do: :created, else: :ok))
      |> json(%{data: data, meta: %{units: units_meta}})
    else
      {:error, reason} -> task_error(conn, reason)
    end
  end

  def create(conn, _params), do: task_error(conn, {:invalid_task, "task"})

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    case task_page(params) do
      {:ok, page} ->
        filters = [limit: page.limit + 1] ++ if(page.cursor, do: [after: page.cursor], else: [])
        {tasks, next_cursor} = take_page(Coordination.list(filters), page.limit, & &1.id)

        json(conn, %{
          data: Enum.map(tasks, &serialize_summary/1),
          meta: %{tasks: %{limit: page.limit, next_cursor: next_cursor}}
        })

      {:error, reason} ->
        task_error(conn, reason)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id} = params) do
    with {:ok, unit_page} <- unit_page(params),
         {:ok, snapshot} <- Coordination.snapshot(id),
         {:ok, data, units_meta} <- serialize_with_unit_page(snapshot, unit_page) do
      json(conn, %{data: data, meta: %{units: units_meta}})
    else
      {:error, reason} -> task_error(conn, reason)
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when is_binary(key) and key != "" -> {:ok, key}
      _headers -> {:error, :idempotency_key_required}
    end
  end

  defp serialize(snapshot, units) do
    %{
      id: snapshot.id,
      external_id: snapshot.external_id,
      version: snapshot.version,
      status: atom_string(snapshot.status),
      plan_revision: snapshot.plan_revision,
      configuration_revision_id: snapshot.configuration_revision,
      baseline_commit: snapshot.baseline,
      correlation_id: snapshot.correlation_id,
      effect: serialize_effect(snapshot.effect),
      units: Enum.map(units, &serialize_unit/1),
      created_at: snapshot.created_at,
      updated_at: snapshot.updated_at
    }
  end

  defp serialize_summary(snapshot) do
    snapshot
    |> serialize([])
    |> Map.delete(:units)
    |> Map.put(:unit_count, Map.get(snapshot, :unit_count, length(Map.get(snapshot, :units, []))))
  end

  defp serialize_with_unit_page(snapshot, page) do
    with {:ok, remaining} <- after_unit_cursor(Map.get(snapshot, :units, []), page.cursor) do
      {units, next_cursor} = take_page(remaining, page.limit, & &1.id)
      {:ok, serialize(snapshot, units), %{limit: page.limit, next_cursor: next_cursor}}
    end
  end

  defp serialize_effect(nil), do: nil

  defp serialize_effect(effect) do
    %{
      operation_id: effect.operation_id,
      status: atom_string(effect.status)
    }
  end

  defp serialize_unit(unit) do
    %{
      id: unit.id,
      status: atom_string(unit.status),
      task_type: unit.task_type,
      execution_profile_id: unit.execution_profile,
      model_reference_id: unit.model_reference_id,
      dependencies: unit.dependencies
    }
  end

  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)

  defp task_page(params) do
    with {:ok, limit} <- parse_limit(params, "limit", @default_limit, @max_limit),
         {:ok, cursor} <- task_cursor(Map.get(params, "cursor")) do
      {:ok, %{limit: limit, cursor: cursor}}
    end
  end

  defp unit_page(params) do
    with {:ok, limit} <-
           parse_limit(params, "unit_limit", @default_unit_limit, @max_unit_limit),
         {:ok, cursor} <- unit_cursor(Map.get(params, "unit_cursor")) do
      {:ok, %{limit: limit, cursor: cursor}}
    end
  end

  defp parse_limit(params, key, default, maximum) do
    params
    |> Map.get(key)
    |> normalize_limit(default, maximum)
  end

  defp normalize_limit(nil, default, _maximum), do: {:ok, default}

  defp normalize_limit(value, _default, maximum)
       when is_integer(value) and value > 0 and value <= maximum,
       do: {:ok, value}

  defp normalize_limit(value, _default, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 and parsed <= maximum -> {:ok, parsed}
      _invalid -> {:error, :invalid_pagination}
    end
  end

  defp normalize_limit(_value, _default, _maximum), do: {:error, :invalid_pagination}

  defp task_cursor(nil), do: {:ok, nil}

  defp task_cursor(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> {:error, :invalid_pagination}
    end
  end

  defp task_cursor(_value), do: {:error, :invalid_pagination}

  defp unit_cursor(nil), do: {:ok, nil}

  defp unit_cursor(value)
       when is_binary(value) and value != "" and byte_size(value) <= @max_unit_cursor_bytes,
       do: {:ok, value}

  defp unit_cursor(_value), do: {:error, :invalid_pagination}

  defp validate_create_unit_cursor(nil, _task), do: :ok

  defp validate_create_unit_cursor(cursor, task) do
    if Enum.any?(Map.get(task, "units", []), &(is_map(&1) and Map.get(&1, "id") == cursor)),
      do: :ok,
      else: {:error, :invalid_pagination}
  end

  defp after_unit_cursor(units, nil), do: {:ok, units}

  defp after_unit_cursor(units, cursor) do
    case Enum.split_while(units, &(&1.id != cursor)) do
      {_before, [_cursor | remaining]} -> {:ok, remaining}
      {_all, []} -> {:error, :invalid_pagination}
    end
  end

  defp take_page(items, limit, cursor) do
    {page, overflow} = Enum.split(items, limit)
    next_cursor = if overflow == [], do: nil, else: page |> List.last() |> cursor.()
    {page, next_cursor}
  end

  defp task_error(conn, :idempotency_key_required) do
    error(conn, :unprocessable_entity, "idempotency_key_required", "Idempotency-Key header is required")
  end

  defp task_error(conn, {:idempotency_conflict, existing_id}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "idempotency_conflict",
        message: "Idempotency-Key was already used for another task intent",
        details: %{existing_task_id: existing_id}
      }
    })
  end

  defp task_error(conn, {:configuration_pin_conflict, _revision_id}) do
    error(conn, :conflict, "configuration_pin_conflict", "Task configuration pin conflicts with durable task state")
  end

  defp task_error(conn, :active_configuration_required) do
    error(conn, :conflict, "active_configuration_required", "An active configuration revision is required")
  end

  defp task_error(conn, :audit_unavailable) do
    error(conn, :service_unavailable, "audit_unavailable", "Task audit could not be durably recorded")
  end

  defp task_error(conn, :effect_interrupted) do
    error(
      conn,
      :service_unavailable,
      "effect_interrupted",
      "External effect outcome is unknown; repeat this request with the same Idempotency-Key"
    )
  end

  defp task_error(conn, {:effect_failed, reason}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{
        code: "effect_failed",
        message: "External effect failed",
        details: %{reason: Atom.to_string(reason)}
      }
    })
  end

  defp task_error(conn, :not_found) do
    error(conn, :not_found, "not_found", "Task not found")
  end

  defp task_error(conn, {:invalid_task, field}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_task",
        message: "Task validation failed",
        details: %{field: field}
      }
    })
  end

  defp task_error(conn, :invalid_idempotency_key) do
    error(conn, :unprocessable_entity, "invalid_idempotency_key", "Idempotency-Key is invalid")
  end

  defp task_error(conn, :invalid_pagination) do
    error(conn, :unprocessable_entity, "invalid_pagination", "Pagination parameters are invalid")
  end

  defp task_error(conn, _reason) do
    error(conn, :service_unavailable, "task_creation_failed", "Task creation requires recovery")
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
