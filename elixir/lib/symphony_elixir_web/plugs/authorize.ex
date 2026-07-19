defmodule SymphonyElixirWeb.Plugs.Authorize do
  @moduledoc false

  import Plug.Conn

  alias SymphonyElixir.Identity.Authorization

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    action = Keyword.get(opts, :action) || Authorization.action_for_path(conn.method, conn.request_path)

    case Authorization.authorize(conn.assigns[:current_principal], action) do
      :ok -> conn
      {:error, :unauthorized} -> reject(conn, :unauthorized, "unauthorized", "Authentication required")
      {:error, :forbidden} -> reject(conn, :forbidden, "forbidden", "Forbidden")
    end
  end

  defp reject(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message, details: %{}, correlation_id: nil}}))
    |> halt()
  end
end
