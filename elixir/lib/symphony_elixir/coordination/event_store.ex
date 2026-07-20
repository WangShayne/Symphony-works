defmodule SymphonyElixir.Coordination.EventStore do
  @moduledoc false

  import Ecto.Query

  alias SymphonyElixir.Coordination.{Event, Projector, TaskProjection, UnitProjection}
  alias SymphonyElixir.Repo

  @spec task_by_idempotency_key(String.t()) :: TaskProjection.t() | nil
  def task_by_idempotency_key(key) do
    Repo.get_by(TaskProjection, idempotency_key: key)
  end

  @spec task(Ecto.UUID.t()) :: TaskProjection.t() | nil
  def task(task_id), do: Repo.get(TaskProjection, task_id)

  @spec units(Ecto.UUID.t()) :: [UnitProjection.t()]
  def units(task_id) do
    from(unit in UnitProjection,
      where: unit.task_id == ^task_id,
      order_by: [asc: unit.created_at, asc: unit.unit_id]
    )
    |> Repo.all()
  end

  @spec events(Ecto.UUID.t()) :: [Event.t()]
  def events(task_id) do
    from(event in Event,
      where: event.task_id == ^task_id,
      order_by: [asc: event.stream_version]
    )
    |> Repo.all()
  end

  @spec stream_ids() :: [Ecto.UUID.t()]
  def stream_ids do
    from(event in Event,
      distinct: true,
      select: event.task_id,
      order_by: [asc: event.task_id]
    )
    |> Repo.all()
  end

  @spec list_tasks(keyword()) :: {[TaskProjection.t()], %{optional(Ecto.UUID.t()) => non_neg_integer()}}
  def list_tasks(filters) do
    query =
      filters
      |> Enum.reduce(from(task in TaskProjection), fn
        {:idempotency_key, value}, query ->
          from(task in query, where: task.idempotency_key == ^value)

        {:status, value}, query ->
          from(task in query, where: task.status == ^to_string(value))

        _, query ->
          query
      end)
      |> after_cursor(Keyword.get(filters, :after))
      |> order_by([task], asc: task.created_at, asc: task.task_id)
      |> limit(^Keyword.fetch!(filters, :limit))

    tasks = Repo.all(query)
    {tasks, unit_counts(tasks)}
  end

  @spec insert_task(map(), map()) :: {:ok, TaskProjection.t()} | {:error, term()}
  def insert_task(event_attrs, projection_attrs) do
    Repo.transaction(
      fn ->
        with {:ok, _event} <- Repo.insert(Event.changeset(%Event{}, event_attrs)),
             {:ok, projection} <-
               Repo.insert(TaskProjection.changeset(%TaskProjection{}, projection_attrs)) do
          projection
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
  end

  @spec append(Ecto.UUID.t(), non_neg_integer(), [map()]) ::
          {:ok, {non_neg_integer(), TaskProjection.t()}} | {:error, term()}
  def append(task_id, expected_version, events) do
    Repo.transaction(
      fn ->
        projection = Repo.get!(TaskProjection, task_id)

        if projection.stream_version != expected_version do
          Repo.rollback(:stale_stream)
        else
          unit_states =
            projection.task_id
            |> units()
            |> Map.new(&{&1.unit_id, UnitProjection.attributes(&1)})

          append_events(projection, unit_states, expected_version, events)
        end
      end,
      mode: :immediate
    )
  end

  @spec rebuild(Ecto.UUID.t()) :: {:ok, TaskProjection.t()} | {:error, term()}
  def rebuild(task_id) do
    Repo.transaction(
      fn ->
        case events(task_id) do
          [] -> Repo.rollback(:not_found)
          events -> rebuild_from_events(task_id, events)
        end
      end,
      mode: :immediate
    )
  end

  defp rebuild_from_events(task_id, events) do
    case Projector.replay(events) do
      {:ok, {task_state, unit_states}} ->
        Repo.delete_all(from(unit in UnitProjection, where: unit.task_id == ^task_id))
        Repo.delete_all(from(task in TaskProjection, where: task.task_id == ^task_id))

        projection =
          %TaskProjection{}
          |> TaskProjection.changeset(task_state)
          |> Repo.insert!()

        persist_units(unit_states)
        projection

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp append_events(projection, unit_states, expected_version, events) do
    case project_events(TaskProjection.attributes(projection), unit_states, events) do
      {:ok, {task_state, units}} ->
        Enum.each(events, fn event_attrs ->
          %Event{}
          |> Event.changeset(event_attrs)
          |> Repo.insert!()
        end)

        stored = update_projection(projection, expected_version, task_state)
        persist_units(units)
        {stored.stream_version, stored}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp project_events(task_state, unit_states, events) do
    Enum.reduce_while(events, {:ok, {task_state, unit_states}}, fn event, {:ok, {task, units}} ->
      unit_id = event.data && event.data["unit_id"]
      current_unit = if is_binary(unit_id), do: Map.get(units, unit_id)

      with {:ok, projected_task} <- Projector.reduce(task, event),
           {:ok, projected_unit} <- Projector.reduce_unit(current_unit, event) do
        {:cont, {:ok, {projected_task, put_projected_unit(units, projected_unit)}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_projected_unit(units, nil), do: units
  defp put_projected_unit(units, unit), do: Map.put(units, unit.unit_id, unit)

  defp update_projection(projection, expected_version, state) do
    updates =
      state
      |> Map.drop([:task_id])
      |> Map.to_list()

    query =
      from(task in TaskProjection,
        where: task.task_id == ^projection.task_id and task.stream_version == ^expected_version
      )

    {1, _} = Repo.update_all(query, set: updates)
    struct!(projection, state)
  end

  defp persist_units(units) do
    Enum.each(units, fn {_unit_id, attrs} ->
      case Repo.get_by(UnitProjection, task_id: attrs.task_id, unit_id: attrs.unit_id) do
        nil ->
          %UnitProjection{}
          |> UnitProjection.changeset(attrs)
          |> Repo.insert!()

        unit ->
          unit
          |> UnitProjection.changeset(attrs)
          |> Repo.update!()
      end
    end)
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, task_id) do
    cursor_query =
      from(cursor in TaskProjection,
        where: cursor.task_id == ^task_id,
        select: %{created_at: cursor.created_at, task_id: cursor.task_id}
      )

    from(task in query,
      join: cursor in subquery(cursor_query),
      on:
        task.created_at > cursor.created_at or
          (task.created_at == cursor.created_at and task.task_id > cursor.task_id)
    )
  end

  defp unit_counts([]), do: %{}

  defp unit_counts(tasks) do
    task_ids = Enum.map(tasks, & &1.task_id)

    from(unit in UnitProjection,
      where: unit.task_id in ^task_ids,
      group_by: unit.task_id,
      select: {unit.task_id, count(unit.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
