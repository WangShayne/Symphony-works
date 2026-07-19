defmodule SymphonyElixirWeb.Auth.Controller do
  @moduledoc false

  use Phoenix.Controller, formats: [:html, :json]

  alias SymphonyElixir.Identity
  alias SymphonyElixirWeb.Auth.OIDC

  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, params) do
    css_url = SymphonyElixirWeb.StaticAssets.dashboard_css_url()
    error = if Map.has_key?(params, "error"), do: ~s(<p class="auth-error" role="alert">Sign in failed</p>), else: ""

    html(conn, """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Symphony Sign In</title>
        <link rel="stylesheet" href="#{css_url}">
      </head>
      <body>
        <main class="auth-shell">
          <section class="auth-panel" aria-labelledby="sign-in-title">
            <div>
              <p class="eyebrow">Symphony Identity</p>
              <h1 id="sign-in-title">Sign in</h1>
              <p class="auth-copy">Use your team identity provider to access the control plane.</p>
            </div>
            #{error}
            <a class="oidc-button" href="/auth/oidc/start?return_to=/tasks">Continue with OIDC</a>
            <p class="auth-footnote">OIDC authorization code flow with PKCE, state, and nonce validation.</p>
          </section>
        </main>
      </body>
    </html>
    """)
  end

  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, params) do
    return_to = Map.get(params, "return_to", "/tasks")

    case OIDC.authorize_url(return_to) do
      {:ok, url, session_values} ->
        conn
        |> put_session("oidc_state", session_values.state)
        |> put_session("oidc_nonce", session_values.nonce)
        |> put_session("oidc_session_params", session_values.session_params)
        |> put_session("return_to", session_values.return_to)
        |> redirect_to_auth(url)

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> html("Sign in unavailable")
    end
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    expected_state = get_session(conn, "oidc_state")

    with %{"state" => ^expected_state} <- params,
         {:ok, claims} <- OIDC.callback(params, callback_session(conn)),
         true <- nonce_valid?(claims, get_session(conn, "oidc_nonce")),
         {:ok, principal} <- Identity.upsert_oidc_principal(claims) do
      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session("principal_id", principal.id)
      |> redirect(to: get_session(conn, "return_to") || "/tasks")
    else
      _error ->
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_flash(:error, "Sign in failed")
        |> redirect(to: "/auth/login?error=sign_in_failed")
    end
  end

  @spec logout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def logout(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: "/auth/login")
  end

  defp nonce_valid?(%{nonce: nonce}, nonce), do: true
  defp nonce_valid?(_claims, _nonce), do: false

  defp redirect_to_auth(conn, "/" <> _path = url), do: redirect(conn, to: url)
  defp redirect_to_auth(conn, url), do: redirect(conn, external: url)

  defp callback_session(conn) do
    %{
      "oidc_nonce" => get_session(conn, "oidc_nonce"),
      "oidc_session_params" => get_session(conn, "oidc_session_params") || %{}
    }
  end
end
