defmodule SymphonyElixir.Repo.Migrations.CreateIdentityBootstrap do
  use Ecto.Migration

  def change do
    create table(:identity_principals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:issuer, :string, null: false)
      add(:subject, :string, null: false)
      add(:email, :string)
      add(:display_name, :string)
      add(:roles, :text, null: false)
      add(:last_authenticated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:identity_principals, [:issuer, :subject]))

    create table(:identity_service_credentials, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:token_hash, :binary, null: false)
      add(:roles, :text, null: false)
      add(:scopes, :text, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:last_used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:identity_service_credentials, [:token_hash]))
    create(index(:identity_service_credentials, [:name]))

    create table(:identity_bootstrap_state, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:oidc_activated_at, :utc_datetime_usec, null: false)
      add(:administrator_principal_id, references(:identity_principals, type: :binary_id), null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
