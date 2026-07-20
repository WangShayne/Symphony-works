defmodule SymphonyElixir.ConfigurationTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.{Config, Configuration}
  alias SymphonyElixir.Configuration.{Document, Exporter, Validator}
  alias SymphonyElixir.Security.SecretStore

  defmodule FailingProbe do
    @behaviour SymphonyElixir.Configuration.Probe

    @impl true
    def validate(_document), do: {:error, {:model, %{"message" => "offline", "api_key" => "secret"}}}
  end

  defmodule PassingProbe do
    @behaviour SymphonyElixir.Configuration.Probe

    @impl true
    def validate(_document), do: {:ok, %{"kind" => "model", "api_key" => "secret"}}
  end

  test "runtime coordination accessors honor application overrides" do
    previous_lifecycle = Application.get_env(:symphony_elixir, :orchestrator_lifecycle_enabled)
    previous_adapter = Application.get_env(:symphony_elixir, :task_creation_effect_adapter)

    on_exit(fn ->
      restore_env(:orchestrator_lifecycle_enabled, previous_lifecycle)
      restore_env(:task_creation_effect_adapter, previous_adapter)
    end)

    Application.delete_env(:symphony_elixir, :orchestrator_lifecycle_enabled)
    assert Config.orchestrator_lifecycle_enabled?()

    Application.put_env(:symphony_elixir, :orchestrator_lifecycle_enabled, false)
    refute Config.orchestrator_lifecycle_enabled?()

    Application.delete_env(:symphony_elixir, :task_creation_effect_adapter)
    assert Config.task_creation_effect_adapter() == SymphonyElixir.Effects.SimulatedAdapter

    Application.put_env(:symphony_elixir, :task_creation_effect_adapter, PassingProbe)
    assert Config.task_creation_effect_adapter() == PassingProbe
  end

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

  test "failed health probe leaves the active revision unchanged and redacts evidence" do
    {:ok, current_draft} =
      Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    {:ok, current} = Configuration.activate(current_draft.id, actor: "bootstrap-admin")

    {:ok, draft} =
      Configuration.create_draft(
        put_in(valid_document(), ["automation_projects", Access.at(0), "name"], "Probe target"),
        actor: "bootstrap-admin"
      )

    assert {:error, {:probe_failed, :model, evidence}} =
             Configuration.activate(draft.id, actor: "bootstrap-admin", probes: [FailingProbe])

    assert evidence["api_key"] == "[REDACTED]"
    assert Configuration.active!().id == current.id
  end

  test "successful health probes are recorded with redacted evidence" do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert {:ok, active} =
             Configuration.activate(draft.id, actor: "bootstrap-admin", probes: [PassingProbe])

    assert [%{"api_key" => "[REDACTED]", "kind" => "model"}] =
             active.validation_evidence["probes"]

    assert {:ok, evidence} = Validator.validate(valid_document())
    assert evidence["probes"] == []

    assert Exporter.redact(%{api_key: "secret"}) == %{api_key: "[REDACTED]"}
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

    assert {:error, :not_found} =
             Configuration.update_draft(missing_id, valid_document(), actor: "bootstrap-admin")

    {:ok, active_draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(active_draft.id, actor: "bootstrap-admin")

    assert {:error, {:invalid_transition, :active, :draft_update}} =
             Configuration.update_draft(active.id, valid_document(), actor: "bootstrap-admin")

    assert {:error, :not_found} = Configuration.rollback(missing_id, actor: "bootstrap-admin")
    assert {:error, :not_found} = Configuration.export(missing_id, redacted: true)

    {:ok, rollback_draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert {:error, {:invalid_transition, :draft, :rollback}} =
             Configuration.rollback(rollback_draft.id, actor: "bootstrap-admin")
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

  test "Administrator updates a draft and running tasks keep their pinned immutable revision" do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    renamed =
      put_in(valid_document(), ["automation_projects", Access.at(0), "name"], "Pinned Symphony")

    assert {:ok, updated_draft} =
             Configuration.update_draft(draft.id, renamed, actor: "bootstrap-admin")

    assert updated_draft.status == :draft
    assert updated_draft.content_hash == Document.content_hash(renamed)

    assert {:ok, active} = Configuration.activate(updated_draft.id, actor: "bootstrap-admin")
    assert {:ok, pinned} = Configuration.pin_for_task("task-1", actor: "scheduler")

    replacement =
      put_in(valid_document(), ["automation_projects", Access.at(0), "name"], "Replacement")

    {:ok, replacement_draft} = Configuration.create_draft(replacement, actor: "bootstrap-admin")
    assert {:ok, replacement_active} = Configuration.activate(replacement_draft.id, actor: "bootstrap-admin")

    assert replacement_active.id != active.id
    assert pinned.revision_id == active.id
    assert pinned.content_hash == active.content_hash

    assert Configuration.pinned_for_task!("task-1").revision_id == active.id
    assert Configuration.pinned_for_task!("task-1").document == active.document

    assert {:ok, existing_pin} = Configuration.pin_for_task("task-1", actor: "scheduler")
    assert existing_pin.id == pinned.id
  end

  test "task recovery pins its captured active revision and refuses a different explicit revision" do
    {:ok, first_draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, first_active} = Configuration.activate(first_draft.id, actor: "bootstrap-admin")

    replacement =
      put_in(valid_document(), ["automation_projects", Access.at(0), "name"], "Replacement")

    {:ok, replacement_draft} = Configuration.create_draft(replacement, actor: "bootstrap-admin")
    {:ok, replacement_active} = Configuration.activate(replacement_draft.id, actor: "bootstrap-admin")
    first_active_id = first_active.id

    assert {:ok, pin} =
             Configuration.pin_for_task("recovered-task",
               actor: "scheduler",
               revision_id: first_active.id
             )

    assert pin.revision_id == first_active.id

    assert {:ok, same_pin} =
             Configuration.pin_for_task("recovered-task",
               actor: "scheduler",
               revision_id: first_active.id
             )

    assert same_pin.id == pin.id

    assert {:error, {:configuration_pin_conflict, ^first_active_id}} =
             Configuration.pin_for_task("recovered-task",
               actor: "scheduler",
               revision_id: replacement_active.id
             )

    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert {:error, {:invalid_pin_revision_status, :draft}} =
             Configuration.pin_for_task("draft-task",
               actor: "scheduler",
               revision_id: draft.id
             )
  end

  test "Administrator rolls back to a prior immutable revision and exports redacted configuration" do
    {:ok, first_draft} = Configuration.create_draft(secret_document("first-secret"), actor: "admin")
    {:ok, first_active} = Configuration.activate(first_draft.id, actor: "admin")

    {:ok, next_draft} = Configuration.create_draft(secret_document("next-secret"), actor: "admin")
    {:ok, next_active} = Configuration.activate(next_draft.id, actor: "admin")

    assert next_active.id == Configuration.active!().id

    assert {:ok, rolled_back} = Configuration.rollback(first_active.id, actor: "admin")

    assert rolled_back.id == first_active.id
    assert rolled_back.status == :active
    assert Configuration.active!().content_hash == first_active.content_hash

    assert {:ok, exported} = Configuration.export(rolled_back.id, redacted: true)
    encoded = Jason.encode!(exported)

    refute encoded =~ "first-secret"
    assert encoded =~ "[REDACTED]"

    assert {:error, {:invalid_transition, :active, :rollback}} =
             Configuration.rollback(rolled_back.id, actor: "admin")
  end

  test "starter templates create valid inactive task and execution profile definitions" do
    templates = Configuration.templates()

    assert %{"task_types" => [_ | _], "execution_profiles" => [_ | _]} = templates

    document =
      valid_document()
      |> Map.put("task_types", templates["task_types"])
      |> Map.put("execution_profiles", templates["execution_profiles"])

    assert {:ok, ^document} = Document.validate(document)
  end

  test "draft revision binds provider-owned credential references without tracker duplication or plaintext" do
    {:ok, reference} = SecretStore.put("linear-api-token", "plain-provider-token", actor: "bootstrap-admin")
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert {:ok, updated} =
             Configuration.bind_provider_credential(
               draft.id,
               %{"id" => "linear", "name" => "Linear"},
               SecretStore.export_reference(reference),
               actor: "bootstrap-admin"
             )

    assert updated.status == :draft
    assert updated.document["automation_projects"] |> hd() |> get_in(["tracker", "credential_ref"]) == nil

    assert updated.document["providers"] == [
             %{
               "id" => "linear",
               "name" => "Linear",
               "credential_ref" => reference.id
             }
           ]

    refute Jason.encode!(updated.document) =~ "plain-provider-token"
    refute Jason.encode!(updated.document) =~ "linear-api-token"
  end

  test "provider credential binding rejects missing, mismatched, and non-draft revisions" do
    {:ok, reference} = SecretStore.put("linear-api-token", "plain-provider-token", actor: "bootstrap-admin")
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")
    {:ok, next_draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    provider = %{"id" => "linear", "name" => "Linear"}
    missing_reference = %{"id" => Ecto.UUID.generate(), "name" => "linear-api-token"}
    mismatched_reference = %{"id" => reference.id, "name" => "wrong-name"}

    assert {:error, :not_found} =
             Configuration.bind_provider_credential(next_draft.id, provider, missing_reference, actor: "bootstrap-admin")

    assert {:error, :reference_mismatch} =
             Configuration.bind_provider_credential(next_draft.id, provider, mismatched_reference, actor: "bootstrap-admin")

    assert {:error, {:invalid_transition, :active, :draft}} =
             Configuration.bind_provider_credential(active.id, provider, SecretStore.export_reference(reference), actor: "bootstrap-admin")
  end

  test "provider credential binding normalizes atom maps and replaces existing providers" do
    {:ok, first_reference} = SecretStore.put("linear-api-token", "first-provider-token", actor: "bootstrap-admin")
    {:ok, second_reference} = SecretStore.put("linear-api-token-next", "second-provider-token", actor: "bootstrap-admin")
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert {:ok, first} =
             Configuration.bind_provider_credential(
               draft.id,
               %{id: "linear", name: "Linear"},
               %{id: first_reference.id, name: first_reference.name},
               actor: "bootstrap-admin"
             )

    assert get_in(first.document, ["providers", Access.at(0), "credential_ref"]) == first_reference.id

    assert {:ok, second} =
             Configuration.bind_provider_credential(
               draft.id,
               %{"id" => "linear", "name" => "Linear"},
               %{id: second_reference.id, name: second_reference.name},
               actor: "bootstrap-admin"
             )

    assert second.document["providers"] == [
             %{
               "id" => "linear",
               "name" => "Linear",
               "credential_ref" => second_reference.id
             }
           ]

    refute Jason.encode!(second.document) =~ "second-provider-token"
    refute Jason.encode!(second.document) =~ "linear-api-token-next"
  end

  test "provider credential binding rejects missing revisions and malformed input" do
    {:ok, reference} = SecretStore.put("linear-api-token", "plain-provider-token", actor: "bootstrap-admin")
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")

    assert {:error, :not_found} =
             Configuration.bind_provider_credential(
               Ecto.UUID.generate(),
               %{"id" => "linear", "name" => "Linear"},
               SecretStore.export_reference(reference),
               actor: "bootstrap-admin"
             )

    assert {:error, :invalid_provider} =
             Configuration.bind_provider_credential(
               draft.id,
               %{"id" => "", "name" => "Linear"},
               SecretStore.export_reference(reference),
               actor: "bootstrap-admin"
             )

    assert {:error, :invalid_provider} =
             Configuration.bind_provider_credential(
               draft.id,
               %{},
               SecretStore.export_reference(reference),
               actor: "bootstrap-admin"
             )

    assert {:error, :invalid_reference} =
             Configuration.bind_provider_credential(
               draft.id,
               %{"id" => "linear", "name" => "Linear"},
               %{},
               actor: "bootstrap-admin"
             )
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

  defp secret_document(secret) do
    valid_document()
    |> Map.put("integrations", [
      %{"id" => "tracker", "kind" => "github", "credential_ref" => "secret:#{secret}"}
    ])
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
