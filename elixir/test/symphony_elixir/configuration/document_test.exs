defmodule SymphonyElixir.Configuration.DocumentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Configuration.Document

  test "rejects values that are not JSON objects" do
    assert {:error, [%{path: [], message: "configuration must be a JSON object"}]} =
             Document.validate("not-an-object")
  end

  test "reports missing schema version and Automation Projects" do
    assert {:error, errors} = Document.validate(%{})
    assert %{path: ["schema_version"], message: "must equal 1"} in errors

    assert %{path: ["automation_projects"], message: "must contain exactly one project"} in errors
  end

  test "reports non-object projects and every missing required field" do
    assert {:error, [%{path: ["automation_projects", "0"], message: "must be an object"}]} =
             valid_project()
             |> Document.for_project()
             |> Map.put("automation_projects", ["bad"])
             |> Document.validate()

    assert {:error, errors} =
             valid_project()
             |> Document.for_project()
             |> Map.put("automation_projects", [%{}])
             |> Document.validate()

    assert length(errors) == 6
    assert Enum.all?(errors, &(&1.message == "is required"))
  end

  test "requires the complete bootstrap document and rejects unsupported fields" do
    document = Document.for_project(valid_project())
    assert {:ok, ^document} = Document.validate(document)

    sanitized =
      valid_project()
      |> Map.put("api_token", "must-not-persist")
      |> put_in(["tracker", "api_token"], "must-not-persist")
      |> Document.for_project()

    [sanitized_project] = sanitized["automation_projects"]
    refute Map.has_key?(sanitized_project, "api_token")
    refute Map.has_key?(sanitized_project["tracker"], "api_token")

    assert {:error, missing_errors} = Document.validate(Map.delete(document, "model_references"))

    assert %{path: ["model_references"], message: "is required"} in missing_errors

    assert {:error, typed_errors} = Document.validate(Map.put(document, "providers", %{}))
    assert %{path: ["providers"], message: "must be a list"} in typed_errors

    assert {:error, populated_errors} =
             Document.validate(Map.put(document, "model_references", ["future"]))

    assert %{path: ["model_references", "0"], message: "must be an object"} in populated_errors

    assert {:error, routing_errors} = Document.validate(Map.put(document, "routing", %{"kind" => "x"}))
    assert %{path: ["routing", "kind"], message: "is not supported"} in routing_errors

    assert {:error, task_type_errors} = Document.validate(Map.put(document, "task_types", ["bad"]))
    assert %{path: ["task_types", "0"], message: "must be an object"} in task_type_errors

    assert {:error, profile_errors} =
             Document.validate(Map.put(document, "execution_profiles", ["bad"]))

    assert %{path: ["execution_profiles", "0"], message: "must be an object"} in profile_errors

    assert {:error, task_type_field_errors} =
             Document.validate(Map.put(document, "task_types", [%{}]))

    assert %{path: ["task_types", "0", "id"], message: "is required"} in task_type_field_errors

    assert {:error, profile_field_errors} =
             Document.validate(Map.put(document, "execution_profiles", [%{}]))

    assert %{path: ["execution_profiles", "0", "id"], message: "is required"} in profile_field_errors

    assert {:error, unsupported_errors} =
             document
             |> put_in(["automation_projects", Access.at(0), "api_token"], "must-not-persist")
             |> Document.validate()

    assert %{
             path: ["automation_projects", "0", "api_token"],
             message: "is not supported"
           } in unsupported_errors

    assert {:error, non_string_key_errors} = Document.validate(Map.put(document, :unexpected, true))
    assert %{path: [":unexpected"], message: "is not supported"} in non_string_key_errors
  end

  test "accepts compatible runtime model bindings and rejects incompatible capabilities" do
    document = runtime_model_document()

    assert {:ok, ^document} = Document.validate(document)

    incompatible =
      put_in(document, ["model_references", Access.at(1), "capabilities"], %{
        "structured_output" => true,
        "tool_use" => false,
        "context_window" => 16_000
      })

    assert {:error, errors} = Document.validate(incompatible)

    assert %{
             path: ["routing", "fallback_model_reference_id"],
             message: "must reference a model with tool_use capability"
           } in errors

    execution_fallback =
      put_in(
        document,
        ["model_references", Access.at(2), "capabilities", "structured_output"],
        false
      )

    assert {:error, execution_fallback_errors} = Document.validate(execution_fallback)

    assert %{
             path: ["execution_profiles", "0", "execution_fallback_model_reference_id"],
             message: "must reference a model with structured_output capability"
           } in execution_fallback_errors

    missing_execution_fallback = update_in(document, ["routing"], &Map.delete(&1, "execution_fallback_model_reference_id"))

    assert {:error, missing_fallback_errors} = Document.validate(missing_execution_fallback)

    assert %{path: ["routing", "execution_fallback_model_reference_id"], message: "is required"} in missing_fallback_errors

    assert {:error, empty_routing_errors} =
             document
             |> Map.put("routing", %{})
             |> Document.validate()

    assert %{path: ["routing", "model_reference_id"], message: "is required"} in empty_routing_errors
    assert %{path: ["routing", "fallback_model_reference_id"], message: "is required"} in empty_routing_errors
    assert %{path: ["routing", "execution_fallback_model_reference_id"], message: "is required"} in empty_routing_errors
    assert %{path: ["routing", "profile"], message: "is required"} in empty_routing_errors

    explicitly_shared_execution_fallback =
      put_in(document, ["routing", "execution_fallback_model_reference_id"], "task-model")

    assert {:ok, ^explicitly_shared_execution_fallback} = Document.validate(explicitly_shared_execution_fallback)

    assert {:error, runtime_errors} =
             document
             |> put_in(["routing", "profile", "runtime"], "simulated")
             |> put_in(["execution_profiles", Access.at(0), "runtime"], "simulated")
             |> Document.validate()

    assert %{path: ["routing", "profile", "runtime"], message: "must be compatible with codex_app_server"} in runtime_errors
    assert %{path: ["execution_profiles", "0", "runtime"], message: "must be compatible with codex_app_server"} in runtime_errors

    assert {:error, no_switch_errors} =
             document
             |> put_in(["execution_profiles", Access.at(0), "model_reference_ids"], [
               "task-model",
               "routing-model"
             ])
             |> put_in(["execution_profiles", Access.at(0), "selection_policy"], "price")
             |> Document.validate()

    assert %{path: ["execution_profiles", "0", "model_reference_ids"], message: "is not supported"} in no_switch_errors
    assert %{path: ["execution_profiles", "0", "selection_policy"], message: "is not supported"} in no_switch_errors
  end

  test "rejects malformed runtime model provider and profile contracts" do
    document = runtime_model_document()

    assert {:error, routing_type_errors} = Document.validate(Map.put(document, "routing", []))
    assert %{path: ["routing"], message: "must be an object"} in routing_type_errors

    assert {:error, routing_profile_errors} =
             document
             |> put_in(["routing", "profile"], "bad")
             |> Document.validate()

    assert %{path: ["routing", "profile"], message: "must be an object"} in routing_profile_errors

    assert {:error, model_errors} =
             document
             |> put_in(["providers", Access.at(0), "runtime_protocol"], "chat_api")
             |> put_in(["model_references", Access.at(0), "provider_id"], "missing-provider")
             |> put_in(["model_references", Access.at(0), "capabilities"], nil)
             |> put_in(["model_references", Access.at(1), "context_window"], 0)
             |> put_in(["model_references", Access.at(1), "prices"], %{"input" => -1})
             |> put_in(["routing", "execution_fallback_model_reference_id"], 42)
             |> put_in(["routing", "profile", "readonly"], false)
             |> put_in(["routing", "profile", "allow_mutation"], true)
             |> put_in(["routing", "profile", "high_risk_tools"], true)
             |> put_in(["routing", "profile", "required_capabilities", "tool_use"], "yes")
             |> put_in(["routing", "profile", "required_capabilities", "context_window"], "large")
             |> put_in(["execution_profiles", Access.at(0), "model_reference_id"], "missing-model")
             |> put_in(["execution_profiles", Access.at(0), "required_capabilities", "structured_output"], "yes")
             |> put_in(["network"], %{"egress" => true})
             |> Document.validate()

    assert %{path: ["providers", "0", "runtime_protocol"], message: "must be codex_app_server"} in model_errors
    assert %{path: ["model_references", "0", "provider_id"], message: "must reference an existing provider"} in model_errors
    assert %{path: ["model_references", "0", "capabilities"], message: "is required"} in model_errors
    assert %{path: ["model_references", "1", "context_window"], message: "must be a positive integer"} in model_errors
    assert %{path: ["model_references", "1", "prices", "input"], message: "must be a non-negative number"} in model_errors
    assert %{path: ["model_references", "1", "prices", "cached_input"], message: "must be a non-negative number"} in model_errors
    assert %{path: ["routing", "execution_fallback_model_reference_id"], message: "must reference an existing model"} in model_errors
    assert %{path: ["routing", "profile", "readonly"], message: "must be true"} in model_errors
    assert %{path: ["routing", "profile", "allow_mutation"], message: "must be false"} in model_errors
    assert %{path: ["routing", "profile", "high_risk_tools"], message: "must be false"} in model_errors
    assert %{path: ["routing", "profile", "required_capabilities", "tool_use"], message: "must be a boolean"} in model_errors
    assert %{path: ["routing", "profile", "required_capabilities", "context_window"], message: "must be a positive integer"} in model_errors
    assert %{path: ["execution_profiles", "0", "model_reference_id"], message: "must reference an existing model"} in model_errors
    assert %{path: ["execution_profiles", "0", "required_capabilities", "structured_output"], message: "must be a boolean"} in model_errors
    assert %{path: ["network"], message: "must be empty during bootstrap"} in model_errors

    assert {:error, price_errors} =
             document
             |> Map.update!("model_references", fn [first | rest] ->
               [
                 first
                 |> Map.delete("prices")
                 |> put_in(["capabilities", "structured_output"], "yes")
                 | rest
               ]
             end)
             |> put_in(["execution_profiles", Access.at(0), "required_capabilities"], %{
               "structured_output" => true
             })
             |> Document.validate()

    assert %{path: ["model_references", "0", "prices"], message: "is required"} in price_errors
    assert %{path: ["model_references", "0", "capabilities", "structured_output"], message: "must be a boolean"} in price_errors
  end

  test "content hashes are deterministic and change with the document" do
    project = %{"id" => "one"}
    document = Document.for_project(project)

    assert Document.content_hash(document) == Document.content_hash(document)
    refute Document.content_hash(document) == Document.content_hash(Document.for_project(%{"id" => "two"}))
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

  defp runtime_model_document do
    valid_project()
    |> Document.for_project()
    |> Map.put("providers", [
      %{
        "id" => "codex-provider",
        "name" => "Codex Provider",
        "runtime_protocol" => "codex_app_server",
        "endpoint" => "http://127.0.0.1:4010",
        "credential_ref" => "00000000-0000-0000-0000-000000000001"
      }
    ])
    |> Map.put("model_references", [
      runtime_model_reference("routing-model", "gpt-5.6-routing", %{
        "input" => 0,
        "cached_input" => 0,
        "output" => 0
      }),
      runtime_model_reference("routing-fallback-model", "gpt-5.6-routing-fallback", %{
        "input" => 1.25,
        "cached_input" => 0.125,
        "output" => 10.0
      }),
      runtime_model_reference("execution-fallback-model", "gpt-5.6-execution-fallback", %{
        "input" => 0,
        "cached_input" => 0,
        "output" => 0
      }),
      runtime_model_reference("task-model", "gpt-5.6-task", %{
        "input" => 0,
        "cached_input" => 0,
        "output" => 0
      })
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

  defp runtime_model_reference(id, model_id, prices) do
    %{
      "id" => id,
      "provider_id" => "codex-provider",
      "endpoint" => "http://127.0.0.1:4010",
      "model_id" => model_id,
      "credential_ref" => "00000000-0000-0000-0000-000000000001",
      "context_window" => 128_000,
      "capabilities" => %{
        "structured_output" => true,
        "tool_use" => true,
        "context_window" => 128_000
      },
      "prices" => prices
    }
  end
end
