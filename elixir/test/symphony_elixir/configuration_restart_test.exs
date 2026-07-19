defmodule SymphonyElixir.ConfigurationRestartTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Configuration.{Revision, TaskPin}
  alias SymphonyElixir.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    Repo.delete_all(Revision)

    on_exit(fn ->
      unless Process.whereis(Repo) do
        {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
      end

      if Process.whereis(Repo) do
        Sandbox.mode(Repo, :auto)
        Repo.delete_all(TaskPin)
        Repo.delete_all(Revision)
        Sandbox.mode(Repo, :manual)
      end
    end)

    :ok
  end

  test "active configuration revision survives a supervised Repo restart" do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert Configuration.active!().id == active.id

    assert Configuration.active!().document["automation_projects"] |> hd() |> Map.fetch!("name") ==
             "Symphony"
  end

  test "task configuration pin survives a supervised Repo restart" do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")
    {:ok, pin} = Configuration.pin_for_task("task-1", actor: "scheduler")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert Configuration.pinned_for_task!("task-1").id == pin.id
    assert Configuration.pinned_for_task!("task-1").revision_id == active.id
  end

  defp valid_document do
    Document.for_project(%{
      "id" => "symphony",
      "name" => "Symphony",
      "tracker" => %{"kind" => "github", "scope" => "WangShayne/Symphony-works"},
      "repository" => %{
        "url" => "git@github.com:WangShayne/Symphony-works.git",
        "target_branch" => "main"
      }
    })
  end
end
