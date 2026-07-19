defmodule SymphonyElixir.Configuration.Revision do
  @moduledoc """
  Immutable configuration snapshot and its validation/activation metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "configuration_revisions" do
    field(:status, Ecto.Enum, values: [:draft, :validated, :active, :superseded], default: :draft)
    field(:schema_version, :integer)
    field(:document, :map)
    field(:content_hash, :string)
    field(:created_by, :string)
    field(:validated_by, :string)
    field(:validation_evidence, :map)
    field(:validated_at, :utc_datetime_usec)
    field(:activated_by, :string)
    field(:activated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type status :: :draft | :validated | :active | :superseded
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          status: status(),
          schema_version: integer() | nil,
          document: map() | nil,
          content_hash: String.t() | nil,
          created_by: String.t() | nil,
          validated_by: String.t() | nil,
          validation_evidence: map() | nil,
          validated_at: DateTime.t() | nil,
          activated_by: String.t() | nil,
          activated_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec draft_changeset(t(), map()) :: Ecto.Changeset.t()
  def draft_changeset(revision, attrs) do
    revision
    |> cast(attrs, [:document, :schema_version, :content_hash, :created_by])
    |> put_change(:status, :draft)
    |> validate_required([:document, :schema_version, :content_hash, :created_by])
  end

  @spec validation_changeset(t(), map()) :: Ecto.Changeset.t()
  def validation_changeset(revision, attrs) do
    revision
    |> cast(attrs, [:validated_by, :validation_evidence, :validated_at])
    |> put_change(:status, :validated)
    |> validate_required([:validated_by, :validation_evidence, :validated_at])
  end

  @spec activation_changeset(t(), map()) :: Ecto.Changeset.t()
  def activation_changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :validated_by,
      :validation_evidence,
      :validated_at,
      :activated_by,
      :activated_at
    ])
    |> put_change(:status, :active)
    |> validate_required([
      :validated_by,
      :validation_evidence,
      :validated_at,
      :activated_by,
      :activated_at
    ])
  end
end
