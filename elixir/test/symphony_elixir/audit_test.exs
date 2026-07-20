defmodule SymphonyElixir.AuditTest do
  use SymphonyElixir.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Audit
  alias SymphonyElixir.Audit.Redactor
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore

  defmodule RedactorFixture do
    @moduledoc false
    defstruct [:value]
  end

  test "audit events identify control context without registered secrets or complete prompts" do
    plaintext = "audit-secret-#{System.unique_integer([:positive])}"
    prompt = String.duplicate("confidential routing prompt ", 1_000)
    system_prompt = "system prompt must not persist"
    developer_instructions = "developer instructions must not persist"
    chat_messages = "chat messages must not persist"
    {:ok, reference} = SecretStore.put("audit-test-token", plaintext, actor: "admin-1")
    test_pid = self()

    assert Redactor.contains_registered_secret?(%{"nested" => ["Bearer #{plaintext}"]})
    assert Redactor.contains_registered_secret?({:reference, reference.id})
    refute Redactor.contains_registered_secret?(%RedactorFixture{value: 123})
    refute Redactor.contains_registered_secret?(123)

    log =
      capture_log(fn ->
        result =
          Audit.record(
            :configuration_activated,
            %{
              task_id: "task-1",
              target: %{type: "configuration_revision", id: "revision-2"},
              configuration_revision: "revision-2",
              plan_revision: 3,
              outcome: :succeeded,
              correlation_id: "correlation-1",
              token: plaintext,
              prompt: prompt,
              systemPrompt: system_prompt,
              developerInstructions: developer_instructions,
              chatMessages: chat_messages,
              summary: %{changed: ["models"], note: "Bearer #{plaintext}"}
            },
            %{type: "administrator", id: "admin-1"}
          )

        send(test_pid, {:audit_result, result})
      end)

    assert_receive {:audit_result, {:ok, event}}
    assert event.action == "configuration_activated"
    assert event.actor == %{"id" => "admin-1", "type" => "administrator"}
    assert event.target == %{"id" => "revision-2", "type" => "configuration_revision"}
    assert event.task_id == "task-1"
    assert event.configuration_revision == "revision-2"
    assert event.plan_revision == 3
    assert event.outcome == "succeeded"
    assert event.correlation_id == "correlation-1"
    assert event.payload["token"] == "[REDACTED]"
    assert event.payload["prompt"] == "[PROMPT REDACTED]"
    assert event.payload["prompt_truncated"] == true
    assert event.payload["systemPrompt"] == "[PROMPT REDACTED]"
    assert event.payload["developerInstructions"] == "[PROMPT REDACTED]"
    assert event.payload["chatMessages"] == "[PROMPT REDACTED]"
    assert event.payload["summary"]["note"] == "Bearer [REDACTED]"
    refute inspect(event) =~ plaintext
    refute inspect(event) =~ prompt
    refute inspect(event) =~ system_prompt
    refute inspect(event) =~ developer_instructions
    refute inspect(event) =~ chat_messages
    refute log =~ plaintext
    refute log =~ prompt

    assert [listed] = Audit.list(task_id: "task-1")
    assert listed.id == event.id
    assert Audit.get!(event.id).id == event.id

    assert {:ok, %{rows: rows}} =
             SQL.query(
               Repo,
               "select actor, target, payload from audit_events where id = ?",
               [event.id]
             )

    refute inspect(rows) =~ plaintext
    refute inspect(rows) =~ prompt
    refute inspect(rows) =~ system_prompt
    refute inspect(rows) =~ developer_instructions
    refute inspect(rows) =~ chat_messages
  end

  test "database triggers reject updates and deletes of audit events" do
    {:ok, event} =
      Audit.record(
        :task_created,
        %{
          task_id: "task-immutable",
          target: %{type: "task", id: "task-immutable"},
          outcome: :succeeded,
          correlation_id: "correlation-immutable",
          summary: %{event: "task_created"}
        },
        %{type: "service", id: "orchestrator"}
      )

    assert {:error, update_error} =
             SQL.query(Repo, "update audit_events set outcome = ? where id = ?", ["failed", event.id])

    assert Exception.message(update_error) =~ "audit events are append-only"

    assert {:error, delete_error} =
             SQL.query(Repo, "delete from audit_events where id = ?", [event.id])

    assert Exception.message(delete_error) =~ "audit events are append-only"
    assert Audit.get!(event.id).outcome == "succeeded"
  end

  test "concurrent records with one dedupe key append one semantic audit event" do
    attrs = %{
      dedupe_key: "task_created:task-concurrent-audit",
      task_id: "task-concurrent-audit",
      target: %{type: "task", id: "task-concurrent-audit"},
      plan_revision: "1",
      outcome: :succeeded,
      correlation_id: "correlation-concurrent-audit",
      summary: %{event: "task_created"}
    }

    events =
      1..8
      |> Task.async_stream(
        fn _index ->
          Audit.record(:task_created, attrs, %{type: "service", id: "orchestrator"})
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, event}} -> event end)

    assert events |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
    assert Enum.all?(events, &(&1.plan_revision == 1))
    assert length(Audit.list(dedupe_key: attrs.dedupe_key)) == 1
  end

  test "reusing an audit dedupe key for different semantics fails closed" do
    attrs = %{
      dedupe_key: "task_created:task-audit-conflict",
      task_id: "task-audit-conflict",
      target: %{type: "task", id: "task-audit-conflict"},
      outcome: :succeeded,
      correlation_id: "correlation-audit-conflict",
      summary: %{event: "task_created", version: 1}
    }

    assert {:ok, original} =
             Audit.record(:task_created, attrs, %{type: "service", id: "orchestrator"})

    assert {:error, :dedupe_conflict} =
             Audit.record(
               :task_created,
               put_in(attrs, [:summary, :version], 2),
               %{type: "service", id: "orchestrator"}
             )

    assert Audit.get!(original.id).payload["summary"]["version"] == 1
  end

  test "invalid audit semantics return changesets with and without dedupe identity" do
    base = %{
      target: %{type: "task", id: "task-invalid-audit"},
      plan_revision: -1,
      correlation_id: "correlation-invalid-audit"
    }

    assert {:error, %Ecto.Changeset{} = without_dedupe} =
             Audit.record(:task_created, base, %{type: "service", id: "orchestrator"})

    refute without_dedupe.valid?

    assert {:error, %Ecto.Changeset{} = with_dedupe} =
             Audit.record(
               :task_created,
               base
               |> Map.put(:dedupe_key, "task_created:task-invalid-audit")
               |> Map.put(:plan_revision, "invalid"),
               %{type: "service", id: "orchestrator"}
             )

    refute with_dedupe.valid?
  end

  test "redaction remains closed when a secret overlaps the redaction marker" do
    {:ok, _reference} = SecretStore.put("short-audit-token", "R", actor: "admin-1")

    assert {:ok, event} =
             Audit.record(
               :task_created,
               %{
                 target: %{type: "task", id: "task-short-secret"},
                 outcome: :succeeded,
                 correlation_id: "correlation-short-secret",
                 summary: %{note: "before-R-after"}
               },
               %{type: "service", id: "orchestrator"}
             )

    refute event.payload["summary"]["note"] =~ "R"
  end

  test "record and query normalize supported public input shapes" do
    assert {:ok, fallback} = Audit.record(:fallback_action, :not_a_map, :system)
    assert fallback.actor == %{"id" => "system", "type" => "actor"}
    assert fallback.target == %{"id" => "system", "type" => "system"}

    assert {:ok, normalized} =
             Audit.record(
               123,
               %{
                 "target" => "target-1",
                 "outcome" => 456,
                 "correlation_id" => "correlation-normalized",
                 "payload" => "summary"
               },
               "actor-1"
             )

    assert normalized.action == "invalid"
    assert normalized.outcome == "invalid"
    assert normalized.actor == %{"id" => "actor-1", "type" => "actor"}
    assert normalized.target == %{"id" => "target-1", "type" => "target"}
    assert normalized.payload == %{"summary" => "summary"}

    assert {:ok, unknown_identity} =
             Audit.record(
               :unknown_identity,
               %{
                 target: self(),
                 outcome: :failed,
                 correlation_id: "correlation-unknown"
               },
               self()
             )

    assert unknown_identity.actor == %{"id" => "unknown", "type" => "actor"}
    assert unknown_identity.target == %{"id" => "unknown", "type" => "target"}

    assert {:ok, struct_actor} =
             Audit.record(
               :struct_actor,
               %{
                 target: %{type: "task", id: "task-struct-actor"},
                 correlation_id: "correlation-struct-actor"
               },
               %RedactorFixture{value: :actor}
             )

    assert struct_actor.actor == %{"value" => "actor"}

    recorded_ids = MapSet.new([fallback.id, normalized.id, unknown_identity.id, struct_actor.id])

    assert recorded_ids
           |> MapSet.subset?(Audit.list() |> Enum.map(& &1.id) |> MapSet.new())

    assert Enum.map(Audit.list(%{action: "invalid"}), & &1.id) == [normalized.id]

    assert Enum.map(Audit.list(correlation_id: "correlation-normalized"), & &1.id) ==
             [normalized.id]

    assert Enum.map(Audit.list(outcome: :failed), & &1.id) == [unknown_identity.id]

    assert recorded_ids
           |> MapSet.subset?(Audit.list(unsupported: true) |> Enum.map(& &1.id) |> MapSet.new())

    assert recorded_ids
           |> MapSet.subset?(Audit.list(:invalid_filters) |> Enum.map(& &1.id) |> MapSet.new())
  end

  test "redactor produces bounded JSON-safe summaries for supported runtime shapes" do
    datetime = DateTime.utc_now()
    naive_datetime = DateTime.to_naive(datetime)
    large = String.duplicate("large-value", 400)

    redacted =
      Redactor.redact(%{
        "datetime" => datetime,
        "naive_datetime" => naive_datetime,
        "struct" => %RedactorFixture{value: :ok},
        "tuple" => {:ok, "value"},
        "large" => large,
        "unsupported" => fn -> :ok end,
        123 => "unsupported key",
        "prompt" => %{nested: true}
      })

    assert redacted["datetime"] == DateTime.to_iso8601(datetime)
    assert redacted["naive_datetime"] == NaiveDateTime.to_iso8601(naive_datetime)
    assert redacted["struct"] == %{"value" => "ok"}
    assert redacted["tuple"] == ["ok", "value"]
    assert redacted["large"] == "[TRUNCATED #{byte_size(large)} BYTES]"
    assert redacted["unsupported"] == "[UNSUPPORTED VALUE]"
    assert redacted["unsupported_key"] == "unsupported key"
    assert redacted["prompt"] == "[PROMPT REDACTED]"
    assert redacted["prompt_truncated"] == true
    assert is_integer(redacted["prompt_bytes"])
  end

  test "an unreadable secret reference fails closed without breaking audit recording" do
    {:ok, _reference} =
      SecretStore.put(
        "alternate-key-secret",
        "not-present-in-audit-input",
        actor: "admin-1",
        key: :crypto.strong_rand_bytes(32)
      )

    assert {:ok, event} =
             Audit.record(
               :secret_fetch_failed,
               %{
                 target: %{type: "task", id: "task-secret-fetch"},
                 correlation_id: "correlation-secret-fetch",
                 summary: %{status: :safe}
               },
               %{type: "service", id: "orchestrator"}
             )

    assert event.actor == %{"redaction_error" => "[REDACTION UNAVAILABLE]"}
    assert event.target == %{"redaction_error" => "[REDACTION UNAVAILABLE]"}
    assert event.payload == %{"redaction_error" => "[REDACTION UNAVAILABLE]"}

    assert {:ok, %{rows: rows}} =
             SQL.query(
               Repo,
               "select actor, target, payload from audit_events where id = ?",
               [event.id]
             )

    refute inspect(rows) =~ "not-present-in-audit-input"
    assert inspect(rows) =~ "REDACTION UNAVAILABLE"
  end

  test "audit persistence redacts whole values when the secret registry is unavailable" do
    sensitive = "registry-unavailable-sensitive-value"
    assert {:ok, _result} = SQL.query(Repo, "alter table secrets rename to unavailable_secrets", [])

    assert {:ok, event} =
             Audit.record(
               :secret_registry_failed,
               %{
                 target: %{type: "task", id: sensitive},
                 correlation_id: "correlation-registry-failure",
                 summary: sensitive
               },
               %{type: "service", id: sensitive}
             )

    marker = %{"redaction_error" => "[REDACTION UNAVAILABLE]"}
    assert event.actor == marker
    assert event.target == marker
    assert event.payload == marker

    assert {:ok, %{rows: rows}} =
             SQL.query(
               Repo,
               "select actor, target, payload from audit_events where id = ?",
               [event.id]
             )

    refute inspect(rows) =~ sensitive
    assert inspect(rows) =~ "REDACTION UNAVAILABLE"
  end
end

defmodule SymphonyElixir.AuditRedactorOwnershipTest do
  use SymphonyElixir.DataCase, async: true

  alias SymphonyElixir.Audit.Redactor

  test "redaction remains available when the secret registry cannot be queried" do
    parent = self()
    spawn(fn -> send(parent, {:redacted, Redactor.redact(%{"safe" => "value"})}) end)
    assert_receive {:redacted, %{"redaction_error" => "[REDACTION UNAVAILABLE]"}}

    spawn(fn -> send(parent, {:redacted_scalar, Redactor.redact("value")}) end)
    assert_receive {:redacted_scalar, "[REDACTION UNAVAILABLE]"}
  end
end
