defmodule SymphonyElixir.Coordination.TaskProjection do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:task_id, :binary_id, autogenerate: false}

  schema "coordination_task_projections" do
    field(:idempotency_key, :string)
    field(:idempotency_hash, :string)
    field(:external_id, :string)
    field(:stream_version, :integer)
    field(:status, :string)
    field(:plan_revision, :string)
    field(:configuration_revision, :string)
    field(:baseline, :string)
    field(:correlation_id, :string)
    field(:data, :map)
    field(:effect, :map)
    field(:effect_status, :string)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [
    :task_id,
    :idempotency_key,
    :idempotency_hash,
    :external_id,
    :stream_version,
    :status,
    :plan_revision,
    :configuration_revision,
    :baseline,
    :correlation_id,
    :data,
    :effect,
    :effect_status,
    :created_at,
    :updated_at
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(projection, attrs) do
    projection
    |> cast(attrs, @fields)
    |> validate_required([
      :task_id,
      :idempotency_key,
      :idempotency_hash,
      :stream_version,
      :status,
      :correlation_id,
      :data,
      :created_at,
      :updated_at
    ])
    |> unique_constraint(:idempotency_key)
  end

  @spec attributes(t()) :: map()
  def attributes(projection) do
    Map.take(projection, @fields)
  end
end
