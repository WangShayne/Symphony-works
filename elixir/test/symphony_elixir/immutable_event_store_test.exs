defmodule SymphonyElixir.ImmutableEventStoreTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.{Audit, Coordination, Repo}

  @coordination_event_insert """
  INSERT INTO coordination_events (
    id,
    task_id,
    stream_version,
    event_type,
    event_version,
    actor_kind,
    actor_id,
    correlation_id,
    data,
    occurred_at,
    inserted_at
  ) VALUES (?, ?, ?, ?, 1, 'service', 'orchestrator', ?, ?, ?, ?)
  """

  @audit_event_insert """
  INSERT INTO audit_events (
    id,
    actor,
    action,
    target,
    task_id,
    configuration_revision,
    plan_revision,
    outcome,
    correlation_id,
    dedupe_key,
    payload,
    inserted_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """

  @coordination_rowid_replace """
  INSERT OR REPLACE INTO coordination_events (
    rowid,
    id,
    task_id,
    stream_version,
    event_type,
    event_version,
    actor_kind,
    actor_id,
    correlation_id,
    data,
    occurred_at,
    inserted_at
  ) VALUES (?, ?, ?, ?, ?, 1, 'service', 'orchestrator', ?, ?, ?, ?)
  """

  @audit_rowid_replace """
  INSERT OR REPLACE INTO audit_events (
    rowid,
    id,
    actor,
    action,
    target,
    task_id,
    configuration_revision,
    plan_revision,
    outcome,
    correlation_id,
    dedupe_key,
    payload,
    inserted_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """

  @migrations [
    {20_260_720_000_100, SymphonyElixir.Repo.Migrations.CreateSystemMetadata},
    {20_260_720_000_200, SymphonyElixir.Repo.Migrations.CreateConfigurationRevisions},
    {20_260_720_000_210, SymphonyElixir.Repo.Migrations.CreateConfigurationTaskPins},
    {20_260_720_000_400, SymphonyElixir.Repo.Migrations.CreateSecrets},
    {20_260_720_000_500, SymphonyElixir.Repo.Migrations.CreateIdentityBootstrap},
    {20_260_720_000_600, SymphonyElixir.Repo.Migrations.CreateCoordinationLedger},
    {20_260_720_000_700, SymphonyElixir.Repo.Migrations.CreateEffectsAndAudits},
    {20_260_720_000_710, SymphonyElixir.Repo.Migrations.ProtectCoordinationEventInserts},
    {20_260_720_000_720, SymphonyElixir.Repo.Migrations.ProtectAuditEventInserts}
  ]

  test "coordination events reject replacement and upsert conflicts without changing history" do
    event_id = uuid_binary()
    task_id = uuid_binary()
    inserted_at = "2026-07-22 00:00:00.000000"

    params =
      coordination_event_params(
        event_id,
        task_id,
        1,
        "task_created",
        "coordination-original",
        ~s({"version":1}),
        inserted_at
      )

    assert {:ok, _result} = Repo.query(@coordination_event_insert, params)
    original = coordination_event_state()

    assert_append_only_error(
      "UPDATE coordination_events SET event_type = ? WHERE id = ?",
      ["task_updated", event_id],
      original,
      "coordination events are append-only"
    )

    assert_append_only_error(
      "DELETE FROM coordination_events WHERE id = ?",
      [event_id],
      original,
      "coordination events are append-only"
    )

    assert_append_only_error(
      String.replace(@coordination_event_insert, "INSERT INTO", "INSERT OR REPLACE INTO"),
      coordination_event_params(
        event_id,
        uuid_binary(),
        2,
        "task_replaced_by_id",
        "coordination-replace-id",
        ~s({"version":2}),
        inserted_at
      ),
      original,
      "coordination events are append-only"
    )

    assert_append_only_error(
      String.replace(@coordination_event_insert, "INSERT INTO", "REPLACE INTO"),
      coordination_event_params(
        uuid_binary(),
        task_id,
        1,
        "task_replaced_by_stream",
        "coordination-replace-stream",
        ~s({"version":3}),
        inserted_at
      ),
      original,
      "coordination events are append-only"
    )

    assert_append_only_error(
      @coordination_event_insert <>
        " ON CONFLICT(task_id, stream_version) DO UPDATE SET event_type = excluded.event_type",
      coordination_event_params(
        uuid_binary(),
        task_id,
        1,
        "task_upserted",
        "coordination-upsert",
        ~s({"version":4}),
        inserted_at
      ),
      original,
      "coordination events are append-only"
    )
  end

  test "audit events reject replacement and upsert conflicts without changing history" do
    event_id = uuid_binary()
    dedupe_key = "audit:#{Ecto.UUID.generate()}"
    inserted_at = "2026-07-22 00:00:00.000000"

    params =
      audit_event_params(
        event_id,
        "task_created",
        "succeeded",
        "audit-original",
        dedupe_key,
        ~s({"version":1}),
        inserted_at
      )

    assert {:ok, _result} = Repo.query(@audit_event_insert, params)
    original = audit_event_state()

    assert_audit_append_only_error(
      String.replace(@audit_event_insert, "INSERT INTO", "INSERT OR REPLACE INTO"),
      audit_event_params(
        event_id,
        "task_replaced_by_id",
        "failed",
        "audit-replace-id",
        "audit:#{Ecto.UUID.generate()}",
        ~s({"version":2}),
        inserted_at
      ),
      original
    )

    assert_audit_append_only_error(
      String.replace(@audit_event_insert, "INSERT INTO", "REPLACE INTO"),
      audit_event_params(
        uuid_binary(),
        "task_replaced_by_dedupe",
        "failed",
        "audit-replace-dedupe",
        dedupe_key,
        ~s({"version":3}),
        inserted_at
      ),
      original
    )

    assert_audit_append_only_error(
      @audit_event_insert <>
        " ON CONFLICT(id) DO UPDATE SET outcome = excluded.outcome",
      audit_event_params(
        event_id,
        "task_upserted",
        "failed",
        "audit-upsert",
        "audit:#{Ecto.UUID.generate()}",
        ~s({"version":4}),
        inserted_at
      ),
      original
    )
  end

  test "event tables reject hidden rowid replacement with recursive triggers off and on" do
    inserted_at = "2026-07-22 00:00:00.000000"
    coordination_id = uuid_binary()
    audit_id = uuid_binary()

    assert {:ok, _result} =
             Repo.query(
               @coordination_event_insert,
               coordination_event_params(
                 coordination_id,
                 uuid_binary(),
                 1,
                 "task_created",
                 "coordination-rowid-original",
                 ~s({"version":1}),
                 inserted_at
               )
             )

    assert {:ok, _result} =
             Repo.query(
               @audit_event_insert,
               audit_event_params(
                 audit_id,
                 "task_created",
                 "succeeded",
                 "audit-rowid-original",
                 "audit-rowid-original:#{Ecto.UUID.generate()}",
                 ~s({"version":1}),
                 inserted_at
               )
             )

    [[coordination_rowid]] =
      Repo.query!("SELECT rowid FROM coordination_events WHERE id = ?", [coordination_id]).rows

    [[audit_rowid]] = Repo.query!("SELECT rowid FROM audit_events WHERE id = ?", [audit_id]).rows

    coordination_original = coordination_event_state()
    audit_original = audit_event_state()
    [[original_recursive_triggers]] = Repo.query!("PRAGMA recursive_triggers").rows

    try do
      for recursive_triggers <- [0, 1] do
        set_recursive_triggers!(recursive_triggers)

        assert_append_only_error(
          @coordination_rowid_replace,
          [
            coordination_rowid
            | coordination_event_params(
                uuid_binary(),
                uuid_binary(),
                100 + recursive_triggers,
                "task_replaced_by_rowid",
                "coordination-rowid-replace-#{recursive_triggers}",
                ~s({"version":2}),
                inserted_at
              )
          ],
          coordination_original,
          "coordination events are append-only"
        )

        assert_audit_append_only_error(
          @audit_rowid_replace,
          [
            audit_rowid
            | audit_event_params(
                uuid_binary(),
                "task_replaced_by_rowid",
                "failed",
                "audit-rowid-replace-#{recursive_triggers}",
                "audit-rowid-replace:#{recursive_triggers}:#{Ecto.UUID.generate()}",
                ~s({"version":2}),
                inserted_at
              )
          ],
          audit_original
        )

        assert_append_only_error(
          @coordination_rowid_replace,
          [
            -1
            | coordination_event_params(
                uuid_binary(),
                uuid_binary(),
                200 + recursive_triggers,
                "task_inserted_with_reserved_rowid",
                "coordination-reserved-rowid-#{recursive_triggers}",
                ~s({"version":3}),
                inserted_at
              )
          ],
          coordination_original,
          "coordination events are append-only"
        )

        assert_audit_append_only_error(
          @audit_rowid_replace,
          [
            -1
            | audit_event_params(
                uuid_binary(),
                "task_inserted_with_reserved_rowid",
                "failed",
                "audit-reserved-rowid-#{recursive_triggers}",
                "audit-reserved-rowid:#{recursive_triggers}:#{Ecto.UUID.generate()}",
                ~s({"version":3}),
                inserted_at
              )
          ],
          audit_original
        )
      end
    after
      set_recursive_triggers!(original_recursive_triggers)
    end
  end

  test "legacy rowid minus one remains writable after the guard migration without enabling replacement" do
    database =
      Path.join(
        System.tmp_dir!(),
        "symphony-append-only-upgrade-#{System.unique_integer([:positive])}.db"
      )

    {:ok, repo_pid} =
      Repo.start_link(
        name: nil,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous_dynamic_repo = Repo.put_dynamic_repo(repo_pid)

    try do
      Ecto.Migrator.run(Repo, @migrations, :up,
        to: 20_260_720_000_700,
        dynamic_repo: repo_pid
      )

      migrated_versions = Ecto.Migrator.migrated_versions(Repo, dynamic_repo: repo_pid)
      assert Enum.max(migrated_versions) == 20_260_720_000_700

      trigger_names =
        Repo.query!("SELECT name FROM sqlite_master WHERE type = 'trigger'").rows
        |> List.flatten()

      refute "coordination_events_prevent_conflicting_insert" in trigger_names
      refute "audit_events_prevent_conflicting_insert" in trigger_names
      refute "coordination_events_prevent_reserved_rowid" in trigger_names
      refute "audit_events_prevent_reserved_rowid" in trigger_names
      assert %{rows: [[0]]} = Repo.query!("SELECT COUNT(*) FROM coordination_events")
      assert %{rows: [[0]]} = Repo.query!("SELECT COUNT(*) FROM audit_events")

      inserted_at = "2026-07-22 00:00:00.000000"
      legacy_coordination_id = uuid_binary()
      legacy_audit_id = uuid_binary()

      assert {:ok, _result} =
               Repo.query(
                 @coordination_rowid_replace,
                 [
                   -1
                   | coordination_event_params(
                       legacy_coordination_id,
                       uuid_binary(),
                       1,
                       "legacy_task_created",
                       "legacy-coordination-rowid",
                       ~s({"version":1}),
                       inserted_at
                     )
                 ]
               )

      assert {:ok, _result} =
               Repo.query(
                 @audit_rowid_replace,
                 [
                   -1
                   | audit_event_params(
                       legacy_audit_id,
                       "legacy_task_created",
                       "succeeded",
                       "legacy-audit-rowid",
                       "legacy-audit-rowid:#{Ecto.UUID.generate()}",
                       ~s({"version":1}),
                       inserted_at
                     )
                 ]
               )

      Ecto.Migrator.run(Repo, @migrations, :up, all: true, dynamic_repo: repo_pid)
      set_recursive_triggers!(0)

      assert {:ok, _result} =
               Repo.query(
                 @coordination_event_insert,
                 coordination_event_params(
                   uuid_binary(),
                   uuid_binary(),
                   2,
                   "task_created_after_upgrade",
                   "coordination-after-upgrade",
                   ~s({"version":2}),
                   inserted_at
                 )
               )

      assert {:ok, _result} =
               Repo.query(
                 @audit_event_insert,
                 audit_event_params(
                   uuid_binary(),
                   "task_created_after_upgrade",
                   "succeeded",
                   "audit-after-upgrade",
                   "audit-after-upgrade:#{Ecto.UUID.generate()}",
                   ~s({"version":2}),
                   inserted_at
                 )
               )

      coordination_before = coordination_event_state()
      audit_before = audit_event_state()

      assert_append_only_error(
        @coordination_rowid_replace,
        [
          -1
          | coordination_event_params(
              uuid_binary(),
              uuid_binary(),
              3,
              "legacy_task_replaced_by_rowid",
              "legacy-coordination-replace",
              ~s({"version":3}),
              inserted_at
            )
        ],
        coordination_before,
        "coordination events are append-only"
      )

      assert_audit_append_only_error(
        @audit_rowid_replace,
        [
          -1
          | audit_event_params(
              uuid_binary(),
              "legacy_task_replaced_by_rowid",
              "failed",
              "legacy-audit-replace",
              "legacy-audit-replace:#{Ecto.UUID.generate()}",
              ~s({"version":3}),
              inserted_at
            )
        ],
        audit_before
      )
    after
      Repo.put_dynamic_repo(previous_dynamic_repo)
      GenServer.stop(repo_pid)
      File.rm(database)
      File.rm(database <> "-shm")
      File.rm(database <> "-wal")
    end
  end

  test "append-only conflict handling does not hide unrelated storage failures" do
    Repo.query!("ALTER TABLE coordination_events RENAME TO unavailable_coordination_events")

    assert_raise Exqlite.Error, ~r/no such table: coordination_events/, fn ->
      Coordination.start_task(%{
        idempotency_key: "unavailable-coordination:#{Ecto.UUID.generate()}",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef"
      })
    end

    Repo.query!("ALTER TABLE unavailable_coordination_events RENAME TO coordination_events")
    Repo.query!("ALTER TABLE audit_events RENAME TO unavailable_audit_events")

    assert_raise Exqlite.Error, ~r/no such table: audit_events/, fn ->
      Audit.record(
        :task_created,
        %{
          target: %{type: "task", id: "task-storage-failure"},
          correlation_id: "audit-storage-failure",
          dedupe_key: "audit-storage-failure:#{Ecto.UUID.generate()}"
        },
        %{type: "service", id: "orchestrator"}
      )
    end
  end

  defp assert_append_only_error(sql, params, original, message) do
    assert {:error, error} = Repo.query(sql, params)
    assert Exception.message(error) =~ message
    assert coordination_event_state() == original
  end

  defp coordination_event_state do
    result =
      Repo.query!(
        "SELECT rowid, id, task_id, stream_version, event_type, event_version, actor_kind, actor_id, " <>
          "plan_revision, configuration_revision, correlation_id, data, occurred_at, inserted_at " <>
          "FROM coordination_events ORDER BY rowid",
        []
      )

    {result.num_rows, result.rows}
  end

  defp assert_audit_append_only_error(sql, params, original) do
    assert {:error, error} = Repo.query(sql, params)
    assert Exception.message(error) =~ "audit events are append-only"
    assert audit_event_state() == original
  end

  defp audit_event_state do
    result =
      Repo.query!(
        "SELECT rowid, id, actor, action, target, task_id, configuration_revision, plan_revision, " <>
          "outcome, correlation_id, dedupe_key, payload, inserted_at " <>
          "FROM audit_events ORDER BY rowid",
        []
      )

    {result.num_rows, result.rows}
  end

  defp coordination_event_params(
         id,
         task_id,
         stream_version,
         event_type,
         correlation_id,
         data,
         inserted_at
       ) do
    [
      id,
      task_id,
      stream_version,
      event_type,
      correlation_id,
      data,
      inserted_at,
      inserted_at
    ]
  end

  defp audit_event_params(
         id,
         action,
         outcome,
         correlation_id,
         dedupe_key,
         payload,
         inserted_at
       ) do
    [
      id,
      ~s({"id":"orchestrator","type":"service"}),
      action,
      ~s({"id":"task-immutable","type":"task"}),
      "task-immutable",
      "configuration-1",
      1,
      outcome,
      correlation_id,
      dedupe_key,
      payload,
      inserted_at
    ]
  end

  defp set_recursive_triggers!(0) do
    assert %{rows: []} = Repo.query!("PRAGMA recursive_triggers = OFF")
    assert %{rows: [[0]]} = Repo.query!("PRAGMA recursive_triggers")
  end

  defp set_recursive_triggers!(1) do
    assert %{rows: []} = Repo.query!("PRAGMA recursive_triggers = ON")
    assert %{rows: [[1]]} = Repo.query!("PRAGMA recursive_triggers")
  end

  defp uuid_binary do
    Ecto.UUID.generate()
    |> Ecto.UUID.dump!()
  end
end
