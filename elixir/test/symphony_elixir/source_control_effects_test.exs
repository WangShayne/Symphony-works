defmodule SymphonyElixir.SourceControlEffectsTest do
  use SymphonyElixir.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Configuration
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

  defmodule CaptureSourceControl do
    def ensure_change_request(attrs, _opts) do
      send(
        Application.fetch_env!(:symphony_elixir, :source_control_effect_capture_pid),
        {:source_control_invocation, attrs}
      )

      repo = get_in(attrs, ["repo"])

      {:ok,
       %{
         "provider" => repo["provider"],
         "repository" => get_in(repo, ["settings", "repository"])
       }}
    end

    def ensure_remote_branch(config, _branch, _opts),
      do: capture_config("ensure_remote_branch", config)

    def push_branch(config, _branch, _commit_sha, _opts),
      do: capture_config("push_branch", config)

    def set_draft(config, _change_request, _opts),
      do: capture_config("set_draft", config)

    def close_or_comment(config, _change_request, _opts),
      do: capture_config("close_or_comment", config)

    defp capture_config(action, config) do
      send(
        Application.fetch_env!(:symphony_elixir, :source_control_effect_capture_pid),
        {:source_control_config, action, config}
      )

      {:ok,
       %{
         "action" => action,
         "provider" => config["provider"],
         "repository" => get_in(config, ["settings", "repository"])
       }}
    end
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

  test "fixture recovery rebuilds the invocation from the complete pinned integration" do
    capture_source_control()

    operation_id = OperationId.generate()
    task_id = "fixture-pinned-recovery-#{System.unique_integer([:positive])}"

    pinned =
      source_control_integration("fixture", nil, %{
        "scenario" => "pinned-recovery",
        "endpoint_trusted_origins" => ["https://pinned.fixture.test"],
        "remote" => "pinned-origin"
      })

    current =
      source_control_integration("fixture", nil, %{
        "scenario" => "current-recovery",
        "endpoint_trusted_origins" => ["https://current.fixture.test"],
        "remote" => "current-origin"
      })

    pin_integrations(task_id, [pinned])

    attrs =
      operation_id
      |> provider_effect("fixture")
      |> Map.put(:task_id, task_id)
      |> put_in([:intent, "attrs", "repo"], current)

    assert {:ok, prepared} = EffectAdapter.prepare(attrs)
    assert {:error, :unknown_outcome} = Effects.execute(prepared, UnknownOutcomeAdapter)

    assert {:ok, %Record{status: :succeeded}} =
             Effects.reconcile(operation_id, EffectAdapter)

    assert_receive {:source_control_invocation, %{"repo" => invoked}}
    assert invoked == Map.delete(pinned, "credential_ref")
  end

  test "GitHub and GitLab create unknown outcomes remain unknown without list or repost" do
    capture_source_control()

    for provider <- ["github", "gitlab"] do
      operation_id = OperationId.generate()
      attrs = provider_effect(operation_id, provider)
      assert {:ok, prepared} = EffectAdapter.prepare(attrs)

      assert {:error, :unknown_outcome} = Effects.execute(prepared, UnknownOutcomeAdapter)

      assert {:error, :change_request_reconciliation_required} =
               SourceControl.execute_effect(attrs)

      assert {:error, :change_request_reconciliation_required} =
               SourceControl.execute_effect(attrs)

      assert %Record{
               status: :unknown,
               error: %{"code" => "change_request_reconciliation_required"}
             } = Effects.get!(operation_id)
    end

    refute_receive {:source_control_invocation, _attrs}
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

  test "execution uses the complete pinned integration without persisting credential material" do
    capture_source_control()

    pinned_secret = "pinned-token-#{System.unique_integer([:positive])}"
    current_secret = "current-token-#{System.unique_integer([:positive])}"

    assert {:ok, pinned_reference} =
             SecretStore.put("pinned-source-control", pinned_secret, actor: "test")

    assert {:ok, current_reference} =
             SecretStore.put("current-source-control", current_secret, actor: "test")

    pinned_reference_id = SecretStore.export_reference(pinned_reference)
    current_reference_id = SecretStore.export_reference(current_reference)
    task_id = "pinned-source-control-#{System.unique_integer([:positive])}"

    pinned_integration =
      source_control_integration("github", pinned_reference_id, %{
        "api_base_url" => "https://pinned.example.test/api/v3",
        "endpoint_trusted_origins" => ["https://pinned.example.test"],
        "bot_actor_id" => "pinned-bot",
        "remote" => "pinned-origin"
      })

    current_integration =
      source_control_integration("github", current_reference_id, %{
        "api_base_url" => "https://current.example.test/api/v3",
        "endpoint_trusted_origins" => ["https://current.example.test"],
        "bot_actor_id" => "current-bot",
        "remote" => "current-origin"
      })

    pin_integrations(task_id, [pinned_integration])

    operation_id = OperationId.generate()

    attrs =
      provider_effect(operation_id, "github")
      |> Map.put(:task_id, task_id)
      |> put_in([:intent, "attrs", "repo"], current_integration)

    log =
      capture_log(fn ->
        assert {:ok, %Record{status: :succeeded}} = SourceControl.execute_effect(attrs)
      end)

    assert_receive {:source_control_invocation, %{"repo" => invoked_integration}}

    assert invoked_integration["settings"] == pinned_integration["settings"]
    assert invoked_integration["credential"] == pinned_secret
    refute Map.has_key?(invoked_integration, "credential_ref")
    refute inspect(invoked_integration) =~ current_secret

    persisted =
      [Effects.get!(operation_id), Effects.list(task_id: task_id)]
      |> inspect(limit: :infinity, printable_limit: :infinity)

    for sensitive <- [
          pinned_secret,
          current_secret,
          pinned_reference_id,
          current_reference_id,
          "https://pinned.example.test/api/v3",
          "https://pinned.example.test",
          "pinned-bot",
          "pinned-origin",
          "https://current.example.test/api/v3",
          "https://current.example.test",
          "current-bot",
          "current-origin"
        ] do
      refute persisted =~ sensitive
      refute log =~ sensitive
    end
  end

  test "branch, push, draft, and close mutations all use the complete pinned integration" do
    capture_source_control()

    pinned_secret = "pinned-all-actions-#{System.unique_integer([:positive])}"

    assert {:ok, reference} =
             SecretStore.put("pinned-all-actions", pinned_secret, actor: "test")

    reference_id = SecretStore.export_reference(reference)
    task_id = "pinned-all-actions-#{System.unique_integer([:positive])}"

    pinned =
      source_control_integration("github", reference_id, %{
        "api_base_url" => "https://pinned-actions.example.test/api/v3",
        "endpoint_trusted_origins" => ["https://pinned-actions.example.test"],
        "bot_actor_id" => "pinned-actions-bot",
        "remote" => "pinned-actions-origin"
      })

    current =
      source_control_integration("github", Ecto.UUID.generate(), %{
        "api_base_url" => "https://current-actions.example.test/api/v3",
        "endpoint_trusted_origins" => ["https://current-actions.example.test"],
        "bot_actor_id" => "current-actions-bot",
        "remote" => "current-actions-origin"
      })

    pin_integrations(task_id, [pinned])

    change_request =
      %{
        "provider" => "github",
        "external_id" => "change-1",
        "number" => 1,
        "url" => "https://github.example.test/acme/unknown-create/pull/1",
        "repository" => "acme/unknown-create",
        "head_branch" => "task/all-actions",
        "base_branch" => "main",
        "title" => "All actions",
        "draft" => true,
        "disposition" => "created"
      }
      |> with_change_request_identity()

    old_sha = String.duplicate("1", 40)
    new_sha = String.duplicate("2", 40)

    intents = [
      {"ensure_remote_branch", %{"config" => current, "branch" => %{"name" => "task/all-actions", "commit_sha" => old_sha}}},
      {"push_branch",
       %{
         "config" => current,
         "branch" => "task/all-actions",
         "commit_sha" => new_sha,
         "expected_remote_sha" => old_sha
       }},
      {"set_draft", %{"config" => current, "change_request" => change_request, "draft" => false}},
      {"close_or_comment",
       %{
         "config" => current,
         "change_request" => change_request,
         "action" => "comment",
         "body" => "Pinned progress"
       }}
    ]

    Enum.each(intents, fn {action, intent} ->
      operation_id = OperationId.generate()

      assert {:ok, %Record{status: :succeeded}} =
               SourceControl.execute_effect(%{
                 operation_id: operation_id,
                 task_id: task_id,
                 plan_revision: 1,
                 unit_id: "integration",
                 action: action,
                 intent: intent
               })

      assert_receive {:source_control_config, ^action, invoked}
      assert invoked["settings"] == pinned["settings"]
      assert invoked["credential"] == pinned_secret
      refute Map.has_key?(invoked, "credential_ref")

      persisted =
        [Effects.get!(operation_id), Effects.list(task_id: task_id)]
        |> inspect(limit: :infinity, printable_limit: :infinity)

      for runtime_only <- [
            "https://pinned-actions.example.test/api/v3",
            "https://pinned-actions.example.test",
            "pinned-actions-bot",
            "pinned-actions-origin",
            "https://current-actions.example.test/api/v3",
            "https://current-actions.example.test",
            "current-actions-bot",
            "current-actions-origin"
          ] do
        refute persisted =~ runtime_only
      end
    end)
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

  test "change request follow-up actions reject descriptors outside the pinned integration" do
    capture_source_control()

    assert {:ok, github_reference} =
             SecretStore.put("cr-provider-github", "github-cr-token", actor: "test")

    assert {:ok, gitlab_reference} =
             SecretStore.put("cr-provider-gitlab", "gitlab-cr-token", actor: "test")

    github =
      source_control_integration("github", SecretStore.export_reference(github_reference), %{
        "repository" => "acme/provider-fence",
        "base_branch" => "main"
      })

    gitlab =
      source_control_integration("gitlab", SecretStore.export_reference(gitlab_reference), %{
        "repository" => "acme/provider-fence",
        "base_branch" => "main"
      })

    valid_github_change_request =
      %{
        "provider" => "github",
        "external_id" => "github-change-1",
        "number" => 1,
        "url" => "https://example.test/acme/provider-fence/change/1",
        "repository" => "acme/provider-fence",
        "head_branch" => "task/provider-fence",
        "base_branch" => "main",
        "title" => "Provider fence",
        "draft" => true,
        "disposition" => "created"
      }
      |> with_change_request_identity()

    valid_gitlab_change_request =
      %{
        "provider" => "gitlab",
        "external_id" => "gitlab-change-1",
        "number" => 1,
        "url" => "https://example.test/acme/provider-fence/merge_requests/1",
        "repository" => "acme/provider-fence",
        "head_branch" => "task/provider-fence",
        "base_branch" => "main",
        "title" => "Provider fence",
        "draft" => true,
        "disposition" => "created"
      }
      |> with_change_request_identity()

    legacy_change_request = %{
      "provider" => "github",
      "external_id" => "change-1",
      "number" => 1,
      "url" => "https://example.test/acme/provider-fence/change/1",
      "repository" => "acme/provider-fence",
      "head_branch" => "task/provider-fence",
      "base_branch" => "main",
      "title" => "Provider fence",
      "draft" => true,
      "disposition" => "created"
    }

    scenarios = [
      {"github-config-gitlab-cr", github, Map.put(valid_github_change_request, "provider", "gitlab")},
      {"gitlab-config-github-cr", gitlab, valid_github_change_request},
      {"repository-mismatch", github, Map.put(valid_github_change_request, "repository", "acme/other")},
      {"base-branch-mismatch", github, Map.put(valid_github_change_request, "base_branch", "develop")},
      {"github-empty-external-id", github,
       valid_github_change_request
       |> Map.put("external_id", "")
       |> with_change_request_identity()},
      {"github-external-id-mismatch", github, Map.put(valid_github_change_request, "external_id", "github-change-2")},
      {"github-zero-number", github,
       valid_github_change_request
       |> Map.put("number", 0)
       |> with_change_request_identity()},
      {"github-nil-number", github,
       valid_github_change_request
       |> Map.put("number", nil)
       |> with_change_request_identity()},
      {"github-number-mismatch", github, Map.put(valid_github_change_request, "number", 2)},
      {"github-missing-identity", github, legacy_change_request},
      {"gitlab-external-id-mismatch", gitlab, Map.put(valid_gitlab_change_request, "external_id", "gitlab-change-2")},
      {"gitlab-number-mismatch", gitlab, Map.put(valid_gitlab_change_request, "number", 2)}
    ]

    for {suffix, config, change_request} <- scenarios,
        {action, intent} <- [
          {"set_draft", %{"config" => config, "change_request" => change_request, "draft" => false}},
          {"close_or_comment",
           %{
             "config" => config,
             "change_request" => change_request,
             "action" => "comment",
             "body" => "Provider fence"
           }}
        ] do
      task_id = "source-control-cr-fence-#{suffix}-#{action}"
      pin_integrations(task_id, [config])

      attrs = %{
        operation_id: OperationId.generate(),
        task_id: task_id,
        plan_revision: 1,
        unit_id: "integration",
        action: action,
        intent: intent
      }

      assert {:error, :invalid_configuration} = SourceControl.execute_effect(attrs)
      assert {:error, :invalid_configuration} = SourceControl.execute_effect(attrs)

      refute_receive {:source_control_config, ^action, _config}, 0
      refute_receive {:source_control_invocation, _attrs}, 0
    end
  end

  test "effect preparation validates and canonicalizes the persisted boundary" do
    valid = fixture_effect(OperationId.generate(), "canonical")

    atom_input =
      valid
      |> Map.put(:action, :ensure_change_request)
      |> put_in([:intent, :attrs, :repo, "provider"], :fixture)
      |> put_in([:intent, :metadata], [:one, :two])

    assert {:ok, prepared} = EffectAdapter.prepare(atom_input)
    refute Map.has_key?(prepared.intent, "metadata")
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
             |> put_in([:intent, :attrs, :repo, "provider"], "unsupported")
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, "provider"], 123)
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, "settings", "repository"], "  ")
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, "settings"], nil)
             |> EffectAdapter.prepare()

    assert {:error, :invalid_effect} =
             valid
             |> put_in([:intent, :attrs, :repo, "settings"], "not-a-map")
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
    pin_integrations(invalid_with_reference.task_id, [Map.put(repo, "kind", "source_control")])

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

  test "pinned credential brokering rejects unresolved references" do
    attrs =
      OperationId.generate()
      |> provider_effect("github")
      |> Map.put(:task_id, "missing-pinned-secret")

    pinned =
      attrs
      |> get_in([:intent, "attrs", "repo"])
      |> Map.put("kind", "source_control")

    pin_integrations(attrs.task_id, [pinned])

    assert {:error, :not_found} = SourceControl.execute_effect(attrs)
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

  test "missing, ambiguous, and mismatched pinned integrations fail before external invocation" do
    capture_source_control()

    assert {:ok, reference_a} = SecretStore.put("pinned-a", "pinned-a-token", actor: "test")
    assert {:ok, reference_b} = SecretStore.put("pinned-b", "pinned-b-token", actor: "test")
    reference_a = SecretStore.export_reference(reference_a)
    reference_b = SecretStore.export_reference(reference_b)

    valid = source_control_integration("github", reference_a, %{})

    scenarios = [
      {"missing-integration", []},
      {"malformed-integrations", "not-a-list"},
      {"malformed-integration-entry", ["ignored", valid]},
      {"ambiguous-integration", [valid, Map.put(valid, "credential_ref", reference_b)]},
      {"wrong-kind", [Map.put(valid, "kind", "tracker")]},
      {"wrong-provider", [Map.put(valid, "provider", "gitlab")]},
      {"wrong-target", [put_in(valid, ["settings", "repository"], "acme/other")]}
    ]

    pinned_scenarios =
      Enum.map(scenarios, fn {suffix, integrations} ->
        attrs =
          OperationId.generate()
          |> provider_effect("github")
          |> Map.put(:task_id, "pinned-fail-closed-#{suffix}")

        pin_integrations(attrs.task_id, integrations)
        attrs
      end)

    missing_pin =
      OperationId.generate()
      |> provider_effect("github")
      |> Map.put(:task_id, "pinned-fail-closed-missing-pin")

    missing_id =
      OperationId.generate()
      |> provider_effect("github")
      |> Map.put(:task_id, "pinned-fail-closed-missing-id")
      |> update_in([:intent, "attrs", "repo"], &Map.delete(&1, "id"))

    pin_integrations(missing_id.task_id, [valid])

    mismatched_pin =
      OperationId.generate()
      |> provider_effect("github")
      |> Map.put(:task_id, "pinned-fail-closed-hash-mismatch")

    pin_integrations(mismatched_pin.task_id, [valid], pin_content_hash: String.duplicate("b", 64))

    rejected = pinned_scenarios ++ [missing_pin, missing_id, mismatched_pin]

    log =
      capture_log(fn ->
        Enum.each(rejected, fn attrs ->
          assert {:error, :missing_credential_reference} =
                   SourceControl.execute_effect(attrs)

          refute_receive {:source_control_invocation, _attrs}, 0
        end)
      end)

    refute_receive {:source_control_invocation, _attrs}
    refute log =~ reference_a
    refute log =~ reference_b
  end

  test "pinned revision lookup fails closed when its registry is unavailable" do
    capture_source_control()

    assert {:error, :not_found} = Configuration.pinned_revision_for_task(nil)

    assert {:ok, _result} =
             SQL.query(
               Repo,
               "alter table configuration_task_pins rename to unavailable_configuration_task_pins",
               []
             )

    attrs =
      OperationId.generate()
      |> provider_effect("github")
      |> Map.put(:task_id, "unavailable-pinned-revision-registry")

    assert {:error, :missing_credential_reference} = SourceControl.execute_effect(attrs)
    refute_receive {:source_control_invocation, _attrs}
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

    for disposition <- ["created", "updated"] do
      change_request =
        base_change_request
        |> Map.put("provider", "fixture")
        |> Map.put("disposition", disposition)

      assert {:ok, %Record{status: :succeeded}} =
               execute_fixture_effect(
                 "set_draft",
                 %{"config" => config, "change_request" => change_request, "draft" => false},
                 "rehydrate-#{disposition}"
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

    config_without_base_branch = update_in(config, ["settings"], &Map.delete(&1, "base_branch"))

    assert {:ok, %Record{status: :succeeded}} =
             execute_fixture_effect(
               "set_draft",
               %{
                 "config" => config_without_base_branch,
                 "change_request" => Map.put(valid_change_request, "base_branch", "release"),
                 "draft" => false
               },
               "rehydrate-without-base-branch"
             )

    assert {:error, :invalid_configuration} =
             execute_fixture_effect(
               "close_or_comment",
               %{"config" => config, "change_request" => valid_change_request, "action" => "invalid"},
               "invalid-close-action"
             )
  end

  defp fixture_effect(operation_id, suffix) do
    task_id = "source-control-effect-#{suffix}"
    integration = fixture_config(suffix)
    pin_integrations(task_id, [integration])

    %{
      operation_id: operation_id,
      task_id: task_id,
      plan_revision: 1,
      unit_id: "integration",
      action: "ensure_change_request",
      provider: "ignored-caller-provider",
      target: "ignored-caller-target",
      intent: %{
        attrs: %{
          repo: integration,
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
    task_id = "source-control-#{suffix}"
    pin_integrations(task_id, [Map.fetch!(intent, "config")])

    SourceControl.execute_effect(%{
      operation_id: OperationId.generate(),
      task_id: task_id,
      plan_revision: 1,
      unit_id: "integration",
      action: action,
      intent: intent
    })
  end

  defp fixture_config(suffix) do
    source_control_integration("fixture", nil, %{
      "repository" => "acme/#{suffix}",
      "base_branch" => "main"
    })
  end

  defp source_control_integration(provider, credential_ref, settings) do
    integration = %{
      "id" => "delivery-main",
      "kind" => "source_control",
      "provider" => provider,
      "settings" =>
        Map.merge(
          %{
            "repository" => "acme/unknown-create",
            "base_branch" => "main"
          },
          settings
        )
    }

    if credential_ref,
      do: Map.put(integration, "credential_ref", credential_ref),
      else: integration
  end

  defp with_change_request_identity(change_request) do
    Map.put(change_request, "identity_sha256", change_request_identity_hash(change_request))
  end

  defp change_request_identity_hash(change_request) do
    [
      "v1",
      Map.fetch!(change_request, "provider"),
      Map.fetch!(change_request, "repository"),
      Map.fetch!(change_request, "external_id"),
      Map.fetch!(change_request, "number"),
      Map.fetch!(change_request, "head_branch"),
      Map.fetch!(change_request, "base_branch")
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp capture_source_control do
    previous_invoker = Application.get_env(:symphony_elixir, :source_control_effect_invoker)
    previous_capture_pid = Application.get_env(:symphony_elixir, :source_control_effect_capture_pid)

    Application.put_env(
      :symphony_elixir,
      :source_control_effect_invoker,
      CaptureSourceControl
    )

    Application.put_env(:symphony_elixir, :source_control_effect_capture_pid, self())

    on_exit(fn ->
      restore_env(:source_control_effect_invoker, previous_invoker)
      restore_env(:source_control_effect_capture_pid, previous_capture_pid)
    end)
  end

  defp pin_integrations(task_id, integrations, opts \\ []) do
    document = %{"integrations" => integrations}
    revision_content_hash = String.duplicate("a", 64)
    pin_content_hash = Keyword.get(opts, :pin_content_hash, revision_content_hash)

    assert {:ok, revision} =
             %Revision{}
             |> Revision.draft_changeset(%{
               document: document,
               schema_version: 1,
               content_hash: revision_content_hash,
               created_by: "test"
             })
             |> Repo.insert()

    assert {:ok, _pin} =
             %TaskPin{}
             |> TaskPin.changeset(%{
               task_id: task_id,
               revision_id: revision.id,
               content_hash: pin_content_hash,
               document: document,
               pinned_by: "test"
             })
             |> Repo.insert()
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
