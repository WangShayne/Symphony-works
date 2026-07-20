defmodule SymphonyElixir.Coordination.UnitProjection do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "coordination_unit_projections" do
    field(:task_id, :binary_id)
    field(:unit_id, :string)
    field(:stream_version, :integer)
    field(:status, :string)
    field(:task_type, :string)
    field(:execution_profile, :string)
    field(:dependencies, :map)
    field(:data, :map)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [
    :task_id,
    :unit_id,
    :stream_version,
    :status,
    :task_type,
    :execution_profile,
    :dependencies,
    :data,
    :created_at,
    :updated_at
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(projection, attrs) do
    projection
    |> cast(attrs, @fields)
    |> validate_required([
      :task_id,
      :unit_id,
      :stream_version,
      :status,
      :dependencies,
      :data,
      :created_at,
      :updated_at
    ])
    |> unique_constraint([:task_id, :unit_id])
  end

  @spec attributes(t()) :: map()
  def attributes(projection), do: Map.take(projection, @fields)
end
