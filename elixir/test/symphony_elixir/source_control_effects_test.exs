defmodule SymphonyElixir.SourceControlEffectsTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Configuration.{Revision, TaskPin}
  alias SymphonyElixir.Effects
  alias SymphonyElixir.Effects.{OperationId, Record}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.EffectAdapter

  defmodule UnknownOutcomeAdapter do
    @spec execute(Record.t()) :: {:unknown, :unknown_outcome}
    def execute(%Record{}), do: {:unknown, :unknown_outcome}

    @spec reconcile(Record.t()) :: {:unknown, :not_observed}
    def reconcile(%Record{}), do: {:unknown, :not_observed}
  end

  defmodule UnknownSourceControl do
    def ensure_change_request(_attrs, _opts), do: {:error, :unknown_outcome}
  end

  test "source control mutations are journaled once and replay the recorded result" do
    operation_id = OperationId.generate()
    attrs = fixture_effect(operation_id, "journal-once")

    assert {:ok, %Record{status: :succeeded} = first} = SourceControl.execute_effect(attrs)
    assert {:ok, %Record{status: :succeeded} = replay} = SourceControl.execute_effect(attrs)

    assert replay.operation_id == first.operation_id
    assert replay.dedupe_hash == first.dedupe_hash
    assert replay.result == first.result
    assert replay.result["provider"] == "fixture"
    assert replay.result["repository"] == "acme/journal-once"
    assert [%Record{operation_id: ^operation_id}] = Effects.list(task_id: attrs.task_id)
  end

  test "a fixture unknown outcome is reconciled before the effect becomes successful" do
    operation_id = OperationId.generate()
    attrs = fixture_effect(operation_id, "recoverable")
    assert {:ok, prepared} = EffectAdapter.prepare(attrs)

    assert {:error, :unknown_outcome} = Effects.execute(prepared, UnknownOutcomeAdapter)
    assert %Record{status: :unknown} = Effects.get!(operation_id)

    assert {:ok, %Record{status: :succeeded} = recovered} =
             Effects.reconcile(operation_id, EffectAdapter)

    assert recovered.result["provider"] == "fixture"
    assert recovered.result["repository"] == "acme/recoverable"
  end

  test "GitHub and GitLab create unknown outcomes remain unknown without list or repost" do
    for provider <- ["github", "gitlab"] do
      operation_id = OperationId.generate()
      attrs = provider_effect(operation_id, provider)
      assert {:ok, prepared} = EffectAdapter.prepare(attrs)

      assert {:error, :unknown_outcome} = Effects.execute(prepared, UnknownOutcomeAdapter)

      assert {:error, :change_request_reconciliation_required} =
               Effects.reconcile(operation_id, EffectAdapter)

      assert %Record{
               status: :unknown,
               error: %{"code" => "change_request_reconciliation_required"}
             } = Effects.get!(operation_id)
    end
  end

  test "runtime credentials and transports never enter the effect intent" do
    operation_id = OperationId.generate()
    canary = "source-control-secret-#{System.unique_integer([:positive])}"

    attrs =
      operation_id
      |> fixture_effect("redacted")
      |> put_in([:intent, :attrs, :repo, :credential], canary)
      |> put_in([:intent, :attrs, :repo, :transport], canary)

    assert {:ok, %Record{} = record} = SourceControl.execute_effect(attrs)

    serialized = inspect(record.intent, limit: :infinity, printable_limit: :infinity)
    refute serialized =~ canary
    refute serialized =~ "credential"
    refute serialized =~ "transport"
  end

  test "branch, push, draft, close, and comment mutations use the same durable seam" do
    config = fixture_config("mutation-suite")
    old_sha = String.duplicate("1", 40)
    new_sha = String.duplicate("2", 40)

    assert {:ok, %Record{status: :succeeded}} =
             execute_fixture_effect(
               "ensure_remote_branch",
               %{"config" => config, "branch" => %{"name" => "task/mutation-suite", "commit_sha" => old_sha}},
               "ensure-branch"
             )

    assert {:ok, %Record{status: :succeeded, result: %{"commit_sha" => ^new_sha}}} =
             execute_fixture_effect(
               "push_branch",
               %{
                 "config" => config,
                 "branch" => "task/mutation-suite",
                 "commit_sha" => new_sha,
                 "expected_remote_sha" => old_sha
               },
               "push-branch"
             )

    assert {:ok, %Record{result: change_request}} =
             SourceControl.execute_effect(fixture_effect(OperationId.generate(), "mutation-suite"))

    assert {:ok, %Record{result: %{"draft?" => false}}} =
             execute_fixture_effect(
               "set_draft",
               %{"config" => config, "change_request" => change_request, "draft" => false},
               "set-draft"
             )

    assert {:ok, %Record{status: :succeeded}} =
             execute_fixture_effect(
               "close_or_comment",
               %{"config" => config, "change_request" => change_request, "action" => "close"},
               "close"
             )

    assert {:ok, %Record{status: :succeeded}} =
             execute_fixture_effect(
               "close_or_comment",
               %{
                 "config" => config,
                 "change_request" => change_request,
                 "action" => "comment",
                 "body" => "Durable progress"
               },
               "comment"
             )
  end

  test "effect preparation validates and canonicalizes the persisted boundary" do
    valid = fixture_effect(OperationId.generate(), "canonical")

    atom_input =
      valid
      |> Map.put(:action, :ensure_change_request)
      |> put_in([:intent, :attrs, :repo, :provider], :fixture)
      |> put_in([:intent, :metadata], [:one, :two])

    assert {:ok, prepared} = EffectAdapter.prepare(atom_input)
    assert prepared.intent["metadata"] == ["one", "two"]
    assert prepared.provider == "fixture"
    assert prepared.target == "acme/canonical"

    assert {:error, :invalid_effect} = EffectAdapter.prepare(nil)
    assert {:error, :invalid_effect} = SourceControl.execute_effect(nil)
    assert {:error, :invalid_effect} = SourceControl.execute_effect(%{}, :invalid_options)
    assert {:error, :invalid_effect} = EffectAdapter.prepare(%{})
    assert {:error, :invalid_effect} = EffectAdapter.prepare(%{action: :unsupported, intent: %{}})
    assert {:error, :invalid_effect} = EffectAdapter.prepare(%{action: :ensure_change_request, intent: []})

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs], "not-a-map")
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, :provider], "unsupported")
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, :provider], 123)
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, :settings, :repository], "  ")
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, :settings], nil)
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, :settings], "not-a-map")
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             EffectAdapter.prepare(%{
               action: "push_branch",
               intent: %{"config" => "not-a-map"}
             })

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :opaque], self())
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> update_in([:intent], &Map.put(&1, 1, "invalid-key"))
             |> EffectAdapter.prepare()
  end

  test "reconciliation and credential failures fail closed without external replay" do
    invalid_fixture = %Record{
      action: "ensure_change_request",
      provider: "fixture",
      intent: %{"attrs" => "invalid"}
    }

    assert {:unknown, :invalid_effect} = EffectAdapter.reconcile(invalid_fixture)

    assert {:unknown, :source_control_reconciliation_required} =
             EffectAdapter.reconcile(%Record{action: "push_branch", provider: "github"})

    assert {:unknown, :invalid_source_control_effect} =
             EffectAdapter.reconcile(%Record{action: "push_branch", provider: "unsupported"})

    assert {:error, :invalid_effect} = EffectAdapter.execute(%Record{action: "unsupported", intent: %{}})

    github_attrs = provider_effect(OperationId.generate(), "github")
    github_without_reference = put_in(github_attrs, [:intent, "attrs", "repo", "credential_ref"], nil)

    assert {:error, :missing_credential_reference} =
             SourceControl.execute_effect(github_without_reference)

    assert {:ok, reference} =
             SecretStore.put("source-control-effect-test", "runtime-token", actor: "test")

    reference_id = SecretStore.export_reference(reference)
    assert is_binary(reference_id)

    invalid_with_reference =
      github_attrs
      |> put_in(
        [:intent, "attrs", "repo", "credential_ref"],
        reference_id
      )
      |> update_in([:intent, "attrs"], &Map.delete(&1, "title"))

    assert {:ok, prepared_with_reference} = EffectAdapter.prepare(invalid_with_reference)
    refute Map.has_key?(get_in(prepared_with_reference, [:intent, "attrs", "repo"]), "credential_ref")

    repo = get_in(invalid_with_reference, [:intent, "attrs", "repo"])
    pin_integrations(invalid_with_reference.task_id, ["ignored", Map.put(repo, "kind", "source_control")])

    assert {:error, :invalid_configuration} =
             SourceControl.execute_effect(invalid_with_reference)
  end

  test "source control unknown results become recoverable unknown Effect Records" do
    previous = Application.get_env(:symphony_elixir, :source_control_effect_invoker)
    Application.put_env(:symphony_elixir, :source_control_effect_invoker, UnknownSourceControl)

    on_exit(fn -> restore_env(:source_control_effect_invoker, previous) end)

    operation_id = OperationId.generate()

    assert {:error, :unknown_outcome} =
             SourceControl.execute_effect(fixture_effect(operation_id, "unknown-result"))

    assert %Record{status: :unknown, error: %{"code" => "unknown_outcome"}} =
             Effects.get!(operation_id)
  end

  test "runtime credential resolver rejects missing, invalid, and interrupted lookups" do
    previous =
      Application.get_env(:symphony_elixir, :source_control_effect_credential_resolver)

    on_exit(fn -> restore_env(:source_control_effect_credential_resolver, previous) end)

    for {suffix, resolver, expected} <- [
          {"invalid", fn _task_id, _config -> :invalid end, :missing_credential_reference},
          {"error", fn _task_id, _config -> {:error, :not_found} end, :not_found},
          {"raise", fn _task_id, _config -> raise "resolver failed" end, :missing_credential_reference},
          {"throw", fn _task_id, _config -> throw(:resolver_failed) end, :missing_credential_reference}
        ] do
      Application.put_env(
        :symphony_elixir,
        :source_control_effect_credential_resolver,
        resolver
      )

      attrs =
        OperationId.generate()
        |> provider_effect("github")
        |> Map.put(:task_id, "credential-resolver-#{suffix}")

      assert {:error, ^expected} = SourceControl.execute_effect(attrs)
    end

    assert {:ok, reference} =
             SecretStore.put("generic-source-control-effect", "runtime-token", actor: "test")

    reference_id = SecretStore.export_reference(reference)

    Application.put_env(
      :symphony_elixir,
      :source_control_effect_credential_resolver,
      fn _task_id, _config -> {:ok, reference_id} end
    )

    assert {:error, :invalid_configuration} =
             SourceControl.execute_effect(%{
               operation_id: OperationId.generate(),
               task_id: "generic-credential-resolution",
               plan_revision: 1,
               action: "push_branch",
               intent: %{
                 "config" => %{
                   "id" => "delivery-main",
                   "provider" => "github",
                   "settings" => %{
                     "repository" => "acme/generic-credential-resolution",
                     "base_branch" => "main"
                   }
                 },
                 "branch" => "task/generic-credential-resolution",
                 "commit_sha" => String.duplicate("2", 40)
               }
             })
  end

  test "pinned credential resolution requires one matching integration with a reference" do
    missing_match = provider_effect(OperationId.generate(), "github")

    pin_integrations(missing_match.task_id, [
      %{
        "id" => "another-delivery",
        "kind" => "source_control",
        "provider" => "github",
        "credential_ref" => "00000000-0000-0000-0000-000000000001",
        "settings" => %{"repository" => "acme/unknown-create"}
      }
    ])

    assert {:error, :missing_credential_reference} =
             SourceControl.execute_effect(missing_match)

    missing_reference =
      OperationId.generate()
      |> provider_effect("github")
      |> Map.put(:task_id, "pinned-integration-missing-reference")

    config =
      missing_reference
      |> get_in([:intent, "attrs", "repo"])
      |> Map.delete("credential_ref")

    pin_integrations(missing_reference.task_id, [Map.put(config, "kind", "source_control")])

    assert {:error, :missing_credential_reference} =
             SourceControl.execute_effect(missing_reference)
  end

  test "persisted Change Request shapes are rehydrated and invalid shapes fail closed" do
    config = fixture_config("rehydrate")

    base_change_request = %{
      "external_id" => "change-1",
      "number" => 1,
      "url" => "https://fixture.invalid/change-1",
      "repository" => "acme/rehydrate",
      "head_branch" => "task/rehydrate",
      "base_branch" => "main",
      "title" => "Rehydrate",
      "draft" => true
    }

    for {provider, disposition} <- [{"github", "created"}, {"gitlab", "updated"}] do
      change_request =
        base_change_request
        |> Map.put("provider", provider)
        |> Map.put("disposition", disposition)

      assert {:ok, %Record{status: :succeeded}} =
               execute_fixture_effect(
                 "set_draft",
                 %{"config" => config, "change_request" => change_request, "draft" => false},
                 "rehydrate-#{provider}"
               )
    end

    invalid_intents = [
      %{"config" => config, "change_request" => "invalid", "draft" => false},
      %{
        "config" => config,
        "change_request" => Map.put(base_change_request, "provider", "unsupported"),
        "draft" => false
      },
      %{
        "config" => config,
        "change_request" =>
          base_change_request
          |> Map.put("provider", "fixture")
          |> Map.put("disposition", "unsupported"),
        "draft" => false
      }
    ]

    for {intent, index} <- Enum.with_index(invalid_intents) do
      assert {:error, :invalid_configuration} =
               execute_fixture_effect("set_draft", intent, "invalid-change-#{index}")
    end

    valid_change_request =
      base_change_request
      |> Map.put("provider", "fixture")
      |> Map.put("disposition", "reconciled")

    assert {:error, :invalid_configuration} =
             execute_fixture_effect(
               "close_or_comment",
               %{"config" => config, "change_request" => valid_change_request, "action" => "invalid"},
               "invalid-close-action"
             )
  end

  defp fixture_effect(operation_id, suffix) do
    %{
      operation_id: operation_id,
      task_id: "source-control-effect-#{suffix}",
      plan_revision: 1,
      unit_id: "integration",
      action: "ensure_change_request",
      provider: "ignored-caller-provider",
      target: "ignored-caller-target",
      intent: %{
        attrs: %{
          repo: %{
            provider: "fixture",
            settings: %{
              repository: "acme/#{suffix}",
              base_branch: "main"
            }
          },
          head: "task/#{suffix}",
          base: "main",
          title: "Deliver #{suffix}",
          body: "Durable source-control effect",
          draft: true
        }
      }
    }
  end

  defp provider_effect(operation_id, provider) do
    %{
      operation_id: operation_id,
      task_id: "#{provider}-unknown-create",
      plan_revision: 1,
      action: "ensure_change_request",
      provider: provider,
      target: "acme/unknown-create",
      intent: %{
        "attrs" => %{
          "repo" => %{
            "id" => "delivery-main",
            "provider" => provider,
            "credential_ref" => "00000000-0000-0000-0000-000000000001",
            "settings" => %{
              "repository" => "acme/unknown-create",
              "base_branch" => "main"
            }
          },
          "head" => "task/unknown-create",
          "base" => "main",
          "title" => "Unknown create",
          "body" => "Do not list or repost",
          "draft" => true
        }
      }
    }
  end

  defp execute_fixture_effect(action, intent, suffix) do
    SourceControl.execute_effect(%{
      operation_id: OperationId.generate(),
      task_id: "source-control-#{suffix}",
      plan_revision: 1,
      unit_id: "integration",
      action: action,
      intent: intent
    })
  end

  defp fixture_config(suffix) do
    %{
      "provider" => "fixture",
      "settings" => %{
        "repository" => "acme/#{suffix}",
        "base_branch" => "main"
      }
    }
  end

  defp pin_integrations(task_id, integrations) do
    document = %{"integrations" => integrations}

    assert {:ok, revision} =
             %Revision{}
             |> Revision.draft_changeset(%{
               document: document,
               schema_version: 1,
               content_hash: String.duplicate("a", 64),
               created_by: "test"
             })
             |> Repo.insert()

    assert {:ok, _pin} =
             %TaskPin{}
             |> TaskPin.changeset(%{
               task_id: task_id,
               revision_id: revision.id,
               content_hash: revision.content_hash,
               document: document,
               pinned_by: "test"
             })
             |> Repo.insert()
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
