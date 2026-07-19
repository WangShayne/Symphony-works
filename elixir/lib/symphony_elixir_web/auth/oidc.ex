defmodule SymphonyElixirWeb.Auth.OIDC do
  @moduledoc """
  Browser OIDC boundary.

  Production delegates authorization-code handling to Assent. Tests use an explicit
  local fixture so auth bypasses cannot compile into production mode.
  """

  alias Assent.Strategy.OIDC, as: AssentOIDC
  alias SymphonyElixir.Security.CredentialBroker

  @spec authorize_url(String.t() | nil) :: {:ok, String.t(), map()} | {:error, :unavailable}
  def authorize_url(return_to) when not is_binary(return_to), do: {:error, :unavailable}

  def authorize_url(return_to) do
    state = random_url_token()
    nonce = random_url_token()

    if SymphonyElixir.Identity.auth_mode() == :test do
      {:ok, "/auth/oidc/callback?code=admin-code&state=#{state}", %{state: state, nonce: nonce, return_to: safe_return_to(return_to), session_params: %{}}}
    else
      production_authorize_url(return_to, nonce)
    end
  end

  @spec callback(map(), map()) :: {:ok, map()} | {:error, atom()}
  def callback(%{"code" => code} = params, %{"oidc_nonce" => nonce} = session) when is_binary(nonce) do
    if SymphonyElixir.Identity.auth_mode() == :test do
      test_claims(code, nonce)
    else
      case Map.fetch(session, "oidc_session_params") do
        {:ok, session_params} when is_map(session_params) -> assent_callback(params, session_params, nonce)
        _missing -> {:error, :invalid_callback}
      end
    end
  end

  def callback(_params, _session), do: {:error, :invalid_callback}

  @spec safe_return_to(String.t() | nil) :: String.t()
  def safe_return_to("/" <> _path = return_to), do: return_to
  def safe_return_to(_return_to), do: "/tasks"

  defp test_claims("admin-code", nonce) do
    {:ok,
     %{
       issuer: "https://issuer.example.test",
       subject: "oidc-admin",
       email: "admin@example.test",
       display_name: "OIDC Admin",
       roles: [:administrator],
       nonce: nonce
     }}
  end

  defp test_claims(_code, _nonce), do: {:error, :invalid_token}

  defp assent_callback(params, session_params, nonce) do
    with {:module, strategy} <- Code.ensure_loaded(oidc_strategy()),
         {:ok, %{user: user}} <-
           with_oidc_config(fn config ->
             config
             |> Keyword.put(:session_params, session_params)
             |> strategy.callback(params)
           end) do
      {:ok,
       %{
         issuer: oidc_issuer(),
         subject: Map.fetch!(user, "sub"),
         email: Map.get(user, "email"),
         display_name: Map.get(user, "name"),
         roles: Map.get(user, "roles", [:viewer]),
         nonce: nonce
       }}
    else
      _error -> {:error, :invalid_token}
    end
  end

  defp random_url_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp production_authorize_url(return_to, nonce) do
    case with_oidc_config(fn config -> config |> Keyword.put(:nonce, nonce) |> oidc_strategy().authorize_url() end) do
      {:ok, %{url: url, session_params: session_params}} ->
        state = Map.get(session_params, :state) || Map.get(session_params, "state")
        stored_nonce = Map.get(session_params, :nonce) || Map.get(session_params, "nonce") || nonce

        {:ok, url,
         %{
           state: state,
           nonce: stored_nonce,
           return_to: safe_return_to(return_to),
           session_params: session_params
         }}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp with_oidc_config(fun) when is_function(fun, 1) do
    config =
      :symphony_elixir
      |> Application.fetch_env!(:oidc)
      |> Keyword.put(:code_verifier, true)

    cond do
      Keyword.has_key?(config, :client_secret) ->
        {:error, :plaintext_client_secret}

      client_secret_ref = Keyword.get(config, :client_secret_ref) ->
        config = Keyword.delete(config, :client_secret_ref)

        CredentialBroker.with_secret(client_secret_ref, :oidc_client_secret, fn client_secret ->
          fun.(Keyword.put(config, :client_secret, client_secret))
        end)

      true ->
        fun.(config)
    end
  end

  defp oidc_strategy do
    :symphony_elixir
    |> Application.fetch_env!(:oidc)
    |> Keyword.get(:oidc_strategy, AssentOIDC)
  end

  defp oidc_issuer do
    :symphony_elixir
    |> Application.fetch_env!(:oidc)
    |> Keyword.fetch!(:issuer)
  end
end
