defmodule SymphonyElixir.Coordination.RebuildAllFailureTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.{Coordination, Repo}

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

  test "returns an error when the durable event store is unavailable" do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:error, %RuntimeError{}} = Coordination.rebuild_all_projections()
  end
end
