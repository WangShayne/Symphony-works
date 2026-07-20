defmodule SymphonyElixir.Coordination.RestartTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  import Ecto.Query

  alias SymphonyElixir.Coordination
  alias SymphonyElixir.Coordination.{TaskProjection, UnitProjection}
  alias SymphonyElixir.Repo

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      unless Process.whereis(Repo) do
        {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
      end

      Sandbox.mode(Repo, :auto)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "task and unit snapshots survive a supervised Repo restart" do
    {:ok, task} =
      Coordination.start_task(%{
        idempotency_key: "restart:#{Ecto.UUID.generate()}",
        external_id: "RESTART-1",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef"
      })

    on_exit(fn -> delete_projections(task.id) end)

    assert {:ok, 2} =
             Coordination.append(task.id, 1, [
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "docs-1",
                   task_type: "documentation",
                   execution_profile: "docs-default",
                   dependencies: []
                 }
               }
             ])

    assert {:ok, before} = Coordination.snapshot(task.id)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert {:ok, ^before} = Coordination.snapshot(task.id)
  end

  defp delete_projections(task_id) do
    unless Process.whereis(Repo) do
      {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    end

    Sandbox.mode(Repo, :auto)
    Repo.delete_all(from(unit in UnitProjection, where: unit.task_id == ^task_id))
    Repo.delete_all(from(task in TaskProjection, where: task.task_id == ^task_id))
  end
end
