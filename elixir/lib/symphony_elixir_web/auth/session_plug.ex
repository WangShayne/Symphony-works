defmodule SymphonyElixirWeb.Auth.SessionPlug do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias SymphonyElixir.Identity

  @behaviour Plug
  @dialyzer {:nowarn_function, call: 2}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_session(conn)

    case fetch_principal(conn) do
      {:ok, principal} ->
        conn
        |> put_session("principal_id", principal.id)
        |> assign(:current_principal, principal)

      {:error, _reason} ->
        conn
        |> redirect(to: "/auth/login")
        |> halt()
    end
  end

  defp fetch_principal(conn) do
    case get_session(conn, "principal_id") do
      principal_id when is_binary(principal_id) ->
        Identity.get_principal(principal_id)

      _missing ->
        fetch_test_principal(conn)
    end
  end

  defp fetch_test_principal(conn) do
    case get_req_header(conn, "x-symphony-test-principal") do
      [test_principal_id | _rest] when is_binary(test_principal_id) ->
        if Identity.auth_mode() == :test, do: Identity.get_principal(test_principal_id), else: {:error, :not_found}

      _headers ->
        {:error, :not_found}
    end
  end
end
