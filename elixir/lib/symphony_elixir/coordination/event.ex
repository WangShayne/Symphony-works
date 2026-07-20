defmodule SymphonyElixir.Coordination.Event do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "coordination_events" do
    field(:task_id, :binary_id)
    field(:stream_version, :integer)
    field(:event_type, :string)
    field(:event_version, :integer)
    field(:actor_kind, :string)
    field(:actor_id, :string)
    field(:plan_revision, :string)
    field(:configuration_revision, :string)
    field(:correlation_id, :string)
    field(:data, :map)
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :task_id,
      :stream_version,
      :event_type,
      :event_version,
      :actor_kind,
      :actor_id,
      :plan_revision,
      :configuration_revision,
      :correlation_id,
      :data,
      :occurred_at
    ])
    |> validate_required([
      :task_id,
      :stream_version,
      :event_type,
      :event_version,
      :actor_kind,
      :actor_id,
      :correlation_id,
      :data,
      :occurred_at
    ])
    |> unique_constraint([:task_id, :stream_version])
  end
end
