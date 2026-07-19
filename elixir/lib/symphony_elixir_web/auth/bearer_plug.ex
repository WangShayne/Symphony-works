defmodule SymphonyElixirWeb.Auth.BearerPlug do
  @moduledoc false

  import Plug.Conn

  alias SymphonyElixir.Identity

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case fetch_principal(conn) do
      {:ok, principal} ->
        assign(conn, :current_principal, principal)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unauthorized, Jason.encode!(error("unauthorized", "Authentication required")))
        |> halt()
    end
  end

  defp fetch_principal(conn) do
    cond do
      principal_id = get_req_header(conn, "x-symphony-test-principal") |> List.first() ->
        if Identity.auth_mode() == :test, do: Identity.get_principal(principal_id), else: {:error, :unauthorized}

      bearer_token = bearer_token(conn) ->
        Identity.verify_service_token(bearer_token)

      true ->
        {:error, :unauthorized}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _headers -> nil
    end
  end

  defp error(code, message), do: %{error: %{code: code, message: message, details: %{}, correlation_id: nil}}
end
