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

    assert {:error, {:sensitive_data, ["metadata", "outer", "reference"]}} =
             Coordination.start_task(
               Map.put(task_attrs("nested-reference-map"), :metadata, %{
                 "outer" => %{"reference" => reference.id}
               })
             )

    assert {:error, {:sensitive_data, ["metadata", 0, "reference"]}} =
             Coordination.start_task(
               Map.put(task_attrs("nested-reference-list"), :metadata, [
                 %{"reference" => reference.id}
               ])
             )

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

    assert {:error, {:sensitive_data, ["metadata", "outer", "reference"]}} =
             Coordination.append(task.id, 1, [
               %{
                 type: :effect_unknown,
                 data: %{
                   operation_id: "op-nested-reference-map",
                   metadata: %{"outer" => %{"reference" => reference.id}}
                 }
               }
             ])

    assert {:error, {:sensitive_data, ["metadata", 0, "reference"]}} =
             Coordination.append(task.id, 1, [
               %{
                 type: :effect_unknown,
                 data: %{
                   operation_id: "op-nested-reference-list",
                   metadata: [%{"reference" => reference.id}]
                 }
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

  test "unit progress cannot overwrite planned task or unit authority fields" do
    {:ok, task} =
      start_task("unit-progress-authority",
        plan_revision: "plan-1",
        task_type: "restricted-task",
        execution_profile: "restricted-profile",
        model_reference: "restricted-model"
      )

    assert {:ok, 2} =
             Coordination.append(task.id, 1, [
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "backend-1",
                   task_type: "backend",
                   execution_profile: "restricted-profile",
                   dependencies: ["frontend-1"],
                   model_reference_id: "model-restricted"
                 }
               }
             ])

    assert {:ok, 3} =
             Coordination.append(task.id, 2, [
               %{
                 type: :unit_progress,
                 plan_revision: "999",
                 data: %{
                   unit_id: "backend-1",
                   percent: 50,
                   task_type: "admin",
                   execution_profile: "admin-profile",
                   dependencies: [],
                   model_reference_id: "model-admin"
                 }
               }
             ])

    assert {:ok, live_snapshot} = Coordination.snapshot(task.id)
    assert_authority_unchanged(live_snapshot)
    assert get_in(live_snapshot.units, [Access.at(0), :data, "percent"]) == 50
    assert_progress_event_sanitized(task.id)

    assert :ok = Coordination.rebuild_projection(task.id)
    assert {:ok, rebuilt_snapshot} = Coordination.snapshot(task.id)
    assert_authority_unchanged(rebuilt_snapshot)
    assert get_in(rebuilt_snapshot.units, [Access.at(0), :data, "percent"]) == 50
  end

  test "non-planning unit events reject authority fields" do
    {:ok, task} = start_task("unit-event-authority")

    assert {:ok, 2} =
             Coordination.append(task.id, 1, [
               %{
                 type: :unit_planned,
                 data: %{
                   unit_id: "backend-1",
                   task_type: "backend",
                   execution_profile: "restricted-profile",
                   dependencies: []
                 }
               }
             ])

    for event_type <- [:unit_runnable, :unit_failed, :unit_cancelled] do
      assert {:error, {:forbidden_event_fields, ^event_type, ["data", "task_type"]}} =
               Coordination.append(task.id, 2, [
                 %{
                   type: event_type,
                   data: %{unit_id: "backend-1", task_type: "admin"}
                 }
               ])
    end

    assert {:ok, %{version: 2, units: [%{task_type: "backend"}]}} = Coordination.snapshot(task.id)
  end

  defp start_task(suffix, extra \\ %{}) do
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

  defp assert_authority_unchanged(snapshot) do
    assert snapshot.plan_revision == "plan-1"

    assert [
             %{
               task_type: "backend",
               execution_profile: "restricted-profile",
               dependencies: ["frontend-1"],
               data: data
             }
           ] = snapshot.units

    assert data["model_reference_id"] == "model-restricted"
    refute Map.has_key?(data, "task_type")
    refute Map.has_key?(data, "execution_profile")
    refute Map.has_key?(data, "dependencies")
  end

  defp assert_progress_event_sanitized(task_id) do
    assert {:ok, %{rows: [[plan_revision, data]]}} =
             SQL.query(
               Repo,
               "SELECT plan_revision, data FROM coordination_events WHERE task_id = ? AND stream_version = 3",
               [task_id]
             )

    assert plan_revision == "plan-1"
    assert Jason.decode!(data) == %{"percent" => 50, "unit_id" => "backend-1"}
  end
end
