defmodule SymphonyElixirWeb.Api.V1.AutomationProjectControllerTest do
  use SymphonyElixirWeb.ConnCase, async: false

  alias SymphonyElixirWeb.Api.V1.AutomationProjectController

  @bootstrap_token "test-bootstrap-token-with-32-bytes"
  @same_length_invalid_token String.duplicate("x", byte_size(@bootstrap_token))

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

    create_conn =
      build_conn()
      |> authenticated()
      |> post("/api/v1/automation-projects", %{
        "project" => put_in(valid_project(), ["repository", "url"], "")
      })

    revision_id = json_response(create_conn, 201)["data"]["id"]

    for action <- ["validate", "activate"] do
      assert %{"error" => %{"code" => "invalid_configuration"}} =
               build_conn()
               |> authenticated()
               |> post("/api/v1/configuration-revisions/#{revision_id}/#{action}")
               |> json_response(422)
    end
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

    invalid_actor_conn =
      build_conn()
      |> assign(:current_principal, %{id: nil})
      |> AutomationProjectController.create(%{
        "project" => Map.put(valid_project(), "private_note", private_value)
      })

    invalid_actor = json_response(invalid_actor_conn, 422)

    assert invalid_actor["error"]["code"] == "invalid_configuration"
    refute Map.has_key?(invalid_actor["error"], "details")
    refute Jason.encode!(invalid_actor) =~ private_value
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
end
