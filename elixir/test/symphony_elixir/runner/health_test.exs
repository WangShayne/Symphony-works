defmodule SymphonyElixir.Runner.HealthTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Runner

  test "health proves runner readiness without Docker or arbitrary command access" do
    assert %{
             protocol: %{ready: true, version: 1},
             backend: %{ready: true, name: "fake"},
             boundary: %{
               arbitrary_host_command: false,
               docker_socket_access: false,
               docker_adapter_loaded: false,
               sandbox_exec_contract: "argv_cwd_secret_refs_only"
             }
           } = Runner.Health.snapshot()
  end
end
