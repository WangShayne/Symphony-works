defmodule SymphonyElixir.Configuration.ValidatorTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document
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

  setup do
    previous = Application.get_env(:symphony_elixir, :configuration_probes)
    previous_health = Application.get_env(:symphony_elixir, :runtime_health_app_server)
    Application.put_env(:symphony_elixir, :configuration_probes, [])
    Application.put_env(:symphony_elixir, :runtime_health_app_server, FakeHealthAppServer)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :configuration_probes, previous)
      Application.put_env(:symphony_elixir, :runtime_health_app_server, previous_health)
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
