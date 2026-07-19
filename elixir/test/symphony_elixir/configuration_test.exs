defmodule SymphonyElixir.ConfigurationTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document

  test "Administrator creates, validates, and atomically activates one Automation Project" do
    assert {:ok, draft} =
             Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert draft.status == :draft
    assert {:ok, validated} = Configuration.validate(draft.id, actor: "bootstrap-admin")
    assert validated.status == :validated

    assert {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")
    assert active.status == :active
    assert active.document["automation_projects"] == valid_document()["automation_projects"]
    assert Configuration.active!().id == active.id
  end

  test "validating an active revision cannot remove the active configuration" do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")

    assert {:error, {:invalid_transition, :active, :validated}} =
             Configuration.validate(active.id, actor: "bootstrap-admin")

    assert {:ok, still_active} = Configuration.active()
    assert still_active.id == active.id
    assert still_active.status == :active
  end

  test "failed validation cannot displace the active revision" do
    {:ok, current_draft} =
      Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    {:ok, current} = Configuration.activate(current_draft.id, actor: "bootstrap-admin")

    invalid_document =
      put_in(
        valid_document(),
        ["automation_projects", Access.at(0), "repository", "url"],
        ""
      )

    {:ok, invalid_draft} =
      Configuration.create_draft(invalid_document, actor: "bootstrap-admin")

    assert {:error, {:invalid_configuration, errors}} =
             Configuration.activate(invalid_draft.id, actor: "bootstrap-admin")

    assert Enum.any?(errors, &(&1.path == ["automation_projects", "0", "repository", "url"]))
    assert Configuration.active!().id == current.id
  end

  test "public lookup and validation report missing or invalid revisions" do
    assert {:error, :not_found} = Configuration.active()

    missing_id = Ecto.UUID.generate()
    assert {:error, :not_found} = Configuration.validate(missing_id, actor: "bootstrap-admin")
    assert {:error, :not_found} = Configuration.activate(missing_id, actor: "bootstrap-admin")

    invalid_document = %{"schema_version" => 1, "automation_projects" => []}
    {:ok, invalid_draft} = Configuration.create_draft(invalid_document, actor: "bootstrap-admin")

    assert {:error, {:invalid_configuration, _errors}} =
             Configuration.validate(invalid_draft.id, actor: "bootstrap-admin")
  end

  test "activating a new valid revision supersedes the previous active revision" do
    {:ok, first_draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, first} = Configuration.activate(first_draft.id, actor: "bootstrap-admin")

    updated = put_in(valid_document(), ["automation_projects", Access.at(0), "name"], "Next")
    {:ok, next_draft} = Configuration.create_draft(updated, actor: "bootstrap-admin")
    {:ok, next} = Configuration.activate(next_draft.id, actor: "bootstrap-admin")

    assert next.id != first.id
    assert Configuration.active!().id == next.id

    assert Configuration.active!().document["automation_projects"] |> hd() |> Map.fetch!("name") ==
             "Next"
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
