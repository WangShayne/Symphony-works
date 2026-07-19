defmodule SymphonyElixirWeb.Auth.TrustedAdminPlug do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias SymphonyElixir.Identity
  alias SymphonyElixir.Identity.Principal

  @behaviour Plug
  @minimum_token_bytes 32

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    surface = Keyword.fetch!(opts, :surface)
    conn = if surface == :browser, do: fetch_session(conn), else: conn

    case fetch_trusted_admin(conn, surface) do
      {:ok, conn, %{roles: roles} = principal} ->
        if :administrator in roles do
          conn
          |> persist_browser_principal(surface, principal)
          |> assign(:current_principal, principal)
        else
          reject(conn, surface, :forbidden, "forbidden", "Forbidden")
        end

      {:error, _reason} ->
        reject(conn, surface, :unauthorized, "unauthorized", "Authentication required")
    end
  end

  defp fetch_trusted_admin(conn, surface) do
    case fetch_bootstrap_admin(conn) do
      {:ok, conn, principal} -> {:ok, conn, principal}
      {:error, _reason} -> fetch_authenticated_principal(conn, surface)
    end
  end

  defp fetch_bootstrap_admin(conn) do
    expected = Application.get_env(:symphony_elixir, :bootstrap_token)

    with false <- Identity.bootstrap_retired?(),
         ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- valid_bootstrap_token?(presented, expected) do
      principal = %Principal{id: "bootstrap-admin", subject: "bootstrap", roles: [:administrator]}

      conn =
        conn
        |> fetch_session()
        |> put_session("bootstrap_admin", true)

      {:ok, conn, principal}
    else
      _error -> {:error, :unauthorized}
    end
  end

  defp fetch_authenticated_principal(conn, :browser) do
    case get_session(conn, "principal_id") do
      principal_id when is_binary(principal_id) ->
        principal_result(conn, Identity.get_principal(principal_id))

      _missing ->
        fetch_test_principal(conn)
    end
  end

  defp fetch_authenticated_principal(conn, :api) do
    cond do
      principal_id = get_req_header(conn, "x-symphony-test-principal") |> List.first() ->
        fetch_test_principal_id(conn, principal_id)

      bearer_token = bearer_token(conn) ->
        principal_result(conn, Identity.verify_service_token(bearer_token))

      true ->
        {:error, :unauthorized}
    end
  end

  defp fetch_test_principal(conn) do
    case get_req_header(conn, "x-symphony-test-principal") do
      [principal_id | _rest] when is_binary(principal_id) ->
        fetch_test_principal_id(conn, principal_id)

      _headers ->
        {:error, :unauthorized}
    end
  end

  defp fetch_test_principal_id(conn, principal_id) do
    if Identity.auth_mode() == :test do
      principal_result(conn, Identity.get_principal(principal_id))
    else
      {:error, :unauthorized}
    end
  end

  defp principal_result(conn, {:ok, principal}), do: {:ok, conn, principal}
  defp principal_result(_conn, {:error, _reason}), do: {:error, :unauthorized}

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _headers -> nil
    end
  end

  defp persist_browser_principal(conn, :browser, %{id: "bootstrap-admin"}), do: conn
  defp persist_browser_principal(conn, :browser, %{id: principal_id}), do: put_session(conn, "principal_id", principal_id)
  defp persist_browser_principal(conn, _surface, _principal), do: conn

  defp valid_bootstrap_token?(presented, expected)
       when is_binary(presented) and is_binary(expected) and byte_size(expected) >= @minimum_token_bytes do
    Plug.Crypto.secure_compare(
      :crypto.hash(:sha256, presented),
      :crypto.hash(:sha256, expected)
    )
  end

  defp valid_bootstrap_token?(_presented, _expected), do: false

  defp reject(conn, :browser, :unauthorized, _code, _message) do
    case get_req_header(conn, "authorization") do
      [] ->
        conn
        |> redirect(to: "/auth/login")
        |> halt()

      _headers ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unauthorized, Jason.encode!(%{error: %{code: "unauthorized", message: "Authentication required"}}))
        |> halt()
    end
  end

  defp reject(conn, :browser, status, _code, message) do
    conn
    |> send_resp(status, message)
    |> halt()
  end

  defp reject(conn, :api, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message, details: %{}, correlation_id: nil}}))
    |> halt()
  end
end
