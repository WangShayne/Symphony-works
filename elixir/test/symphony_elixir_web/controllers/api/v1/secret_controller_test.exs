defmodule SymphonyElixirWeb.Api.V1.SecretControllerTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Security.SecretStore

  @bootstrap_token "test-bootstrap-token-with-32-bytes"
  @plaintext "api-secret-value"

  test "API creates and replaces secrets without returning plaintext", %{conn: conn} do
    create =
      conn
      |> authenticated()
      |> post("/api/v1/secrets", %{"secret" => %{"name" => "github", "value" => @plaintext}})
      |> json_response(201)

    assert %{"data" => %{"id" => id, "name" => "github"}} = create
    refute Jason.encode!(create) =~ @plaintext

    replace =
      build_conn()
      |> authenticated()
      |> patch("/api/v1/secrets/#{id}", %{"secret" => %{"value" => "replacement-value"}})
      |> json_response(200)

    assert %{"data" => %{"id" => ^id, "name" => "github"}} = replace
    refute Jason.encode!(replace) =~ "replacement-value"
    assert {:ok, "replacement-value"} = SecretStore.fetch(%SecretStore.Reference{id: id, name: "github"})
  end

  test "Phoenix logs filter secret API POST values", %{conn: conn} do
    canary = "api-secret-log-canary-#{System.unique_integer([:positive, :monotonic])}"

    log =
      capture_log([level: :debug], fn ->
        response =
          conn
          |> authenticated()
          |> post("/api/v1/secrets", %{"secret" => %{"name" => "github", "value" => canary}})
          |> json_response(201)

        assert %{"data" => %{"name" => "github"}} = response
      end)

    assert log =~ "Parameters:"
    assert log =~ "[FILTERED]"
    refute log =~ canary
  end

  test "API normalizes invalid secret errors without echoing submitted values", %{conn: conn} do
    response =
      conn
      |> authenticated()
      |> post("/api/v1/secrets", %{"secret" => %{"name" => "", "value" => @plaintext}})
      |> json_response(422)

    assert response["error"]["code"] == "invalid_secret"
    refute Jason.encode!(response) =~ @plaintext
  end

  test "API handles malformed create and replace requests", %{conn: conn} do
    malformed_create =
      conn
      |> authenticated()
      |> post("/api/v1/secrets", %{})
      |> json_response(422)

    assert malformed_create["error"]["code"] == "invalid_secret"

    malformed_replace =
      build_conn()
      |> authenticated()
      |> patch("/api/v1/secrets/#{Ecto.UUID.generate()}", %{})
      |> json_response(422)

    assert malformed_replace["error"]["code"] == "invalid_secret"

    not_found =
      build_conn()
      |> authenticated()
      |> patch("/api/v1/secrets/#{Ecto.UUID.generate()}", %{"secret" => %{"value" => "replacement-value"}})
      |> json_response(404)

    assert not_found["error"]["code"] == "not_found"

    invalid_replace =
      build_conn()
      |> authenticated()
      |> post("/api/v1/secrets", %{"secret" => %{"name" => "github", "value" => "value"}})
      |> json_response(201)

    id = invalid_replace["data"]["id"]

    response =
      build_conn()
      |> authenticated()
      |> patch("/api/v1/secrets/#{id}", %{"secret" => %{"value" => ""}})
      |> json_response(422)

    assert response["error"]["code"] == "invalid_secret"
  end

  defp authenticated(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{@bootstrap_token}")
  end
end
