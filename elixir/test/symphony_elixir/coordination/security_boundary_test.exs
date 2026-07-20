defmodule SymphonyElixir.Coordination.SecurityBoundaryTest do
  use SymphonyElixir.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.{Coordination, Repo}
  alias SymphonyElixir.Security.SecretStore

  @raw_uuid "plaintext-secret"

  test "requires canonical textual task UUIDs at every public boundary" do
    canonical = Ecto.UUID.generate()
    uppercase = String.upcase(canonical)

    assert {:error, :invalid_task_id} = start_task("raw-id", id: @raw_uuid)
    assert {:error, :invalid_task_id} = start_task("uppercase-id", id: uppercase)
    assert {:error, :not_found} = Coordination.snapshot(@raw_uuid)

    assert {:error, :not_found} =
             Coordination.append(@raw_uuid, 0, [%{type: :planning_started, data: %{}}])

    assert {:error, :invalid_task_id} = Coordination.subscribe(@raw_uuid)
    assert {:error, :not_found} = Coordination.rebuild_projection(@raw_uuid)
    assert [] = Coordination.list(after: @raw_uuid)

    assert {:ok, %{id: ^canonical}} = start_task("canonical-id", id: canonical)
  end

  test "fails closed for sensitive key variants across the persisted event envelope" do
    plaintext = "coordination-plaintext-#{Ecto.UUID.generate()}"

    {:ok, reference} =
      SecretStore.put("coordination-redaction-#{Ecto.UUID.generate()}", plaintext, actor: "admin")

    for {key, suffix} <- [
          {"credential", "credential"},
          {"api-key", "api-key"},
          {"accessToken", "access-token"},
          {"refreshToken", "refresh-token"}
        ] do
      attrs = Map.put(task_attrs("start-#{suffix}"), key, plaintext)
      assert {:error, {:sensitive_data, _path}} = Coordination.start_task(attrs)
    end

    assert {:error, {:sensitive_data, _path}} =
             Coordination.start_task(Map.put(task_attrs("registered-plaintext"), :actor, %{kind: :service, id: plaintext}))

    assert {:error, {:sensitive_data, _path}} =
             Coordination.start_task(Map.put(task_attrs("registered-key"), plaintext, "must-not-persist"))

    for {value, suffix} <- [
          {%{"reference" => reference.id}, "reference-map"},
          {[reference.id], "reference-list"}
        ] do
      assert {:error, {:sensitive_data, _path}} =
               Coordination.start_task(Map.put(task_attrs(suffix), :metadata, value))
    end

    {:ok, task} = Coordination.start_task(task_attrs("safe-task"))

    for {key, suffix} <- [
          {"credential", "credential"},
          {"api-key", "api-key"},
          {"accessToken", "access-token"},
          {"refreshToken", "refresh-token"}
        ] do
      event = %{
        type: :effect_unknown,
        data: %{"operation_id" => "op-#{suffix}", key => plaintext}
      }

      assert {:error, {:sensitive_data, _path}} = Coordination.append(task.id, 1, [event])
    end

    assert {:error, {:sensitive_data, _path}} =
             Coordination.append(task.id, 1, [
               %{
                 type: :effect_unknown,
                 actor: %{kind: :service, id: plaintext},
                 data: %{operation_id: "op-registered"}
               }
             ])

    assert {:ok, %{version: 1}} = Coordination.snapshot(task.id)

    assert {:ok, %{rows: rows}} =
             SQL.query(
               Repo,
               "SELECT task_id, actor_kind, actor_id, correlation_id, data FROM coordination_events",
               []
             )

    refute inspect(rows) =~ plaintext
  end

  defp start_task(suffix, extra) do
    suffix
    |> task_attrs()
    |> Map.merge(Map.new(extra))
    |> Coordination.start_task()
  end

  defp task_attrs(suffix) do
    %{
      idempotency_key: "security-boundary:#{suffix}",
      external_id: "TASK-#{suffix}",
      config_revision_id: Ecto.UUID.generate(),
      baseline: "0123456789abcdef"
    }
  end
end
