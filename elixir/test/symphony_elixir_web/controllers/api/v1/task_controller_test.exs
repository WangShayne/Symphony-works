defmodule SymphonyElixirWeb.Api.V1.TaskControllerTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Audit, Configuration, Coordination, Effects, Identity, Repo}
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Coordination.{TaskProjection, UnitProjection}
  alias SymphonyElixir.Identity.Principal

  @baseline String.duplicate("a", 40)

  defmodule InterruptingAdapter do
    @moduledoc false

    @spec execute(SymphonyElixir.Effects.Record.t()) :: no_return()
    def execute(_record), do: exit(:simulated_process_loss)

    @spec reconcile(SymphonyElixir.Effects.Record.t()) :: {:unknown, :not_observed}
    def reconcile(_record), do: {:unknown, :not_observed}
  end

  defmodule ReconcileAsAppliedAdapter do
    @moduledoc false

    @spec execute(SymphonyElixir.Effects.Record.t()) :: {:ok, map()}
    def execute(_record) do
      send(Application.fetch_env!(:symphony_elixir, :task_effect_test_pid), :unexpected_execute)
      {:ok, %{status: "unexpected"}}
    end

    @spec reconcile(SymphonyElixir.Effects.Record.t()) :: {:ok, :already_applied}
    def reconcile(_record) do
      send(Application.fetch_env!(:symphony_elixir, :task_effect_test_pid), :effect_reconciled)
      {:ok, :already_applied}
    end
  end

  defmodule FailingAdapter do
    @moduledoc false

    @spec execute(SymphonyElixir.Effects.Record.t()) :: {:error, :provider_down}
    def execute(_record), do: {:error, :provider_down}

    @spec reconcile(SymphonyElixir.Effects.Record.t()) :: {:ok, :not_applied}
    def reconcile(_record), do: {:ok, :not_applied}
  end

  setup do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")

    %{
      active: active,
      operator: insert_principal!([:operator]),
      viewer: insert_principal!([:viewer])
    }
  end

  test "authenticated Operator creates one durable task tracer and idempotent replay resumes it", %{
    conn: conn,
    active: active,
    operator: operator
  } do
    secret = "should-never-be-persisted-or-logged"
    prompt = String.duplicate("sensitive task prompt ", 200)
    key = "task-create-#{System.unique_integer([:positive])}"
    payload = task_payload(%{"metadata" => %{"token" => secret, "prompt" => prompt}})

    log =
      capture_log(fn ->
        created = post_task(conn, operator, key, payload)
        assert created.status == 201

        data = json_response(created, 201)["data"]
        task_id = data["id"]
        operation_id = data["effect"]["operation_id"]

        assert data["configuration_revision_id"] == active.id
        assert data["status"] == "queued"
        assert data["effect"]["status"] == "succeeded"
        assert [%{"id" => "unit-api", "status" => "pending"}] = data["units"]

        assert {:ok, snapshot} = Coordination.snapshot(task_id)
        assert snapshot.configuration_revision == active.id
        assert snapshot.effect_status == :succeeded
        assert [%{id: "unit-api", status: :pending}] = snapshot.units
        assert Configuration.pinned_for_task!(task_id).revision_id == active.id

        assert Effects.get!(operation_id).status == :succeeded

        audits = Audit.list(task_id: task_id)
        assert Enum.count(audits, &task_created_audit?/1) == 1

        replayed = post_task(conn, operator, key, payload)
        assert replayed.status == 200
        assert json_response(replayed, 200)["data"]["id"] == task_id
        assert Enum.count(Audit.list(task_id: task_id), &task_created_audit?/1) == 1

        evidence = inspect([data, snapshot, audits, Effects.get!(operation_id)])
        refute evidence =~ secret
        refute evidence =~ prompt
      end)

    refute log =~ secret
    refute log =~ prompt
  end

  test "task creation requires authentication, Operator authority, an idempotency key, and stable intent", %{
    conn: conn,
    operator: operator,
    viewer: viewer
  } do
    payload = task_payload()
    key = "task-create-#{System.unique_integer([:positive])}"

    assert post(conn, "/api/v1/tasks", payload).status == 401
    assert post_task(conn, viewer, key, payload).status == 403

    missing_key =
      conn
      |> api_conn(operator)
      |> post("/api/v1/tasks", payload)

    assert %{"error" => %{"code" => "idempotency_key_required"}} =
             json_response(missing_key, 422)

    created = post_task(conn, operator, key, payload)
    assert created.status == 201

    conflict =
      post_task(
        conn,
        operator,
        key,
        task_payload(%{"external_id" => "GH-DIFFERENT"})
      )

    assert %{"error" => %{"code" => "idempotency_conflict"}} = json_response(conflict, 409)
  end

  test "task creation authorization follows the matched route for canonical and trailing slash paths", %{
    conn: conn,
    operator: operator,
    viewer: viewer
  } do
    for path <- ["/api/v1/tasks", "/api/v1/tasks/"],
        {principal, expected_status} <- [{viewer, 403}, {operator, 201}] do
      key = "route-auth-#{principal.id}-#{System.unique_integer([:positive])}"

      response =
        conn
        |> api_conn(principal)
        |> put_req_header("idempotency-key", key)
        |> post(path, task_payload(%{"external_id" => "GH-ROUTE-#{key}"}))

      assert response.status == expected_status
    end
  end

  test "oversized task creation bodies are rejected before parsing across supported content types", %{
    conn: conn,
    operator: operator,
    viewer: viewer
  } do
    for path <- ["/api/v1/tasks", "/api/v1/tasks/"],
        principal <- [viewer, operator],
        {content_type, body} <- oversized_task_bodies() do
      task_count = Repo.aggregate(TaskProjection, :count, :task_id)
      effect_count = Repo.aggregate(Effects.Record, :count, :operation_id)
      audit_count = length(Audit.list())

      assert_error_sent(:request_entity_too_large, fn ->
        conn
        |> api_conn(principal)
        |> put_req_header("content-type", content_type)
        |> put_req_header("idempotency-key", "oversized-#{System.unique_integer([:positive])}")
        |> post(path, body)
      end)

      assert Repo.aggregate(TaskProjection, :count, :task_id) == task_count
      assert Repo.aggregate(Effects.Record, :count, :operation_id) == effect_count
      assert length(Audit.list()) == audit_count
    end
  end

  test "unauthenticated oversized task JSON is rejected before auth or task creation", %{
    conn: conn
  } do
    body =
      task_payload(%{"summary" => String.duplicate("oversized task body ", 4_000)})
      |> Jason.encode!()

    assert byte_size(body) > 65_536

    task_count = Repo.aggregate(TaskProjection, :count, :task_id)
    effect_count = Repo.aggregate(Effects.Record, :count, :operation_id)
    audit_count = length(Audit.list())

    assert_error_sent(:request_entity_too_large, fn ->
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> Plug.Conn.delete_req_header("content-length")
      |> post("/api/v1/tasks", body)
    end)

    assert Repo.aggregate(TaskProjection, :count, :task_id) == task_count
    assert Repo.aggregate(Effects.Record, :count, :operation_id) == effect_count
    assert length(Audit.list()) == audit_count
  end

  test "idempotent replay reconciles an unknown effect before returning the recovered task", %{
    conn: conn,
    operator: operator
  } do
    previous_adapter = Application.get_env(:symphony_elixir, :task_creation_effect_adapter)
    previous_pid = Application.get_env(:symphony_elixir, :task_effect_test_pid)

    on_exit(fn ->
      restore_env(:task_creation_effect_adapter, previous_adapter)
      restore_env(:task_effect_test_pid, previous_pid)
    end)

    Application.put_env(:symphony_elixir, :task_creation_effect_adapter, InterruptingAdapter)
    Application.put_env(:symphony_elixir, :task_effect_test_pid, self())

    key = "task-reconcile-#{System.unique_integer([:positive])}"
    payload = task_payload(%{"external_id" => "GH-RECOVER"})
    interrupted = post_task(conn, operator, key, payload)

    assert %{"error" => %{"code" => "effect_interrupted"}} =
             json_response(interrupted, 503)

    assert [unknown] = Coordination.list(idempotency_key: key)
    assert unknown.effect_status == :unknown

    Application.put_env(
      :symphony_elixir,
      :task_creation_effect_adapter,
      ReconcileAsAppliedAdapter
    )

    recovered = post_task(conn, operator, key, payload)
    assert recovered.status == 200
    assert json_response(recovered, 200)["data"]["effect"]["status"] == "succeeded"
    assert_receive :effect_reconciled
    refute_receive :unexpected_execute

    assert [task] = Coordination.list(idempotency_key: key)
    assert task.effect_status == :succeeded
    assert Enum.count(Audit.list(task_id: task.id), &task_created_audit?/1) == 1
  end

  test "task query surfaces and validation errors stay structured", %{
    conn: conn,
    active: active,
    operator: operator
  } do
    missing_task =
      conn
      |> api_conn(operator)
      |> put_req_header("idempotency-key", "missing-task-body")
      |> post("/api/v1/tasks", %{})

    assert %{"error" => %{"code" => "invalid_task"}} = json_response(missing_task, 422)

    invalid_key =
      conn
      |> api_conn(operator)
      |> put_req_header("idempotency-key", " ")
      |> post("/api/v1/tasks", task_payload())

    assert %{"error" => %{"code" => "invalid_idempotency_key"}} =
             json_response(invalid_key, 422)

    missing_id = Ecto.UUID.generate()

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> api_conn(operator)
             |> get("/api/v1/tasks/#{missing_id}")
             |> json_response(404)

    {:ok, projection_only} =
      Coordination.start_task(%{
        idempotency_key: "projection-only",
        external_id: "GH-PROJECTION",
        configuration_revision: active.id,
        plan_revision: "1",
        baseline: @baseline,
        correlation_id: "projection-only",
        actor: %{kind: :principal, id: operator.id},
        data: %{"summary" => "Projection without an external effect"}
      })

    shown =
      conn
      |> api_conn(operator)
      |> get("/api/v1/tasks/#{projection_only.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert shown["effect"] == nil

    listed =
      conn
      |> api_conn(operator)
      |> get("/api/v1/tasks")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.any?(listed, &(&1["id"] == projection_only.id))

    Repo.delete_all(SymphonyElixir.Configuration.Revision)

    no_active =
      post_task(
        conn,
        operator,
        "missing-active-configuration",
        task_payload(%{"external_id" => "GH-NO-CONFIG"})
      )

    assert %{"error" => %{"code" => "active_configuration_required"}} =
             json_response(no_active, 409)
  end

  test "task and unit query payloads use bounded cursor pagination", %{
    conn: conn,
    operator: operator
  } do
    Repo.delete_all(UnitProjection)
    Repo.delete_all(TaskProjection)

    created_ids =
      Enum.map(1..3, fn index ->
        payload =
          task_payload(%{
            "external_id" => "GH-PAGE-#{index}",
            "units" => [
              %{
                "id" => "unit-page-#{index}",
                "task_type" => "backend",
                "model_reference_id" => "model-backend-primary"
              }
            ]
          })

        post_task(conn, operator, "task-page-#{index}", payload)
        |> json_response(201)
        |> get_in(["data", "id"])
      end)

    first_page =
      conn
      |> api_conn(operator)
      |> get("/api/v1/tasks?limit=2")
      |> json_response(200)

    assert length(first_page["data"]) == 2
    assert first_page["meta"]["tasks"]["limit"] == 2
    assert is_binary(first_page["meta"]["tasks"]["next_cursor"])
    assert Enum.all?(first_page["data"], &(not Map.has_key?(&1, "units")))
    assert Enum.all?(first_page["data"], &(&1["unit_count"] == 1))

    second_page =
      conn
      |> api_conn(operator)
      |> get("/api/v1/tasks?limit=2&cursor=#{first_page["meta"]["tasks"]["next_cursor"]}")
      |> json_response(200)

    assert length(second_page["data"]) == 1
    assert second_page["meta"]["tasks"]["next_cursor"] == nil

    listed_ids = Enum.map(first_page["data"] ++ second_page["data"], & &1["id"])
    assert Enum.sort(listed_ids) == Enum.sort(created_ids)
    assert length(Enum.uniq(listed_ids)) == 3

    units =
      Enum.map(1..3, fn index ->
        %{
          "id" => "unit-detail-#{index}",
          "task_type" => "backend",
          "model_reference_id" => "model-backend-primary"
        }
      end)

    task_id =
      conn
      |> post_task(
        operator,
        "unit-page-task",
        task_payload(%{"external_id" => "GH-UNIT-PAGE", "units" => units})
      )
      |> json_response(201)
      |> get_in(["data", "id"])

    first_units =
      conn
      |> api_conn(operator)
      |> get("/api/v1/tasks/#{task_id}?unit_limit=2")
      |> json_response(200)

    assert length(first_units["data"]["units"]) == 2
    assert first_units["meta"]["units"]["limit"] == 2
    assert is_binary(first_units["meta"]["units"]["next_cursor"])

    second_units =
      conn
      |> api_conn(operator)
      |> get("/api/v1/tasks/#{task_id}?unit_limit=2&unit_cursor=#{first_units["meta"]["units"]["next_cursor"]}")
      |> json_response(200)

    assert length(second_units["data"]["units"]) == 1
    assert second_units["meta"]["units"]["next_cursor"] == nil

    create_with_cursor_payload =
      task_payload(%{
        "external_id" => "GH-CREATE-UNIT-CURSOR",
        "units" => [
          %{
            "id" => "unit-create-cursor-1",
            "task_type" => "backend",
            "model_reference_id" => "model-backend-primary"
          },
          %{
            "id" => "unit-create-cursor-2",
            "task_type" => "backend",
            "model_reference_id" => "model-backend-primary"
          }
        ]
      })
      |> Map.merge(%{"unit_limit" => 1, "unit_cursor" => "unit-create-cursor-1"})

    create_with_cursor =
      conn
      |> post_task(operator, "unit-page-create-cursor", create_with_cursor_payload)
      |> json_response(201)

    assert [%{"id" => "unit-create-cursor-2"}] = create_with_cursor["data"]["units"]
    assert create_with_cursor["meta"]["units"]["next_cursor"] == nil

    invalid_json_limit =
      task_payload(%{"external_id" => "GH-BAD-UNIT-LIMIT"})
      |> Map.put("unit_limit", [])

    response =
      conn
      |> post_task(operator, "invalid-json-unit-limit", invalid_json_limit)

    assert %{"error" => %{"code" => "invalid_pagination"}} =
             json_response(response, 422)

    for query <- ["limit=0", "limit=101", "limit=invalid", "cursor=plaintext-secret", "cursor[]=nested"] do
      response =
        conn
        |> api_conn(operator)
        |> get("/api/v1/tasks?#{query}")

      assert %{"error" => %{"code" => "invalid_pagination"}} =
               json_response(response, 422)
    end

    for query <- [
          "unit_limit=0",
          "unit_limit=101",
          "unit_limit=invalid",
          "unit_cursor[]=nested",
          "unit_cursor=missing-unit"
        ] do
      response =
        conn
        |> api_conn(operator)
        |> get("/api/v1/tasks/#{task_id}?#{query}")

      assert %{"error" => %{"code" => "invalid_pagination"}} =
               json_response(response, 422)
    end
  end

  test "oversized task JSON fails without reflecting submitted content", %{
    conn: conn,
    operator: operator
  } do
    marker = String.duplicate("oversized-private-value", 3_200)

    request_body =
      task_payload(%{"metadata" => %{"blob" => marker}})
      |> Jason.encode!()

    assert byte_size(request_body) > 65_536

    {_status, _headers, body} =
      assert_error_sent(:request_entity_too_large, fn ->
        conn
        |> api_conn(operator)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("idempotency-key", "oversized-task-controller")
        |> post("/api/v1/tasks", request_body)
      end)

    refute body =~ marker
  end

  test "adapter failure is durable and returned without leaking internals", %{
    conn: conn,
    operator: operator
  } do
    previous_adapter = Application.get_env(:symphony_elixir, :task_creation_effect_adapter)

    on_exit(fn -> restore_env(:task_creation_effect_adapter, previous_adapter) end)
    Application.put_env(:symphony_elixir, :task_creation_effect_adapter, FailingAdapter)

    response =
      post_task(
        conn,
        operator,
        "failed-effect-controller",
        task_payload(%{"external_id" => "GH-EFFECT-FAILED"})
      )

    assert %{
             "error" => %{
               "code" => "effect_failed",
               "details" => %{"reason" => "provider_down"}
             }
           } = json_response(response, 502)

    assert [task] = Coordination.list(idempotency_key: "failed-effect-controller")
    assert task.status == :awaiting_intervention
  end

  test "audit persistence conflict returns a durable unavailable response", %{
    conn: conn,
    active: active,
    operator: operator
  } do
    key = "audit-unavailable-controller"
    payload = task_payload(%{"external_id" => "GH-AUDIT-UNAVAILABLE"})
    task_params = Map.fetch!(payload, "task")

    assert {:ok, task} =
             Coordination.start_task(coordination_attrs(task_params, operator, key, active.id))

    assert {:ok, conflicting_audit} =
             Audit.record(
               :task_reserved,
               %{
                 dedupe_key: "task_created:#{task.id}",
                 task_id: task.id,
                 target: %{type: "task", id: task.id},
                 configuration_revision: active.id,
                 plan_revision: task.plan_revision,
                 correlation_id: task.correlation_id,
                 outcome: :succeeded,
                 summary: %{event: "task_reserved"}
               },
               operator
             )

    response = post_task(conn, operator, key, payload)

    assert %{
             "error" => %{
               "code" => "audit_unavailable",
               "message" => "Task audit could not be durably recorded"
             }
           } = json_response(response, 503)

    assert [audit] = Audit.list(task_id: task.id)
    assert audit.id == conflicting_audit.id
    refute task_created_audit?(audit)

    assert {:ok, recovered} = Coordination.snapshot(task.id)
    assert recovered.status == :awaiting_intervention
    assert recovered.effect_status == :recovery_needed
  end

  test "unexpected task creation errors return an opaque recovery response", %{
    conn: conn,
    operator: operator
  } do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: operator.id)
    key = "unexpected-task-creation-error"
    payload = task_payload(%{"external_id" => "GH-UNEXPECTED-CREATION"})
    task_params = Map.fetch!(payload, "task")

    assert {:ok, task} =
             Coordination.start_task(coordination_attrs(task_params, operator, key, draft.id))

    response = post_task(conn, operator, key, payload)

    assert %{
             "error" => %{
               "code" => "task_creation_failed",
               "message" => "Task creation requires recovery"
             }
           } = json_response(response, 503)

    refute response.resp_body =~ "invalid_pin_revision_status"
    assert {:ok, unchanged} = Coordination.snapshot(task.id)
    assert unchanged.status == :queued
    assert unchanged.effect == nil
    assert Audit.list(task_id: task.id) == []
  end

  test "an existing task never rewrites a conflicting configuration pin", %{
    conn: conn,
    active: active,
    operator: operator
  } do
    key = "configuration-pin-conflict"
    payload = task_payload(%{"external_id" => "GH-PIN-CONFLICT"})
    task_params = Map.fetch!(payload, "task")

    assert {:ok, task} =
             Coordination.start_task(coordination_attrs(task_params, operator, key, active.id))

    replacement_document =
      valid_document()
      |> put_in(["automation_projects", Access.at(0), "name"], "Replacement")

    {:ok, replacement_draft} =
      Configuration.create_draft(replacement_document, actor: operator.id)

    {:ok, replacement} = Configuration.activate(replacement_draft.id, actor: operator.id)

    assert {:ok, pin} =
             Configuration.pin_for_task(task.id,
               actor: operator.id,
               revision_id: replacement.id
             )

    assert pin.revision_id == replacement.id

    response = post_task(conn, operator, key, payload)

    assert %{"error" => %{"code" => "configuration_pin_conflict"}} =
             json_response(response, 409)

    assert Configuration.pinned_for_task!(task.id).revision_id == replacement.id
  end

  defp post_task(conn, principal, key, payload) do
    conn
    |> api_conn(principal)
    |> put_req_header("idempotency-key", key)
    |> post("/api/v1/tasks", payload)
  end

  defp api_conn(conn, %Principal{} = principal) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-symphony-test-principal", principal.id)
  end

  defp insert_principal!(roles) do
    {:ok, principal} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "task-api-#{System.unique_integer([:positive])}",
        roles: roles
      })

    principal
  end

  defp task_payload(overrides \\ %{}) do
    task =
      Map.merge(
        %{
          "external_id" => "GH-9",
          "summary" => "Persist and recover a task",
          "baseline_commit" => @baseline,
          "plan_revision" => 1,
          "units" => [
            %{
              "id" => "unit-api",
              "task_type" => "backend",
              "model_reference_id" => "model-backend-primary",
              "status" => "pending"
            }
          ]
        },
        overrides
      )

    %{"task" => task}
  end

  defp oversized_task_bodies do
    json =
      task_payload(%{"summary" => String.duplicate("oversized task body ", 4_000)})
      |> Jason.encode!()

    form =
      "task[external_id]=GH-OVERSIZED&task[summary]=" <>
        URI.encode_www_form(String.duplicate("oversized task body ", 4_000))

    boundary = "symphony-boundary"

    multipart =
      [
        "--#{boundary}",
        ~s(content-disposition: form-data; name="task[external_id]"),
        "",
        "GH-OVERSIZED",
        "--#{boundary}",
        ~s(content-disposition: form-data; name="task[summary]"),
        "",
        String.duplicate("oversized task body ", 4_000),
        "--#{boundary}--",
        ""
      ]
      |> Enum.join("\r\n")

    assert byte_size(json) > 65_536
    assert byte_size(form) > 65_536
    assert byte_size(multipart) > 65_536

    [
      {"application/json", json},
      {"application/x-www-form-urlencoded", form},
      {"multipart/form-data; boundary=#{boundary}", multipart}
    ]
  end

  defp coordination_attrs(task, principal, key, configuration_revision) do
    units =
      Enum.map(task["units"], fn unit ->
        %{
          "id" => unit["id"],
          "task_type" => unit["task_type"],
          "execution_profile" => unit["execution_profile_id"] || "profile-#{unit["task_type"]}",
          "model_reference_id" => unit["model_reference_id"],
          "dependencies" => unit["dependencies"] || []
        }
      end)

    %{
      idempotency_key: key,
      external_id: task["external_id"],
      configuration_revision: configuration_revision,
      plan_revision: Integer.to_string(task["plan_revision"]),
      baseline: task["baseline_commit"],
      correlation_id: key,
      actor: %{kind: :principal, id: principal.id},
      data: %{"summary" => task["summary"], "units" => units}
    }
  end

  defp valid_document do
    Document.for_project(%{
      "id" => "symphony",
      "name" => "Symphony",
      "tracker" => %{"kind" => "github", "scope" => "WangShayne/Symphony-works"},
      "repository" => %{
        "url" => "git@github.com:WangShayne/Symphony-works.git",
        "target_branch" => "main"
      }
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp task_created_audit?(event), do: event.action in [:task_created, "task_created"]
end
