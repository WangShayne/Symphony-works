defmodule SymphonyElixir.Audit.Event do
  @moduledoc """
  Immutable, redacted audit event.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "audit_events" do
    field(:actor, :map)
    field(:action, :string)
    field(:target, :map)
    field(:task_id, :string)
    field(:configuration_revision, :string)
    field(:plan_revision, :integer)
    field(:outcome, :string)
    field(:correlation_id, :string)
    field(:dedupe_key, :string)
    field(:payload, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          actor: map() | nil,
          action: String.t() | nil,
          target: map() | nil,
          task_id: String.t() | nil,
          configuration_revision: String.t() | nil,
          plan_revision: non_neg_integer() | nil,
          outcome: String.t() | nil,
          correlation_id: String.t() | nil,
          dedupe_key: String.t() | nil,
          payload: map(),
          inserted_at: DateTime.t() | nil
        }

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :actor,
      :action,
      :target,
      :task_id,
      :configuration_revision,
      :plan_revision,
      :outcome,
      :correlation_id,
      :dedupe_key,
      :payload
    ])
    |> validate_required([:id, :actor, :action, :target, :outcome, :correlation_id, :payload])
    |> validate_number(:plan_revision, greater_than_or_equal_to: 0)
    |> validate_length(:action, min: 1, max: 128)
    |> validate_length(:task_id, max: 255)
    |> validate_length(:configuration_revision, max: 255)
    |> validate_length(:outcome, min: 1, max: 128)
    |> validate_length(:correlation_id, min: 1, max: 255)
    |> validate_length(:dedupe_key, min: 1, max: 255)
    |> unique_constraint(:dedupe_key)
  end
end
