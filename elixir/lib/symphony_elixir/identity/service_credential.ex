defmodule SymphonyElixir.Identity.ServiceCredential do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Identity.{Principal, RoleList, StringList}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "identity_service_credentials" do
    field(:name, :string)
    field(:token_hash, :binary)
    field(:roles, RoleList)
    field(:scopes, StringList)
    field(:revoked_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :token_hash, :roles, :scopes, :revoked_at, :last_used_at])
    |> validate_required([:name, :token_hash, :roles, :scopes])
    |> validate_length(:name, min: 1, max: 128)
    |> unique_constraint(:token_hash)
  end

  @spec principal(t()) :: Principal.t()
  def principal(record) do
    %Principal{
      id: "service:#{record.id}",
      subject: record.name,
      roles: record.roles || [],
      service?: true,
      scopes: record.scopes || []
    }
  end
end
