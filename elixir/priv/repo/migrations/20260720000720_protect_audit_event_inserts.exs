defmodule SymphonyElixir.Repo.Migrations.ProtectAuditEventInserts do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TRIGGER audit_events_prevent_conflicting_insert
    BEFORE INSERT ON audit_events
    WHEN EXISTS (
      SELECT 1
      FROM audit_events AS existing
      WHERE existing.id = NEW.id
         OR (
           NEW.rowid != -1
           AND existing.rowid = NEW.rowid
         )
         OR (
           NEW.dedupe_key IS NOT NULL
           AND existing.dedupe_key = NEW.dedupe_key
         )
    )
    BEGIN
      SELECT RAISE(ABORT, 'audit events are append-only');
    END;
    """)

    execute("""
    CREATE TRIGGER audit_events_prevent_reserved_rowid
    AFTER INSERT ON audit_events
    WHEN NEW.rowid = -1
    BEGIN
      SELECT RAISE(ABORT, 'audit events are append-only');
    END;
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS audit_events_prevent_reserved_rowid")
    execute("DROP TRIGGER IF EXISTS audit_events_prevent_conflicting_insert")
  end
end
