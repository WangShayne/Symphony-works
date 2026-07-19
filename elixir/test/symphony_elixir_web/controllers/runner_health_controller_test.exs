defmodule SymphonyElixirWeb.RunnerHealthControllerTest do
  use SymphonyElixirWeb.ConnCase, async: false

  test "GET /api/v1/runner/health exposes boundary proof", %{conn: conn} do
    response =
      conn
      |> get("/api/v1/runner/health")
      |> json_response(200)

    assert response["protocol"] == %{"ready" => true, "version" => 1}
    assert response["backend"] == %{"ready" => true, "name" => "fake"}

    assert response["boundary"] == %{
             "arbitrary_host_command" => false,
             "docker_adapter_loaded" => false,
             "docker_socket_access" => false,
             "sandbox_exec_contract" => "argv_cwd_secret_refs_only"
           }
  end
end
