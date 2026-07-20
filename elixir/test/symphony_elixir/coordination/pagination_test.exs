defmodule SymphonyElixir.Coordination.PaginationTest do
  use SymphonyElixir.DataCase, async: false

  import Ecto.Query

  alias SymphonyElixir.{Coordination, Repo}
  alias SymphonyElixir.Coordination.TaskProjection

  test "lists bounded keyset pages as two-query summaries with batched unit counts" do
    starting_task = latest_task()
    starting_cursor = starting_task && starting_task.id

    ordering_base =
      [DateTime.utc_now(), starting_task && starting_task.created_at]
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(&DateTime.to_unix(&1, :microsecond))

    run_id = Ecto.UUID.generate()

    tasks =
      for index <- 1..4 do
        {:ok, task} = start_task(run_id, index)

        if index <= 3 do
          events =
            for unit_index <- 1..index do
              %{
                type: :unit_planned,
                data: %{
                  unit_id: "unit-#{index}-#{unit_index}",
                  task_type: "backend",
                  execution_profile: "backend-default",
                  dependencies: []
                }
              }
            end

          assert {:ok, _version} = Coordination.append(task.id, task.version, events)
        end

        {:ok, task} = Coordination.snapshot(task.id)

        assert {:ok, _version} =
                 Coordination.append(task.id, task.version, [
                   %{type: :planning_started, data: %{}},
                   %{type: :execution_started, data: %{}},
                   %{type: :integration_started, data: %{}},
                   %{type: :task_validation_started, data: %{}}
                 ])

        created_at = DateTime.add(ordering_base, index, :second)

        Repo.update_all(
          from(projection in TaskProjection, where: projection.task_id == ^task.id),
          set: [created_at: created_at]
        )

        {:ok, snapshot} = Coordination.snapshot(task.id)
        snapshot
      end

    ordered_tasks = Enum.sort_by(tasks, &{&1.created_at, &1.id})

    first_filters = maybe_after([status: :validating, limit: 2], starting_cursor)
    assert {first_page, first_queries} = capture_list_queries(first_filters)
    assert Enum.map(first_page, & &1.id) == ordered_tasks |> Enum.take(2) |> Enum.map(& &1.id)

    assert Enum.map(first_page, & &1.unit_count) ==
             ordered_tasks |> Enum.take(2) |> Enum.map(&length(&1.units))

    assert Enum.all?(first_page, &(not Map.has_key?(&1, :units)))
    assert two_projection_queries?(first_queries)

    cursor = List.last(first_page).id

    assert {second_page, second_queries} =
             capture_list_queries(status: :validating, limit: 2, after: cursor)

    assert Enum.map(second_page, & &1.id) == ordered_tasks |> Enum.drop(2) |> Enum.map(& &1.id)

    assert Enum.map(second_page, & &1.unit_count) ==
             ordered_tasks |> Enum.drop(2) |> Enum.map(&length(&1.units))

    assert two_projection_queries?(second_queries)

    assert 4 ==
             [status: :validating, limit: 101]
             |> maybe_after(starting_cursor)
             |> Coordination.list()
             |> length()

    assert [] = Coordination.list(status: :validating, limit: 2, after: Ecto.UUID.generate())

    string_filters =
      %{"status" => "validating", "limit" => 1}
      |> maybe_after("after", starting_cursor)

    assert [%{status: :validating}] =
             Coordination.list(string_filters)

    atom_filters = maybe_after([status: :validating, limit: 1], starting_cursor)
    assert [%{status: :validating}] = Coordination.list(atom_filters)

    assert 4 ==
             [status: :validating, limit: "not-an-integer"]
             |> maybe_after(starting_cursor)
             |> Coordination.list()
             |> length()

    assert [] = Coordination.list(status: %{"unexpected" => true})
    assert [] = Coordination.list(idempotency_key: {:invalid, "tuple"})
  end

  defp latest_task(cursor \\ nil, latest \\ nil) do
    filters = maybe_after([limit: 101], cursor)

    case Coordination.list(filters) do
      [] -> latest
      page -> latest_task(List.last(page).id, List.last(page))
    end
  end

  defp capture_list_queries(filters) do
    handler_id = "coordination-pagination-#{System.unique_integer([:positive])}"
    caller = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:symphony_elixir, :repo, :query],
        fn _event, _measurements, metadata, pid -> send(pid, {:repo_query, metadata.query}) end,
        caller
      )

    tasks = Coordination.list(filters)
    :telemetry.detach(handler_id)
    {tasks, drain_queries([])}
  end

  defp drain_queries(queries) do
    receive do
      {:repo_query, query} -> drain_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp two_projection_queries?(queries) do
    selects = Enum.filter(queries, &String.starts_with?(String.upcase(String.trim(&1)), "SELECT"))

    length(selects) == 2 and
      Enum.any?(selects, &String.contains?(&1, "coordination_task_projections")) and
      Enum.any?(selects, &String.contains?(&1, "coordination_unit_projections"))
  end

  defp maybe_after(filters, nil), do: filters
  defp maybe_after(filters, cursor), do: Keyword.put(filters, :after, cursor)

  defp maybe_after(filters, _key, nil), do: filters
  defp maybe_after(filters, key, cursor), do: Map.put(filters, key, cursor)

  defp start_task(run_id, index) do
    Coordination.start_task(%{
      idempotency_key: "pagination:#{run_id}:#{index}",
      external_id: "TASK-#{run_id}-#{index}",
      config_revision_id: Ecto.UUID.generate(),
      baseline: "0123456789abcdef"
    })
  end
end
