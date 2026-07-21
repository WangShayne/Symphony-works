defmodule SymphonyElixir.ConfigurationRestartTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Configuration.{Revision, TaskPin}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore

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

  test "independent integration settings survive a supervised Repo restart" do
    document =
      valid_document()
      |> Map.put("integrations", [
        %{
          "id" => "tracker-fixture",
          "kind" => "tracker",
          "provider" => "fixture",
          "settings" => %{"scenario" => "healthy"}
        },
        %{
          "id" => "delivery-fixture",
          "kind" => "source_control",
          "provider" => "fixture",
          "settings" => %{
            "repository" => "WangShayne/Symphony-works",
            "base_branch" => "main",
            "scenario" => "healthy"
          }
        }
      ])

    assert {:ok, draft} = Configuration.create_draft(document, actor: "bootstrap-admin")
    assert {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert {:ok, exported} = Configuration.export(active.id, redacted: true)
    assert get_in(exported, ["document", "integrations"]) == document["integrations"]

    assert %{
             "probes" => [
               %{
                 "probe" => "integrations",
                 "status" => "passed",
                 "integration_count" => 2
               }
             ]
           } = Configuration.active!().validation_evidence
  end

  test "Linear workflow state ID mappings survive a supervised Repo restart" do
    state_ids = %{
      "started" => "state-started",
      "completed" => "state-completed",
      "cancelled" => "state-cancelled"
    }

    document =
      valid_document()
      |> put_in(
        ["automation_projects", Access.at(0), "tracker_integration_ref"],
        "linear-main"
      )
      |> put_in(
        ["automation_projects", Access.at(0), "source_control_integration_ref"],
        "delivery-main"
      )
      |> Map.put("integrations", [
        %{
          "id" => "linear-main",
          "kind" => "tracker",
          "provider" => "linear",
          "credential_ref" => "00000000-0000-4000-8000-000000000021",
          "settings" => %{
            "project_slug" => "ENG",
            "bot_actor_id" => "linear-bot",
            "webhook_secret_ref" => "00000000-0000-4000-8000-000000000022",
            "state_ids" => state_ids
          }
        },
        %{
          "id" => "delivery-main",
          "kind" => "source_control",
          "provider" => "github",
          "credential_ref" => "00000000-0000-4000-8000-000000000023",
          "settings" => %{
            "repository" => "WangShayne/Symphony-works",
            "base_branch" => "main"
          }
        }
      ])

    assert {:ok, ^document} = Document.validate(document)
    assert {:ok, draft} = Configuration.create_draft(document, actor: "bootstrap-admin")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert {:ok, exported} = Configuration.export(draft.id, redacted: true)
    assert get_in(exported, ["document", "integrations", Access.at(0), "settings", "state_ids"]) == state_ids
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

  test "provider credential binding survives Repo restart and exports only opaque metadata" do
    {:ok, reference} = SecretStore.put("linear-api-token", "plain-provider-token", actor: "bootstrap-admin")
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert {:ok, updated} =
             Configuration.bind_provider_credential(
               draft.id,
               %{"id" => "linear", "name" => "Linear"},
               SecretStore.export_reference(reference),
               actor: "bootstrap-admin"
             )

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    restarted = Repo.get!(Revision, updated.id)
    encoded = Jason.encode!(restarted.document)

    assert restarted.document["providers"] == [
             %{
               "id" => "linear",
               "name" => "Linear",
               "credential_ref" => reference.id
             }
           ]

    refute encoded =~ "plain-provider-token"
    refute encoded =~ "linear-api-token"
    refute encoded =~ "api_key"
  end

  test "secret reference list survives Repo restart with opaque metadata only" do
    {:ok, reference} = SecretStore.put("linear-api-token", "plain-provider-token", actor: "bootstrap-admin")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    references = SecretStore.list_references()

    assert Enum.any?(references, &(&1.id == reference.id and &1.name == "linear-api-token"))
    refute inspect(references) =~ "plain-provider-token"
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
