defmodule SymphonyElixir.Configuration.ValidatorTest do
  use SymphonyElixir.DataCase, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Configuration.IntegrationProbe
  alias SymphonyElixir.Configuration.Validator
  alias SymphonyElixir.Runtime.CapabilityProbe
  alias SymphonyElixir.Security.SecretStore

  @plaintext "codex-provider-secret"

  defmodule FakeHealthAppServer do
    def start_session(_workspace, opts) do
      true = Keyword.fetch!(opts, :health_probe)
      binding = Keyword.fetch!(opts, :provider_binding)

      assert binding.endpoint == "http://127.0.0.1:4010"

      assert binding.model_id in [
               "gpt-5.6-routing",
               "gpt-5.6-routing-fallback",
               "gpt-5.6-execution-fallback",
               "gpt-5.6-task"
             ]

      assert binding.credential == "codex-provider-secret"

      {:ok, %{thread_id: "probe-thread"}}
    end

    def run_turn(%{thread_id: "probe-thread"}, _prompt, %{identifier: "runtime-capability-probe"}, opts) do
      true = Keyword.fetch!(opts, :health_probe)
      binding = Keyword.fetch!(opts, :provider_binding)
      assert binding.credential == "codex-provider-secret"

      {:ok, %{result: %{"task_type" => "general"}}}
    end

    def stop_session(%{thread_id: "probe-thread"}), do: :ok
  end

  defmodule FakeTrackerHealth do
    def health_check(%{
          "provider" => "github",
          "credential" => "tracker-health-secret",
          "webhook_secret" => "tracker-webhook-secret"
        }) do
      {:ok,
       %{
         provider: :github,
         status: :healthy,
         evidence: %{"scope" => "WangShayne/Symphony-works", "message" => "credential accepted"}
       }}
    end
  end

  defmodule SelectedTrackerHealth do
    def health_check(%{"id" => "tracker-selected", "project_integration_ref" => "tracker-selected"}) do
      Process.put({__MODULE__, :called}, ["tracker-selected" | Process.get({__MODULE__, :called}, [])])
      {:ok, %{status: :healthy, evidence: %{"selected" => true}}}
    end

    def health_check(%{"id" => id}) do
      Process.put({__MODULE__, :called}, [id | Process.get({__MODULE__, :called}, [])])
      {:error, %{"code" => "unselected_probe"}}
    end
  end

  defmodule FakeSourceControlHealth do
    def health_check(%{"provider" => "gitlab", "credential" => "source-control-health-secret"}) do
      {:ok,
       %{
         provider: :gitlab,
         status: :healthy,
         evidence: %{"base_branch" => "main", "message" => "credential accepted"}
       }}
    end
  end

  defmodule LeakyWebhookTrackerHealth do
    def health_check(%{"webhook_secret" => webhook_secret}) do
      {:error, %{"code" => "denied", "message" => webhook_secret}}
    end
  end

  defmodule RichIntegrationHealth do
    def health_check(%{"credential" => credential, "webhook_secret" => webhook_secret}) do
      {credential_ref, webhook_ref} = Process.get({__MODULE__, :references})

      {:ok,
       %{
         status: :healthy,
         nested: [
           credential_ref,
           %{tuple: {:secret_refs, webhook_ref, credential != webhook_secret}}
         ]
       }}
    end
  end

  defmodule AdversarialIntegrationHealth do
    def health_check(%{"credential" => credential, "webhook_secret" => webhook_secret}) do
      {:ok,
       %{
         "status" => "healthy",
         "credential #{credential}" => "bearer #{credential}",
         "nested" => [
           %{"webhook #{webhook_secret}" => "signed with #{webhook_secret}"},
           "combined #{credential}:#{webhook_secret}"
         ]
       }}
    end
  end

  defmodule InvalidIntegrationHealth do
    def health_check(_integration), do: :unexpected_health_result
  end

  defmodule InvalidOkIntegrationHealth do
    def health_check(_integration), do: {:ok, ["not", "a", "health", "map"]}
  end

  defmodule BinaryReasonIntegrationHealth do
    def health_check(%{"credential" => _credential}) do
      {credential_ref, _webhook_ref} = Process.get({RichIntegrationHealth, :references})
      {:error, "adapter denied #{credential_ref} #{String.duplicate("x", 180)}"}
    end
  end

  defmodule MapCodeIntegrationHealth do
    def health_check(%{"credential" => _credential}), do: {:error, %{"code" => "map_code"}}
  end

  defmodule AtomMapCodeIntegrationHealth do
    def health_check(%{"credential" => _credential}), do: {:error, %{code: :atom_map_code}}
  end

  defmodule TupleReasonIntegrationHealth do
    def health_check(%{"credential" => _credential}), do: {:error, {:tuple_code, %{details: true}}}
  end

  defmodule UnknownReasonIntegrationHealth do
    def health_check(%{"credential" => _credential}), do: {:error, ["unexpected"]}
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :configuration_probes)
    previous_health = Application.get_env(:symphony_elixir, :runtime_health_app_server)
    previous_integration_adapters = Application.get_env(:symphony_elixir, :integration_health_adapters)
    Application.put_env(:symphony_elixir, :configuration_probes, [])
    Application.put_env(:symphony_elixir, :runtime_health_app_server, FakeHealthAppServer)

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => FakeTrackerHealth,
      "source_control" => FakeSourceControlHealth
    })

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :configuration_probes, previous)
      Application.put_env(:symphony_elixir, :runtime_health_app_server, previous_health)
      Application.put_env(:symphony_elixir, :integration_health_adapters, previous_integration_adapters)
    end)
  end

  test "activation rejects runtime model credential references that do not resolve through the broker" do
    missing_reference = Ecto.UUID.generate()
    document = runtime_model_document(missing_reference)

    assert {:ok, draft} = Configuration.create_draft(document, actor: "admin")

    assert {:error, {:probe_failed, :credential_ref, evidence}} =
             Configuration.activate(draft.id, actor: "admin")

    assert evidence["status"] == "failed"
    assert evidence["reason"] == "not_found"
    assert evidence["credential_ref"] == "[REDACTED]"
    refute inspect(evidence) =~ missing_reference
  end

  test "activation runs default runtime capability probes and records redacted evidence" do
    assert {:ok, reference} = SecretStore.put("codex-provider-token", @plaintext, actor: "admin")
    document = runtime_model_document(reference.id)

    assert {:ok, draft} = Configuration.create_draft(document, actor: "admin")
    assert {:ok, active} = Configuration.activate(draft.id, actor: "admin")

    assert %{"probes" => [probe]} = active.validation_evidence
    assert probe["probe"] == "runtime_capability"
    assert probe["status"] == "passed"
    assert probe["provider_count"] == 1
    assert probe["model_count"] == 4
    assert [%{"runtime" => "codex", "status" => "passed"} | _] = probe["models"]

    encoded = Jason.encode!(active.validation_evidence)
    refute encoded =~ @plaintext
    refute encoded =~ reference.id
    refute encoded =~ "codex-provider-token"
    refute encoded =~ "api_key"
  end

  test "configuration mutations reject plaintext credential refs before persistence" do
    assert {:ok, reference} = SecretStore.put("codex-provider-token", @plaintext, actor: "admin")
    assert {:ok, draft} = Configuration.create_draft(runtime_model_document(reference.id), actor: "admin")

    unsafe_document = runtime_model_document("sk-plaintext-runtime-secret")

    assert {:error, {:invalid_credential_ref, evidence}} =
             Configuration.update_draft(draft.id, unsafe_document, actor: "admin")

    assert evidence["credential_ref"] == "[REDACTED]"
    assert evidence["reason"] == "invalid_reference"
    refute inspect(evidence) =~ "sk-plaintext-runtime-secret"

    reloaded = SymphonyElixir.Repo.get!(SymphonyElixir.Configuration.Revision, draft.id)
    refute inspect(reloaded.document) =~ "sk-plaintext-runtime-secret"
    assert inspect(reloaded.document) =~ reference.id
  end

  test "integration credential plaintext is rejected before a draft can persist it" do
    assert {:ok, api_reference} =
             SecretStore.put("github-tracker-api", "github-api-secret", actor: "admin")

    fixture_document =
      valid_project()
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "fixture-tracker",
          "kind" => "tracker",
          "provider" => "fixture",
          "settings" => %{"scenario" => "healthy"}
        }
      ])

    assert {:ok, draft} = Configuration.create_draft(fixture_document, actor: "admin")

    unsafe_document =
      Map.put(fixture_document, "integrations", [
        %{
          "id" => "github-tracker",
          "kind" => "tracker",
          "provider" => "github",
          "credential_ref" => "plaintext-secret",
          "settings" => %{"owner" => "WangShayne", "repository" => "Symphony-works"}
        }
      ])

    assert {:error, {:invalid_credential_ref, evidence}} =
             Configuration.update_draft(draft.id, unsafe_document, actor: "admin")

    assert evidence["credential_ref"] == "[REDACTED]"
    refute inspect(evidence) =~ "plaintext-secret"

    unsafe_webhook_document =
      Map.put(fixture_document, "integrations", [
        %{
          "id" => "github-tracker",
          "kind" => "tracker",
          "provider" => "github",
          "credential_ref" => api_reference.id,
          "settings" => %{
            "owner" => "WangShayne",
            "repository" => "Symphony-works",
            "webhook_secret_ref" => "1234567890abcdef"
          }
        }
      ])

    assert {:error, {:invalid_credential_ref, nested_evidence}} =
             Configuration.update_draft(draft.id, unsafe_webhook_document, actor: "admin")

    assert nested_evidence["credential_ref"] == "[REDACTED]"
    refute inspect(nested_evidence) =~ "1234567890abcdef"

    unsafe_field_document =
      Map.put(fixture_document, "integrations", [
        %{
          "id" => "fixture-tracker",
          "kind" => "tracker",
          "provider" => "fixture",
          "settings" => %{
            "scenario" => "healthy",
            "webhook_secret" => "raw-webhook-credential"
          }
        }
      ])

    assert {:error, {:invalid_credential_ref, field_evidence}} =
             Configuration.update_draft(draft.id, unsafe_field_document, actor: "admin")

    assert field_evidence["credential_ref"] == "[REDACTED]"
    assert field_evidence["reason"] == "plaintext_field"
    refute inspect(field_evidence) =~ "raw-webhook-credential"

    assert {:ok, exported} = Configuration.export(draft.id, redacted: true)
    refute inspect(exported) =~ "plaintext-secret"
    refute inspect(exported) =~ "1234567890abcdef"
    refute inspect(exported) =~ "raw-webhook-credential"
    assert inspect(exported) =~ "fixture-tracker"

    unsafe_transport_document =
      Map.put(fixture_document, "integrations", [
        %{
          "id" => "fixture-source-control",
          "kind" => "source_control",
          "provider" => "fixture",
          "settings" => %{
            "repository" => "WangShayne/Symphony-works",
            "base_branch" => "main",
            "Transport" => "runtime-only-transport"
          }
        }
      ])

    assert {:error, {:invalid_credential_ref, transport_evidence}} =
             Configuration.create_draft(unsafe_transport_document, actor: "admin")

    assert transport_evidence["reason"] == "plaintext_field"

    refute inspect(SymphonyElixir.Repo.all(SymphonyElixir.Configuration.Revision)) =~
             "runtime-only-transport"

    for {field, value} <- [
          {"Credential", "mixed-case-credential"},
          {"credentialRef", "camel-case-credential"},
          {"webhookSecret", "camel-case-webhook"},
          {"webhook-secret", "hyphen-webhook"},
          {"WEBHOOKSECRET", "uppercase-webhook"},
          {"Transport", "runtime-only-transport-alias"}
        ] do
      unsafe_alias_document =
        Map.put(fixture_document, "integrations", [
          %{
            "id" => "fixture-tracker",
            "kind" => "tracker",
            "provider" => "fixture",
            "settings" => Map.put(%{"scenario" => "healthy"}, field, value)
          }
        ])

      assert {:error, {:invalid_credential_ref, alias_evidence}} =
               Configuration.create_draft(unsafe_alias_document, actor: "admin")

      assert alias_evidence["reason"] == "plaintext_field"
      refute inspect(SymphonyElixir.Repo.all(SymphonyElixir.Configuration.Revision)) =~ value
    end
  end

  test "activation brokers integration credentials and stores only redacted health evidence" do
    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => FakeTrackerHealth,
      source_control: FakeSourceControlHealth
    })

    assert {:ok, tracker_reference} =
             SecretStore.put("tracker-health", "tracker-health-secret", actor: "admin")

    assert {:ok, webhook_reference} =
             SecretStore.put("tracker-webhook", "tracker-webhook-secret", actor: "admin")

    assert {:ok, source_control_reference} =
             SecretStore.put("source-control-health", "source-control-health-secret", actor: "admin")

    document =
      valid_project()
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "tracker-main",
          "kind" => "tracker",
          "provider" => "github",
          "credential_ref" => tracker_reference.id,
          "settings" => %{
            "owner" => "WangShayne",
            "repository" => "Symphony-works",
            "bot_actor_id" => "symphony-bot",
            "webhook_secret_ref" => webhook_reference.id
          }
        },
        %{
          "id" => "delivery-main",
          "kind" => "source_control",
          "provider" => "gitlab",
          "credential_ref" => source_control_reference.id,
          "settings" => %{
            "repository" => "WangShayne/Symphony-works",
            "base_branch" => "main",
            "bot_actor_id" => "31337"
          }
        }
      ])

    assert {:ok, draft} = Configuration.create_draft(document, actor: "admin")
    assert {:ok, active} = Configuration.activate(draft.id, actor: "admin")

    assert %{"probes" => [%{"probe" => "integrations"} = probe]} = active.validation_evidence
    assert probe["status"] == "passed"
    assert Enum.map(probe["integrations"], & &1["kind"]) == ["tracker", "source_control"]
    assert hd(probe["integrations"])["webhook_signing"] == "resolved"

    encoded = Jason.encode!(active.validation_evidence)
    refute encoded =~ "tracker-health-secret"
    refute encoded =~ "tracker-webhook-secret"
    refute encoded =~ "source-control-health-secret"
    refute encoded =~ tracker_reference.id
    refute encoded =~ webhook_reference.id
    refute encoded =~ source_control_reference.id
    refute encoded =~ "credential_ref"

    missing_webhook_reference = Ecto.UUID.generate()

    missing_webhook_document =
      put_in(
        document,
        ["integrations", Access.at(0), "settings", "webhook_secret_ref"],
        missing_webhook_reference
      )

    assert {:ok, missing_webhook_draft} =
             Configuration.create_draft(missing_webhook_document, actor: "admin")

    assert {:error, {:probe_failed, :integration, failed_evidence}} =
             Configuration.activate(missing_webhook_draft.id, actor: "admin")

    assert failed_evidence["integration"]["id"] == "tracker-main"
    assert failed_evidence["integration"]["reason"] == "not_found"
    refute Jason.encode!(failed_evidence) =~ missing_webhook_reference
    assert Configuration.active!().id == active.id

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => LeakyWebhookTrackerHealth,
      "source_control" => FakeSourceControlHealth
    })

    assert {:ok, leaky_draft} = Configuration.create_draft(document, actor: "admin")

    assert {:error, {:probe_failed, :integration, leaky_evidence}} =
             Configuration.activate(leaky_draft.id, actor: "admin")

    assert leaky_evidence["integration"]["reason"] == "denied"

    leaky_encoded = Jason.encode!(leaky_evidence)
    refute leaky_encoded =~ "tracker-health-secret"
    refute leaky_encoded =~ "tracker-webhook-secret"
    refute leaky_encoded =~ tracker_reference.id
    refute leaky_encoded =~ webhook_reference.id
    assert Configuration.active!().id == active.id
  end

  test "integration probe resolves and uses project-selected integration refs" do
    Process.put({SelectedTrackerHealth, :called}, [])

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => SelectedTrackerHealth
    })

    document =
      valid_project()
      |> Map.put("tracker_integration_ref", "tracker-selected")
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "tracker-unselected",
          "kind" => "tracker",
          "provider" => "fixture",
          "settings" => %{"scenario" => "unselected"}
        },
        %{
          "id" => "tracker-selected",
          "kind" => "tracker",
          "provider" => "fixture",
          "settings" => %{"scenario" => "healthy"}
        }
      ])

    assert {:ok, document} = Document.validate(document)
    assert {:ok, evidence} = Validator.validate(document)

    assert %{"probes" => [%{"integrations" => [selected]}]} = evidence
    assert selected["id"] == "tracker-selected"
    assert selected["project_integration_ref"] == "tracker-selected"
    assert Process.get({SelectedTrackerHealth, :called}) == ["tracker-selected"]
  end

  test "integration probe scrubs adversarial plaintext health evidence before persistence or logs" do
    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => AdversarialIntegrationHealth
    })

    assert {:ok, tracker_reference} =
             SecretStore.put("tracker-adversarial", "tracker-adversarial-secret", actor: "admin")

    assert {:ok, webhook_reference} =
             SecretStore.put("tracker-webhook-adversarial", "webhook-adversarial-secret", actor: "admin")

    document =
      valid_project()
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "tracker-adversarial",
          "kind" => "tracker",
          "provider" => "github",
          "credential_ref" => tracker_reference.id,
          "settings" => %{
            "owner" => "WangShayne",
            "repository" => "Symphony-works",
            "bot_actor_id" => "symphony-bot",
            "webhook_secret_ref" => webhook_reference.id
          }
        }
      ])

    assert {:ok, draft} = Configuration.create_draft(document, actor: "admin")

    log =
      capture_log(fn ->
        assert {:ok, active} = Configuration.activate(draft.id, actor: "admin")
        persisted = SymphonyElixir.Repo.get!(SymphonyElixir.Configuration.Revision, active.id)
        encoded = Jason.encode!(persisted.validation_evidence)

        assert encoded =~ "[REDACTED]"
        refute encoded =~ "tracker-adversarial-secret"
        refute encoded =~ "webhook-adversarial-secret"
        refute encoded =~ tracker_reference.id
        refute encoded =~ webhook_reference.id
      end)

    refute log =~ "tracker-adversarial-secret"
    refute log =~ "webhook-adversarial-secret"
  end

  test "validator ignores invalid extra probe configuration" do
    document = valid_project() |> Document.for_project()

    assert {:ok, %{"probes" => []}} = Validator.validate(document, probes: :invalid)
  end

  test "integration probe validates malformed documents and redacts rich adapter evidence" do
    assert IntegrationProbe.configured?(:not_a_document) == false

    assert {:ok, %{"integration_count" => 0, "integrations" => []}} =
             IntegrationProbe.validate(:not_a_document)

    assert {:ok, %{"integration_count" => 0, "integrations" => []}} =
             IntegrationProbe.validate(%{"automation_projects" => [:not_a_project], "integrations" => []})

    assert {:ok, tracker_reference} =
             SecretStore.put("tracker-health-rich", "tracker-rich-secret", actor: "admin")

    assert {:ok, webhook_reference} =
             SecretStore.put("tracker-webhook-rich", "webhook-rich-secret", actor: "admin")

    document =
      valid_project()
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "tracker-rich",
          "kind" => "tracker",
          "provider" => "github",
          "credential_ref" => tracker_reference.id,
          "settings" => %{
            "owner" => "WangShayne",
            "repository" => "Symphony-works",
            "bot_actor_id" => "symphony-bot",
            "webhook_secret_ref" => webhook_reference.id
          }
        }
      ])

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => RichIntegrationHealth
    })

    Process.put({RichIntegrationHealth, :references}, {tracker_reference.id, webhook_reference.id})

    assert {:ok, %{"integrations" => [%{"health" => health}]}} = IntegrationProbe.validate(document)
    encoded = inspect(health)
    assert encoded =~ "[REDACTED]"
    refute encoded =~ tracker_reference.id
    refute encoded =~ webhook_reference.id
    refute encoded =~ "tracker-rich-secret"
    refute encoded =~ "webhook-rich-secret"

    invalid_result_document =
      valid_project()
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "fixture-invalid",
          "kind" => "tracker",
          "provider" => "fixture",
          "settings" => %{"scenario" => "healthy"}
        }
      ])

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => InvalidIntegrationHealth
    })

    assert {:error, {:integration, %{"integration" => failed}}} =
             IntegrationProbe.validate(invalid_result_document)

    assert failed["reason"] == "invalid_health_result"

    invalid_non_fixture_document =
      valid_project()
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "tracker-invalid",
          "kind" => "tracker",
          "provider" => "github",
          "credential_ref" => tracker_reference.id,
          "settings" => %{
            "owner" => "WangShayne",
            "repository" => "Symphony-works",
            "bot_actor_id" => "symphony-bot",
            "webhook_secret_ref" => webhook_reference.id
          }
        }
      ])

    assert {:error, {:integration, %{"integration" => non_fixture_failed}}} =
             IntegrationProbe.validate(invalid_non_fixture_document)

    assert non_fixture_failed["reason"] == "invalid_health_result"

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => InvalidOkIntegrationHealth
    })

    assert {:error, {:integration, %{"integration" => ok_non_map_failed}}} =
             IntegrationProbe.validate(invalid_non_fixture_document)

    assert ok_non_map_failed["reason"] == "invalid_health_result"

    for {adapter, expected_reason} <- [
          {BinaryReasonIntegrationHealth, "adapter denied [REDACTED]"},
          {MapCodeIntegrationHealth, "map_code"},
          {AtomMapCodeIntegrationHealth, "atom_map_code"},
          {TupleReasonIntegrationHealth, "tuple_code"},
          {UnknownReasonIntegrationHealth, "health_check_failed"}
        ] do
      Application.put_env(:symphony_elixir, :integration_health_adapters, %{
        "tracker" => adapter
      })

      assert {:error, {:integration, %{"integration" => failed}}} =
               IntegrationProbe.validate(document)

      assert failed["reason"] =~ expected_reason
      refute failed["reason"] =~ tracker_reference.id
      refute failed["reason"] =~ "tracker-rich-secret"
      assert String.length(failed["reason"]) <= 120
    end
  end

  test "runtime capability probe rejects unsupported and malformed provider bindings with redacted evidence" do
    assert CapabilityProbe.configured?(%{}) == false
    assert {:ok, %{"provider_count" => 0, "model_count" => 0}} = CapabilityProbe.validate(%{})

    assert {:ok, reference} = SecretStore.put("codex-provider-token", @plaintext, actor: "admin")
    document = runtime_model_document(reference.id)

    unsupported_provider =
      put_in(document, ["providers", Access.at(0), "runtime_protocol"], "chat_api")

    assert {:error, {:model_provider, unsupported_evidence}} = CapabilityProbe.validate(unsupported_provider)
    assert unsupported_evidence["reason"] == "unsupported_runtime_protocol"

    missing_provider =
      put_in(document, ["model_references", Access.at(0), "provider_id"], "missing-provider")

    assert {:error, {:model_provider, missing_provider_evidence}} = CapabilityProbe.validate(missing_provider)
    assert missing_provider_evidence["reason"] == "provider_not_found"

    malformed_provider =
      put_in(document, ["model_references", Access.at(0), "provider_id"], nil)

    assert {:error, {:model_provider, malformed_provider_evidence}} = CapabilityProbe.validate(malformed_provider)
    assert malformed_provider_evidence["reason"] == "provider_not_found"

    missing_prices =
      update_in(document, ["model_references", Access.at(0)], &Map.delete(&1, "prices"))

    assert {:error, {:model_provider, price_evidence}} = CapabilityProbe.validate(missing_prices)
    assert price_evidence["reason"] == "failed"

    unavailable_structured_output =
      put_in(document, ["model_references", Access.at(0), "capabilities", "structured_output"], false)

    assert {:error, {:model_provider, capability_evidence}} = CapabilityProbe.validate(unavailable_structured_output)
    assert capability_evidence["reason"] == "structured_output_unavailable"

    encoded = Jason.encode!([unsupported_evidence, missing_provider_evidence, price_evidence, capability_evidence])
    refute encoded =~ @plaintext
    refute encoded =~ reference.id
    refute encoded =~ "api_key"
  end

  defp runtime_model_document(credential_ref) do
    valid_project()
    |> Document.for_project()
    |> Map.put("providers", [
      %{
        "id" => "codex-provider",
        "name" => "Codex Provider",
        "runtime_protocol" => "codex_app_server",
        "endpoint" => "http://127.0.0.1:4010",
        "credential_ref" => credential_ref
      }
    ])
    |> Map.put("model_references", [
      runtime_model_reference("routing-model", "gpt-5.6-routing", credential_ref),
      runtime_model_reference("routing-fallback-model", "gpt-5.6-routing-fallback", credential_ref),
      runtime_model_reference("execution-fallback-model", "gpt-5.6-execution-fallback", credential_ref),
      runtime_model_reference("task-model", "gpt-5.6-task", credential_ref)
    ])
    |> Map.put("routing", %{
      "model_reference_id" => "routing-model",
      "fallback_model_reference_id" => "routing-fallback-model",
      "execution_fallback_model_reference_id" => "execution-fallback-model",
      "profile" => %{
        "id" => "routing-profile",
        "runtime" => "codex",
        "readonly" => true,
        "allow_mutation" => false,
        "high_risk_tools" => false,
        "required_capabilities" => %{
          "structured_output" => true,
          "tool_use" => true,
          "context_window" => 64_000
        }
      }
    })
    |> Map.put("execution_profiles", [
      %{
        "id" => "general-profile",
        "name" => "General",
        "runtime" => "codex",
        "model_reference_id" => "task-model",
        "instructions" => "Implement the accepted task.",
        "required_capabilities" => %{
          "structured_output" => true,
          "tool_use" => true,
          "context_window" => 64_000
        }
      }
    ])
  end

  defp runtime_model_reference(id, model_id, credential_ref) do
    %{
      "id" => id,
      "provider_id" => "codex-provider",
      "endpoint" => "http://127.0.0.1:4010",
      "model_id" => model_id,
      "credential_ref" => credential_ref,
      "context_window" => 128_000,
      "capabilities" => %{
        "structured_output" => true,
        "tool_use" => true,
        "context_window" => 128_000
      },
      "prices" => %{"input" => 0, "cached_input" => 0, "output" => 0}
    }
  end

  defp valid_project do
    %{
      "id" => "symphony",
      "name" => "Symphony",
      "tracker" => %{"kind" => "github", "scope" => "WangShayne/Symphony-works"},
      "repository" => %{
        "url" => "git@github.com:WangShayne/Symphony-works.git",
        "target_branch" => "main"
      }
    }
  end
end
