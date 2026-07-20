defmodule SymphonyElixirWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @endpoint SymphonyElixirWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup tags do
    runtime_was_running? = stop_default_runtime()

    unless Process.whereis(SymphonyElixirWeb.Endpoint) do
      start_supervised!(SymphonyElixirWeb.Endpoint)
    end

    owner = Sandbox.start_owner!(SymphonyElixir.Repo, shared: !tags[:async])

    on_exit(fn ->
      stop_default_runtime()
      Sandbox.stop_owner(owner)
      if runtime_was_running?, do: restart_default_runtime()
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp stop_default_runtime do
    case Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      nil ->
        false

      _pid ->
        :ok =
          Supervisor.terminate_child(
            SymphonyElixir.Supervisor,
            SymphonyElixir.AgentRuntimeSupervisor
          )

        true
    end
  end

  defp restart_default_runtime do
    case Supervisor.restart_child(
           SymphonyElixir.Supervisor,
           SymphonyElixir.AgentRuntimeSupervisor
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
