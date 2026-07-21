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
    unless Process.whereis(SymphonyElixirWeb.Endpoint) do
      start_supervised!(SymphonyElixirWeb.Endpoint)
    end

    owner = Sandbox.start_owner!(SymphonyElixir.Repo, shared: !tags[:async])
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
