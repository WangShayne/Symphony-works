defmodule SymphonyElixir.Configuration.TaskPin do
  @moduledoc """
  Task-level immutable configuration pin.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "configuration_task_pins" do
    field(:task_id, :string)
    field(:revision_id, :binary_id)
    field(:content_hash, :string)
    field(:document, :map)
    field(:pinned_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          task_id: String.t() | nil,
          revision_id: Ecto.UUID.t() | nil,
          content_hash: String.t() | nil,
          document: map() | nil,
          pinned_by: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [:task_id, :revision_id, :content_hash, :document, :pinned_by])
    |> validate_required([:task_id, :revision_id, :content_hash, :document, :pinned_by])
    |> unique_constraint(:task_id)
  end
end
