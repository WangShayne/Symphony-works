defmodule SymphonyElixir.Security.Secret do
  @moduledoc """
  Encrypted credential row. Plaintext is never stored on this schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "secrets" do
    field(:name, :string)
    field(:ciphertext, :binary)
    field(:nonce, :binary)
    field(:tag, :binary)
    field(:key_version, :integer, default: 1)
    field(:created_by, :string)
    field(:updated_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          ciphertext: binary() | nil,
          nonce: binary() | nil,
          tag: binary() | nil,
          key_version: pos_integer() | nil,
          created_by: String.t() | nil,
          updated_by: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :ciphertext, :nonce, :tag, :key_version, :created_by, :updated_by])
    |> validate_required([
      :name,
      :ciphertext,
      :nonce,
      :tag,
      :key_version,
      :created_by,
      :updated_by
    ])
    |> validate_number(:key_version, greater_than: 0)
    |> validate_length(:name, min: 1, max: 128)
  end

  @spec replace_changeset(t(), map()) :: Ecto.Changeset.t()
  def replace_changeset(secret, attrs) do
    secret
    |> cast(attrs, [:ciphertext, :nonce, :tag, :key_version, :updated_by])
    |> validate_required([:ciphertext, :nonce, :tag, :key_version, :updated_by])
    |> validate_number(:key_version, greater_than: 0)
  end
end
