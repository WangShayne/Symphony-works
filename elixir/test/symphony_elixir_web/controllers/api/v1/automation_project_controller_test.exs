defmodule SymphonyElixirWeb.Api.V1.AutomationProjectControllerTest do
  use SymphonyElixirWeb.ConnCase, async: false

  @bootstrap_token "test-bootstrap-token-with-32-bytes"
  @same_length_invalid_token String.duplicate("x", byte_size(@bootstrap_token))

  defmodule FailingProbe do
    @behaviour SymphonyElixir.Configuration.Probe

    @impl true
    def validate(_document), do: {:error, {:model, %{"message" => "offline", "api_key" => "secret"}}}
  end

  test "configuration writes reject an unauthenticated request", %{conn: conn} do
    conn = post(conn, "/api/v1/automation-projects", %{"project" => valid_project()})

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "configuration writes reject invalid bootstrap tokens", %{conn: conn} do
    different_length =
      conn
      |> put_req_header("authorization", "Bearer wrong")
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})

    assert json_response(different_length, 401)["error"]["code"] == "unauthorized"

    same_length =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@same_length_invalid_token}")
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})

    assert json_response(same_length, 401)["error"]["code"] == "unauthorized"
  end

  test "configuration writes reject blank and undersized configured tokens" do
    previous_token = Application.get_env(:symphony_elixir, :bootstrap_token)

    on_exit(fn -> Application.put_env(:symphony_elixir, :bootstrap_token, previous_token) end)

    for token <- ["", "too-short"] do
      Application.put_env(:symphony_elixir, :bootstrap_token, token)

      response =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/automation-projects", %{"project" => valid_project()})

      assert json_response(response, 401)["error"]["code"] == "unauthorized"
    end
  end

  test "configuration resources return validation and not-found errors" do
    assert %{"error" => %{"code" => "not_found"}} =
             build_conn()
             |> authenticated()
             |> get("/api/v1/configuration-revisions/active")
             |> json_response(404)

    missing_id = Ecto.UUID.generate()

    for action <- ["validate", "activate"] do
      assert %{"error" => %{"code" => "not_found"}} =
               build_conn()
               |> authenticated()
               |> post("/api/v1/configuration-revisions/#{missing_id}/#{action}")
               |> json_response(404)
    end

    assert %{"error" => %{"code" => "not_found"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{missing_id}/rollback")
             |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             build_conn()
             |> authenticated()
             |> get("/api/v1/configuration-revisions/#{missing_id}/export")
             |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             build_conn()
             |> authenticated()
             |> patch("/api/v1/configuration-revisions/#{missing_id}", %{
               "document" => %{"schema_version" => 1, "automation_projects" => []}
             })
             |> json_response(404)

    create_conn =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{
        "project" => put_in(valid_project(), ["repository", "url"], "")
      })

    revision_id = json_response(create_conn, 201)["data"]["id"]

    for action <- ["validate", "activate"] do
      assert %{"error" => %{"code" => "invalid_configuration", "details" => details}} =
               build_conn()
               |> authenticated()
               |> post("/api/v1/configuration-revisions/#{revision_id}/#{action}")
               |> json_response(422)

      assert Enum.any?(
               details,
               &(&1["path"] == ["automation_projects", "0", "repository", "url"])
             )
    end

    assert %{"error" => %{"code" => "invalid_configuration"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{revision_id}/rollback")
             |> json_response(422)

    valid_create =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})
      |> json_response(201)

    active_id = valid_create["data"]["id"]
    active_document = valid_create["data"]["document"]

    build_conn()
    |> authenticated()
    |> post("/api/v1/configuration-revisions/#{active_id}/activate")
    |> json_response(200)

    assert %{"error" => %{"code" => "invalid_configuration"}} =
             build_conn()
             |> authenticated()
             |> patch("/api/v1/configuration-revisions/#{active_id}", %{"document" => active_document})
             |> json_response(422)
  end

  test "missing project input and an invalid actor return validation errors", %{conn: conn} do
    missing_project =
      conn
      |> authenticated()
      |> post("/api/v1/automation-projects", %{})
      |> json_response(422)

    assert %{
             "error" => %{
               "code" => "invalid_configuration",
               "message" => "Configuration validation failed"
             }
           } = missing_project

    refute Map.has_key?(missing_project["error"], "details")

    private_value = "must-not-leak"

    private_revision =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{
        "project" =>
          valid_project()
          |> Map.put("private_note", private_value)
          |> put_in(["repository", "url"], "")
      })
      |> json_response(201)

    invalid_configuration =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/#{private_revision["data"]["id"]}/validate")
      |> json_response(422)

    assert invalid_configuration["error"]["code"] == "invalid_configuration"
    refute Jason.encode!(invalid_configuration) =~ private_value
  end

  test "configuration lifecycle resources normalize invalid import and pin errors" do
    assert %{"error" => %{"code" => "invalid_configuration"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/import-workflow", %{})
             |> json_response(422)

    assert %{"error" => %{"code" => "invalid_configuration"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/import-workflow", %{
               "workflow" => %{"content" => "---\n["}
             })
             |> json_response(422)

    path_import =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/import-workflow", %{
        "workflow" => %{"path" => "/etc/passwd"}
      })
      |> json_response(422)

    assert path_import["error"]["code"] == "invalid_configuration"
    refute Jason.encode!(path_import) =~ "root:"

    assert %{"error" => %{"code" => "invalid_configuration"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-task-pins", %{})
             |> json_response(422)

    assert %{"error" => %{"code" => "invalid_configuration"}} =
             build_conn()
             |> authenticated()
             |> patch("/api/v1/configuration-revisions/#{Ecto.UUID.generate()}", %{})
             |> json_response(422)

    assert %{"error" => %{"code" => "not_found"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-task-pins", %{"task_id" => "task-1"})
             |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             build_conn()
             |> authenticated()
             |> get("/api/v1/configuration-task-pins/missing")
             |> json_response(404)
  end

  test "REST activation invokes configured probes without exposing probe details" do
    previous = Application.get_env(:symphony_elixir, :configuration_probes)
    Application.put_env(:symphony_elixir, :configuration_probes, [FailingProbe])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :configuration_probes, previous)
    end)

    create_conn =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})

    revision_id = json_response(create_conn, 201)["data"]["id"]

    response =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/#{revision_id}/activate")
      |> json_response(422)

    assert response["error"]["code"] == "invalid_configuration"
    refute Jason.encode!(response) =~ "secret"
    refute Jason.encode!(response) =~ "offline"

    Application.put_env(:symphony_elixir, :configuration_probes, :invalid)

    create_conn =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{"project" => put_in(valid_project(), ["name"], "No probes")})

    revision_id = json_response(create_conn, 201)["data"]["id"]

    assert %{"data" => %{"id" => ^revision_id, "status" => "active"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{revision_id}/activate")
             |> json_response(200)
  end

  test "bootstrap Administrator creates, validates, activates, and reads an Automation Project",
       %{conn: conn} do
    create_conn =
      conn
      |> authenticated()
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})

    assert %{"data" => %{"id" => revision_id, "status" => "draft"}} =
             json_response(create_conn, 201)

    validate_conn =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/#{revision_id}/validate")

    assert %{"data" => %{"status" => "validated"}} = json_response(validate_conn, 200)

    activate_conn =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/#{revision_id}/activate")

    assert %{"data" => %{"status" => "active"}} = json_response(activate_conn, 200)

    active_conn =
      build_conn()
      |> authenticated()
      |> get("/api/v1/configuration-revisions/active")

    assert %{
             "data" => %{
               "id" => ^revision_id,
               "status" => "active",
               "document" => %{"automation_projects" => [project]}
             }
           } = json_response(active_conn, 200)

    assert project["name"] == "Symphony"
    assert project["repository"]["target_branch"] == "main"
  end

  test "REST configuration lifecycle imports, pins, rolls back, and exports redacted data" do
    assert %{"data" => %{"task_types" => [_ | _], "execution_profiles" => [_ | _]}} =
             build_conn()
             |> authenticated()
             |> get("/api/v1/configuration/templates")
             |> json_response(200)

    import_conn =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/import-workflow", %{
        "workflow" => %{"content" => workflow_content()}
      })

    assert %{"data" => %{"id" => imported_id, "status" => "draft", "document" => imported_document}} =
             json_response(import_conn, 201)

    updated_document =
      put_in(imported_document, ["automation_projects", Access.at(0), "name"], "Edited draft")

    assert %{"data" => %{"id" => ^imported_id, "document" => %{"automation_projects" => [updated]}}} =
             build_conn()
             |> authenticated()
             |> patch("/api/v1/configuration-revisions/#{imported_id}", %{
               "document" => updated_document
             })
             |> json_response(200)

    assert updated["name"] == "Edited draft"

    assert %{"data" => %{"id" => ^imported_id, "status" => "active"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{imported_id}/activate")
             |> json_response(200)

    assert %{"error" => %{"code" => "invalid_configuration"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-task-pins", %{"task_id" => ""})
             |> json_response(422)

    assert %{"data" => %{"revision_id" => ^imported_id, "task_id" => "task-1"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-task-pins", %{"task_id" => "task-1"})
             |> json_response(201)

    replacement =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{
        "project" => put_in(valid_project(), ["name"], "Replacement")
      })
      |> json_response(201)

    replacement_id = replacement["data"]["id"]

    assert %{"data" => %{"id" => ^replacement_id, "status" => "active"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{replacement_id}/activate")
             |> json_response(200)

    assert %{"data" => %{"revision_id" => ^imported_id}} =
             build_conn()
             |> authenticated()
             |> get("/api/v1/configuration-task-pins/task-1")
             |> json_response(200)

    assert %{"data" => %{"id" => ^imported_id, "status" => "active"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{imported_id}/rollback")
             |> json_response(200)

    exported =
      build_conn()
      |> authenticated()
      |> get("/api/v1/configuration-revisions/#{imported_id}/export")
      |> json_response(200)

    encoded = Jason.encode!(exported)
    refute encoded =~ "ghp_api_key"
    assert encoded =~ "[REDACTED]"
  end

  test "bootstrap Administrator binds a secret reference to a draft provider without returning plaintext",
       %{conn: conn} do
    secret =
      conn
      |> authenticated()
      |> post("/api/v1/secrets", %{"secret" => %{"name" => "linear-api-token", "value" => "plain-api-token"}})
      |> json_response(201)

    reference = secret["data"]

    create =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})
      |> json_response(201)

    revision_id = create["data"]["id"]

    bind =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/#{revision_id}/providers/linear/credential-ref", %{
        "provider" => %{"name" => "Linear"},
        "credential_ref" => reference
      })
      |> json_response(200)

    assert %{
             "data" => %{
               "id" => ^revision_id,
               "status" => "draft",
               "document" => %{
                 "providers" => [
                   %{
                     "id" => "linear",
                     "name" => "Linear",
                     "credential_ref" => secret_id
                   }
                 ]
               }
             }
           } = bind

    assert secret_id == reference["id"]

    encoded = Jason.encode!(bind)
    refute encoded =~ "plain-api-token"
    refute encoded =~ "linear-api-token"
    refute encoded =~ "\"api_key\""

    assert %{"data" => %{"status" => "validated"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{revision_id}/validate")
             |> json_response(200)

    assert %{"data" => %{"status" => "active"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{revision_id}/activate")
             |> json_response(200)

    active =
      build_conn()
      |> authenticated()
      |> get("/api/v1/configuration-revisions/active")
      |> json_response(200)

    assert get_in(active, ["data", "document", "providers", Access.at(0), "credential_ref"]) == reference["id"]

    exported = Jason.encode!(active)
    refute exported =~ "plain-api-token"
    refute exported =~ "linear-api-token"
    refute exported =~ "\"api_key\""
  end

  test "provider credential binding endpoint returns sanitized validation errors", %{conn: conn} do
    secret =
      conn
      |> authenticated()
      |> post("/api/v1/secrets", %{"secret" => %{"name" => "linear-api-token", "value" => "plain-api-token"}})
      |> json_response(201)

    reference = secret["data"]

    assert %{"error" => %{"code" => "not_found"}} =
             build_conn()
             |> authenticated()
             |> post("/api/v1/configuration-revisions/#{Ecto.UUID.generate()}/providers/linear/credential-ref", %{
               "provider" => %{"name" => "Linear"},
               "credential_ref" => reference
             })
             |> json_response(404)

    create =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})
      |> json_response(201)

    revision_id = create["data"]["id"]

    invalid_reference =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/#{revision_id}/providers/linear/credential-ref", %{
        "provider" => %{"name" => "Linear"},
        "credential_ref" => %{}
      })
      |> json_response(422)

    assert invalid_reference["error"]["code"] == "invalid_configuration"
    refute Jason.encode!(invalid_reference) =~ "plain-api-token"

    malformed =
      build_conn()
      |> authenticated()
      |> post("/api/v1/configuration-revisions/#{revision_id}/providers/linear/credential-ref", %{})
      |> json_response(422)

    assert malformed["error"]["code"] == "invalid_configuration"
  end

  defp authenticated(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{@bootstrap_token}")
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

  defp workflow_content do
    """
    ---
    tracker:
      kind: github
      project_slug: WangShayne/Symphony-works
      api_key: ghp_api_key
    codex:
      command: codex app-server
    ---
    Imported prompt.
    """
  end
end
