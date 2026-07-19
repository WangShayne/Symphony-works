defmodule SymphonyElixirWeb.Auth.BootstrapPlug do
  @moduledoc """
  Authenticates the externally supplied bootstrap Administrator token.

  The token is never stored in SQLite. The OIDC/RBAC slice replaces this narrow bootstrap seam.
  """

  import Plug.Conn

  @behaviour Plug
  @minimum_token_bytes 32

  @impl true
  def init(opts), do: opts

  @spec validate_configuration!() :: :ok
  def validate_configuration! do
    case Application.get_env(:symphony_elixir, :bootstrap_token) do
      token when is_binary(token) and byte_size(token) >= @minimum_token_bytes ->
        :ok

      _invalid_token ->
        raise ArgumentError,
              "SYMPHONY_BOOTSTRAP_TOKEN must contain at least #{@minimum_token_bytes} bytes"
    end
  end

  @impl true
  def call(conn, _opts) do
    expected = Application.get_env(:symphony_elixir, :bootstrap_token)

    with ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- valid_token?(presented, expected) do
      conn
      |> fetch_session()
      |> put_session("bootstrap_admin", true)
      |> assign(:current_principal, %{id: "bootstrap-admin", roles: [:administrator]})
    else
      _ -> reject(conn)
    end
  end

  defp valid_token?(presented, expected)
       when is_binary(presented) and is_binary(expected) and byte_size(expected) >= @minimum_token_bytes do
    Plug.Crypto.secure_compare(
      :crypto.hash(:sha256, presented),
      :crypto.hash(:sha256, expected)
    )
  end

  defp valid_token?(_presented, _expected), do: false

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      :unauthorized,
      Jason.encode!(%{error: %{code: "unauthorized", message: "Authentication required"}})
    )
    |> halt()
  end
end
