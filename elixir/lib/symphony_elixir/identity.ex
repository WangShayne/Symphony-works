defmodule SymphonyElixir.Identity do
  @moduledoc """
  Public identity context for OIDC users, service bearer credentials, and bootstrap retirement.
  """

  import Ecto.Query

  alias SymphonyElixir.Identity.{BootstrapState, PrincipalRecord, ServiceCredential}
  alias SymphonyElixir.Repo

  @bootstrap_id "oidc-activation"
  @token_bytes 32

  @spec validate_auth_configuration!() :: :ok
  def validate_auth_configuration! do
    mode = auth_mode()

    if mode == :test and Application.get_env(:symphony_elixir, :env) == :prod do
      raise ArgumentError, "auth.mode :test is not allowed in production"
    end

    :ok
  end

  @spec auth_mode() :: :oidc | :test
  def auth_mode do
    :symphony_elixir
    |> Application.get_env(:auth, [])
    |> Keyword.get(:mode, :oidc)
  end

  @spec get_principal(String.t()) :: {:ok, SymphonyElixir.Identity.Principal.t()} | {:error, :not_found}
  def get_principal(id) do
    case Ecto.UUID.cast(id) do
      {:ok, principal_id} ->
        case Repo.get(PrincipalRecord, principal_id) do
          %PrincipalRecord{} = record -> {:ok, PrincipalRecord.principal(record)}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @spec upsert_oidc_principal(map()) :: {:ok, PrincipalRecord.t()} | {:error, term()}
  def upsert_oidc_principal(attrs) do
    now = DateTime.utc_now()
    roles = Map.get(attrs, :roles) || Map.get(attrs, "roles") || default_roles()

    normalized = %{
      issuer: Map.get(attrs, :issuer) || Map.fetch!(attrs, "issuer"),
      subject: Map.get(attrs, :subject) || Map.fetch!(attrs, "subject"),
      email: Map.get(attrs, :email) || Map.get(attrs, "email"),
      display_name: Map.get(attrs, :display_name) || Map.get(attrs, "display_name"),
      roles: roles,
      last_authenticated_at: now
    }

    Repo.transaction(fn ->
      principal =
        case Repo.get_by(PrincipalRecord, issuer: normalized.issuer, subject: normalized.subject) do
          %PrincipalRecord{} = record ->
            record
            |> PrincipalRecord.changeset(normalized)
            |> Repo.update!()

          nil ->
            %PrincipalRecord{}
            |> PrincipalRecord.changeset(normalized)
            |> Repo.insert!()
        end

      maybe_retire_bootstrap!(principal, now)
      PrincipalRecord.principal(principal)
    end)
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  @spec bootstrap_retired?() :: boolean()
  def bootstrap_retired?, do: not is_nil(Repo.get(BootstrapState, @bootstrap_id))

  @spec create_service_credential(map()) :: {:ok, String.t(), ServiceCredential.t()} | {:error, Ecto.Changeset.t()}
  def create_service_credential(attrs) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    changeset =
      ServiceCredential.changeset(%ServiceCredential{}, %{
        name: Map.fetch!(attrs, :name),
        token_hash: token_hash(token),
        roles: Map.fetch!(attrs, :roles),
        scopes: Map.get(attrs, :scopes, [])
      })

    case Repo.insert(changeset) do
      {:ok, credential} -> {:ok, token, credential}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec verify_service_token(String.t()) :: {:ok, SymphonyElixir.Identity.Principal.t()} | {:error, :unauthorized}
  def verify_service_token(token) when is_binary(token) do
    hash = token_hash(token)

    ServiceCredential
    |> where([credential], is_nil(credential.revoked_at))
    |> Repo.all()
    |> Enum.find(&Plug.Crypto.secure_compare(&1.token_hash, hash))
    |> case do
      %ServiceCredential{} = credential ->
        now = DateTime.utc_now()
        credential |> ServiceCredential.changeset(%{last_used_at: now}) |> Repo.update()
        {:ok, ServiceCredential.principal(credential)}

      nil ->
        {:error, :unauthorized}
    end
  end

  def verify_service_token(_token), do: {:error, :unauthorized}

  @spec revoke_service_credential(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def revoke_service_credential(id) do
    case Repo.get(ServiceCredential, id) do
      %ServiceCredential{} = credential ->
        now = DateTime.utc_now()
        credential |> ServiceCredential.changeset(%{revoked_at: now}) |> Repo.update!()
        :ok

      nil ->
        {:error, :not_found}
    end
  end

  defp maybe_retire_bootstrap!(principal, now) do
    if :administrator in principal.roles and not bootstrap_retired?() do
      %BootstrapState{}
      |> BootstrapState.changeset(%{
        id: @bootstrap_id,
        oidc_activated_at: now,
        administrator_principal_id: principal.id
      })
      |> Repo.insert!()
    end
  end

  defp default_roles do
    if bootstrap_retired?(), do: [:viewer], else: [:administrator]
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)
end
