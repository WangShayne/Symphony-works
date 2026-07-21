defmodule SymphonyElixir.Configuration.WorkflowImporterTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Revision
  alias SymphonyElixir.Configuration.WorkflowImporter

  test "imports an upstream WORKFLOW.md into a draft without making the file runtime authority" do
    workflow = """
    ---
    tracker:
      kind: github
      project_slug: WangShayne/Symphony-works
      api_key: ghp_should_not_export
    workspace:
      root: /tmp/symphony-workspaces
    codex:
      command: codex app-server
      thread_sandbox: workspace-write
    ---
    Implement the tracked issue with care.
    """

    assert {:ok, draft} =
             Configuration.import(%{"content" => workflow, "source" => "WORKFLOW.md"},
               actor: "admin"
             )

    assert draft.status == :draft
    assert [project] = draft.document["automation_projects"]
    assert project["tracker"]["kind"] == "github"
    assert project["tracker"]["scope"] == "WangShayne/Symphony-works"
    assert project["tracker_integration_ref"] == "tracker"
    assert hd(draft.document["task_types"])["name"] == "General"
    profile = hd(draft.document["execution_profiles"])
    assert profile["instructions"] =~ "Implement the tracked issue"
    refute Map.has_key?(profile, "command")
    refute Map.has_key?(profile, "thread_sandbox")

    integrations = Map.new(draft.document["integrations"], &{&1["id"], &1})
    assert integrations["tracker"]["provider"] == "github"

    assert integrations["tracker"]["settings"] == %{
             "owner" => "WangShayne",
             "repository" => "Symphony-works"
           }

    refute Map.has_key?(integrations["tracker"], "credential_ref")
    assert integrations["workspace"]["settings"]["root"] == "/tmp/symphony-workspaces"
    assert integrations["codex"]["settings"]["command"] == "codex app-server"
    assert integrations["codex"]["settings"]["thread_sandbox"] == "workspace-write"

    refute Map.has_key?(draft.document, "workflow_path")

    assert {:ok, exported} = Configuration.export(draft.id, redacted: true)
    refute Jason.encode!(exported) =~ "ghp_should_not_export"
  end

  test "rejects server paths and imports content bytes without later source authority" do
    path = Path.join(System.tmp_dir!(), "symphony-workflow-importer-test.md")
    File.write!(path, "---\ntracker:\n  kind: github\n---\nPrompt")

    assert {:error, :missing_workflow_source} = WorkflowImporter.import(%{"path" => path})
    assert {:error, :missing_workflow_source} = Configuration.import(%{"path" => path}, actor: "admin")
    assert Repo.aggregate(Revision, :count) == 0

    assert {:ok, draft} =
             Configuration.import(%{"content" => File.read!(path)}, actor: "admin")

    document = draft.document
    assert document["integrations"] == []

    File.write!(path, "---\ntracker:\n  kind: gitlab\n---\nChanged")
    assert hd(document["execution_profiles"])["instructions"] == "Prompt"
    assert Configuration.active() == {:error, :not_found}

    assert {:error, :missing_workflow_source} = WorkflowImporter.import(%{})
  after
    File.rm(Path.join(System.tmp_dir!(), "symphony-workflow-importer-test.md"))
  end

  test "imports provider-specific tracker settings only when legacy API keys exist" do
    for {kind, project_slug, expected_settings} <- [
          {"github", "not-a-repository-slug", %{}},
          {"gitlab", "group/project", %{"project_id" => "group/project"}},
          {"linear", "ENG", %{"project_slug" => "ENG"}},
          {"unknown", "ignored", %{}}
        ] do
      workflow = """
      ---
      tracker:
        kind: #{kind}
        project_slug: #{project_slug}
        api_key: legacy-secret
      ---
      Prompt
      """

      assert {:ok, draft} = WorkflowImporter.import(%{"content" => workflow})
      assert [%{"id" => "tracker", "settings" => ^expected_settings}] = draft["integrations"]
    end
  end
end
