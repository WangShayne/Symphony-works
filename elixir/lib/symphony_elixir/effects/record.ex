defmodule SymphonyElixir.Effects.Record do
  @moduledoc """
  Durable intent and observed outcome for one external mutation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:operation_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @statuses [:planned, :started, :unknown, :succeeded, :failed]

  schema "effect_records" do
    field(:dedupe_hash, :string)
    field(:task_id, :string)
    field(:plan_revision, :integer)
    field(:unit_id, :string)
    field(:action, :string)
    field(:provider, :string)
    field(:target, :string)
    field(:intent, :map, default: %{})
    field(:status, Ecto.Enum, values: @statuses, default: :planned)
    field(:result, :map)
    field(:error, :map)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type status :: :planned | :started | :unknown | :succeeded | :failed

  @type t :: %__MODULE__{
          operation_id: Ecto.UUID.t() | nil,
          dedupe_hash: String.t() | nil,
          task_id: String.t() | nil,
          plan_revision: non_neg_integer() | nil,
          unit_id: String.t() | nil,
          action: String.t() | nil,
          provider: String.t() | nil,
          target: String.t() | nil,
          intent: map(),
          status: status(),
          result: map() | nil,
          error: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          lease_owner: String.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :operation_id,
      :dedupe_hash,
      :task_id,
      :plan_revision,
      :unit_id,
      :action,
      :provider,
      :target,
      :intent,
      :status
    ])
    |> validate_required([
      :operation_id,
      :dedupe_hash,
      :task_id,
      :plan_revision,
      :action,
      :provider,
      :target,
      :intent,
      :status
    ])
    |> validate_number(:plan_revision, greater_than_or_equal_to: 0)
    |> validate_length(:dedupe_hash, is: 64)
    |> validate_length(:task_id, min: 1, max: 255)
    |> validate_length(:unit_id, max: 255)
    |> validate_length(:action, min: 1, max: 128)
    |> validate_length(:provider, min: 1, max: 128)
    |> validate_length(:target, min: 1, max: 2_048)
    |> unique_constraint(:operation_id, name: :effect_records_operation_id_index)
    |> unique_constraint(:dedupe_hash)
  end
end
