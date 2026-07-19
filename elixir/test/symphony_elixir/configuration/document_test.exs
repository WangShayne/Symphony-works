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

    assert {:error, populated_errors} =
             Document.validate(Map.put(document, "model_references", [%{"id" => "future"}]))

    assert %{path: ["model_references"], message: "must be empty during bootstrap"} in populated_errors

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
end
