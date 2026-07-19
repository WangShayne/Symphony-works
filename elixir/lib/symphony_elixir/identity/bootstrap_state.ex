defmodule SymphonyElixir.Identity.BootstrapState do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "identity_bootstrap_state" do
    field(:oidc_activated_at, :utc_datetime_usec)
    field(:administrator_principal_id, Ecto.UUID)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:id, :oidc_activated_at, :administrator_principal_id])
    |> validate_required([:id, :oidc_activated_at, :administrator_principal_id])
  end
end
