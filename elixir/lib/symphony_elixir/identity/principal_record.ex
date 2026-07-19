defmodule SymphonyElixir.Identity.PrincipalRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Identity.{Principal, RoleList}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "identity_principals" do
    field(:issuer, :string)
    field(:subject, :string)
    field(:email, :string)
    field(:display_name, :string)
    field(:roles, RoleList)
    field(:last_authenticated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:issuer, :subject, :email, :display_name, :roles, :last_authenticated_at])
    |> validate_required([:issuer, :subject, :roles])
    |> validate_length(:issuer, min: 1, max: 512)
    |> validate_length(:subject, min: 1, max: 512)
    |> unique_constraint([:issuer, :subject])
  end

  @spec principal(t()) :: Principal.t()
  def principal(record) do
    %Principal{
      id: record.id,
      issuer: record.issuer,
      subject: record.subject,
      email: record.email,
      display_name: record.display_name,
      roles: record.roles || []
    }
  end
end
