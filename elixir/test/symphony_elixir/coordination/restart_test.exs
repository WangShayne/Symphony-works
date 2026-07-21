defmodule SymphonyElixir.Coordination.RestartTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  import Ecto.Query

  alias SymphonyElixir.{Audit, Coordination}
  alias SymphonyElixir.Coordination.{Event, TaskProjection, UnitProjection}
  alias SymphonyElixir.Repo

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      unless Process.whereis(Repo) do
        {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
      end

      Sandbox.mode(Repo, :auto)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "task and unit snapshots survive a supervised Repo restart" do
    {:ok, task} =
      Coordination.start_task(%{
        idempotency_key: "restart:#{Ecto.UUID.generate()}",
        external_id: "RESTART-1",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef"
      })

    on_exit(fn -> delete_projections(task.id) end)

    assert {:ok, 2} =
             Coordination.append(task.id, 1, [
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "docs-1",
                   task_type: "documentation",
                   execution_profile: "docs-default",
                   dependencies: []
                 }
               }
             ])

    assert {:ok, before} = Coordination.snapshot(task.id)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert {:ok, ^before} = Coordination.snapshot(task.id)
  end

  test "immutable event guards survive a supervised Repo restart" do
    {:ok, task} =
      Coordination.start_task(%{
        idempotency_key: "restart-immutable:#{Ecto.UUID.generate()}",
        external_id: "RESTART-IMMUTABLE",
        config_revision_id: Ecto.UUID.generate(),
        baseline: "0123456789abcdef"
      })

    {:ok, audit_event} =
      Audit.record(
        :task_created,
        %{
          task_id: task.id,
          target: %{type: "task", id: task.id},
          outcome: :succeeded,
          correlation_id: "restart-immutable:#{task.id}",
          summary: %{event: "task_created"}
        },
        %{type: "service", id: "orchestrator"}
      )

    coordination_event_id =
      Repo.one!(from(event in Event, where: event.task_id == ^task.id, select: event.id))

    coordination_before = immutable_row_state("coordination_events", coordination_event_id)
    audit_before = immutable_row_state("audit_events", audit_event.id)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert %{rows: [[1]]} = Repo.query!("PRAGMA foreign_keys")
    assert %{rows: [["wal"]]} = Repo.query!("PRAGMA journal_mode")

    assert {:error, coordination_error} =
             Repo.query(
               """
               INSERT OR REPLACE INTO coordination_events (
                 id,
                 task_id,
                 stream_version,
                 event_type,
                 event_version,
                 actor_kind,
                 actor_id,
                 plan_revision,
                 configuration_revision,
                 correlation_id,
                 data,
                 occurred_at,
                 inserted_at
               )
               SELECT
                 id,
                 task_id,
                 stream_version,
                 'replaced_after_restart',
                 event_version,
                 actor_kind,
                 actor_id,
                 plan_revision,
                 configuration_revision,
                 correlation_id,
                 data,
                 occurred_at,
                 inserted_at
               FROM coordination_events
               WHERE id = ?
               """,
               [coordination_event_id]
             )

    assert Exception.message(coordination_error) =~ "coordination events are append-only"

    assert immutable_row_state("coordination_events", coordination_event_id) ==
             coordination_before

    assert {:error, audit_error} =
             Repo.query(
               """
               REPLACE INTO audit_events (
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
               )
               SELECT
                 id,
                 actor,
                 'replaced_after_restart',
                 target,
                 task_id,
                 configuration_revision,
                 plan_revision,
                 outcome,
                 correlation_id,
                 dedupe_key,
                 payload,
                 inserted_at
               FROM audit_events
               WHERE id = ?
               """,
               [audit_event.id]
             )

    assert Exception.message(audit_error) =~ "audit events are append-only"
    assert immutable_row_state("audit_events", audit_event.id) == audit_before
  end

  defp delete_projections(task_id) do
    unless Process.whereis(Repo) do
      {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    end

    Sandbox.mode(Repo, :auto)
    Repo.delete_all(from(unit in UnitProjection, where: unit.task_id == ^task_id))
    Repo.delete_all(from(task in TaskProjection, where: task.task_id == ^task_id))
  end

  defp immutable_row_state(table, id) do
    count = Repo.query!("SELECT COUNT(*) FROM #{table}").rows
    row = Repo.query!("SELECT * FROM #{table} WHERE id = ?", [id]).rows
    {count, row}
  end
end
