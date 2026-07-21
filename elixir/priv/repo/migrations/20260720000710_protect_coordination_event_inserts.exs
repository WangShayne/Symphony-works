defmodule SymphonyElixir.Repo.Migrations.ProtectCoordinationEventInserts do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TRIGGER coordination_events_prevent_conflicting_insert
    BEFORE INSERT ON coordination_events
    WHEN EXISTS (
      SELECT 1
      FROM coordination_events AS existing
      WHERE existing.id = NEW.id
         OR (
           NEW.rowid != -1
           AND existing.rowid = NEW.rowid
         )
         OR (
           existing.task_id = NEW.task_id
           AND existing.stream_version = NEW.stream_version
         )
    )
    BEGIN
      SELECT RAISE(ABORT, 'coordination events are append-only');
    END;
    """)

    execute("""
    CREATE TRIGGER coordination_events_prevent_reserved_rowid
    AFTER INSERT ON coordination_events
    WHEN NEW.rowid = -1
    BEGIN
      SELECT RAISE(ABORT, 'coordination events are append-only');
    END;
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS coordination_events_prevent_reserved_rowid")
    execute("DROP TRIGGER IF EXISTS coordination_events_prevent_conflicting_insert")
  end
end
