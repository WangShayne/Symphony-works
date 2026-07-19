defmodule SymphonyElixir.Runner.Health do
  @moduledoc """
  Public health view for the Runner protocol and security boundary.
  """

  @spec snapshot() :: map()
  def snapshot do
    backend =
      case SymphonyElixir.Runner.ping() do
        {:ok, result} -> %{ready: true, name: result.backend}
        {:error, error} -> %{ready: false, error_code: error.code}
      end

    %{
      protocol: %{ready: true, version: SymphonyRunner.Protocol.version()},
      backend: backend,
      boundary: %{
        arbitrary_host_command: false,
        docker_socket_access: false,
        docker_adapter_loaded: false,
        sandbox_exec_contract: "argv_cwd_secret_refs_only"
      }
    }
  end
end
