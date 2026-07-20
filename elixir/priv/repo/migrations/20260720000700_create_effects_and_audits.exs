defmodule SymphonyElixir.Repo.Migrations.CreateEffectsAndAudits do
  use Ecto.Migration

  def up do
    create table(:effect_records, primary_key: false) do
      add(:operation_id, :binary_id, primary_key: true, null: false)
      add(:dedupe_hash, :string, null: false)
      add(:task_id, :string, null: false)
      add(:plan_revision, :integer, null: false)
      add(:unit_id, :string)
      add(:action, :string, null: false)
      add(:provider, :string, null: false)
      add(:target, :string, null: false)
      add(:intent, :map, null: false)
      add(:status, :string, null: false, default: "planned")
      add(:result, :map)
      add(:error, :map)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:effect_records, [:dedupe_hash]))
    create(index(:effect_records, [:task_id, :status]))
    create(index(:effect_records, [:status]))
    create(index(:effect_records, [:status, :started_at, :operation_id]))

    create table(:audit_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true, null: false)
      add(:actor, :map, null: false)
      add(:action, :string, null: false)
      add(:target, :map, null: false)
      add(:task_id, :string)
      add(:configuration_revision, :string)
      add(:plan_revision, :integer)
      add(:outcome, :string, null: false)
      add(:correlation_id, :string, null: false)
      add(:dedupe_key, :string)
      add(:payload, :map, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:audit_events, [:task_id, :inserted_at]))
    create(index(:audit_events, [:correlation_id]))
    create(index(:audit_events, [:action, :inserted_at]))
    create(unique_index(:audit_events, [:dedupe_key], where: "dedupe_key IS NOT NULL"))

    execute("""
    CREATE TRIGGER audit_events_prevent_update
    BEFORE UPDATE ON audit_events
    BEGIN
      SELECT RAISE(ABORT, 'audit events are append-only');
    END;
    """)

    execute("""
    CREATE TRIGGER audit_events_prevent_delete
    BEFORE DELETE ON audit_events
    BEGIN
      SELECT RAISE(ABORT, 'audit events are append-only');
    END;
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS audit_events_prevent_delete")
    execute("DROP TRIGGER IF EXISTS audit_events_prevent_update")
    drop(table(:audit_events))
    drop(table(:effect_records))
  end
end
