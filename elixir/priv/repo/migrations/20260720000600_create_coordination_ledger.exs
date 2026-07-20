defmodule SymphonyElixir.Repo.Migrations.CreateCoordinationLedger do
  use Ecto.Migration

  def change do
    create table(:coordination_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:task_id, :binary_id, null: false)
      add(:stream_version, :integer, null: false)
      add(:event_type, :string, null: false)
      add(:event_version, :integer, null: false)
      add(:actor_kind, :string, null: false)
      add(:actor_id, :string, null: false)
      add(:plan_revision, :string)
      add(:configuration_revision, :string)
      add(:correlation_id, :string, null: false)
      add(:data, :map, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:coordination_events, [:task_id, :stream_version]))
    create(index(:coordination_events, [:task_id, :occurred_at]))

    execute(
      """
      CREATE TRIGGER coordination_events_prevent_update
      BEFORE UPDATE ON coordination_events
      BEGIN
        SELECT RAISE(ABORT, 'coordination events are append-only');
      END;
      """,
      "DROP TRIGGER IF EXISTS coordination_events_prevent_update"
    )

    execute(
      """
      CREATE TRIGGER coordination_events_prevent_delete
      BEFORE DELETE ON coordination_events
      BEGIN
        SELECT RAISE(ABORT, 'coordination events are append-only');
      END;
      """,
      "DROP TRIGGER IF EXISTS coordination_events_prevent_delete"
    )

    create table(:coordination_task_projections, primary_key: false) do
      add(:task_id, :binary_id, primary_key: true)
      add(:idempotency_key, :string, null: false)
      add(:idempotency_hash, :string, null: false)
      add(:external_id, :string)
      add(:stream_version, :integer, null: false)
      add(:status, :string, null: false)
      add(:plan_revision, :string)
      add(:configuration_revision, :string)
      add(:baseline, :string)
      add(:correlation_id, :string, null: false)
      add(:data, :map, null: false)
      add(:effect, :map)
      add(:effect_status, :string)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:coordination_task_projections, [:idempotency_key]))
    create(index(:coordination_task_projections, [:status]))
    create(index(:coordination_task_projections, [:updated_at]))

    create table(:coordination_unit_projections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:task_id, :binary_id, null: false)
      add(:unit_id, :string, null: false)
      add(:stream_version, :integer, null: false)
      add(:status, :string, null: false)
      add(:task_type, :string)
      add(:execution_profile, :string)
      add(:dependencies, :map, null: false)
      add(:data, :map, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:coordination_unit_projections, [:task_id, :unit_id]))
    create(index(:coordination_unit_projections, [:task_id, :status]))

    create table(:coordination_leases, primary_key: false) do
      add(:name, :string, primary_key: true)
      add(:holder_id, :string, null: false)
      add(:token, :binary_id, null: false)
      add(:ttl_ms, :integer, null: false)
      add(:heartbeat_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:coordination_leases, [:token]))
    create(index(:coordination_leases, [:expires_at]))
  end
end
