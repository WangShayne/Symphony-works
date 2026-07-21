defmodule SymphonyElixirWeb.TaskLiveTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Configuration, Coordination, Identity, Repo}
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Coordination.{TaskProjection, UnitProjection}
  alias SymphonyElixir.Identity.Principal

  setup %{conn: conn} do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, _active} = Configuration.activate(draft.id, actor: "bootstrap-admin")
    operator = insert_principal!([:operator])
    key = "task-live-#{System.unique_integer([:positive])}"

    created =
      conn
      |> api_conn(operator)
      |> put_req_header("idempotency-key", key)
      |> post("/api/v1/tasks", task_payload())

    task_id = json_response(created, 201)["data"]["id"]
    %{operator: operator, task_id: task_id}
  end

  test "task list and detail render durable task, unit, configuration, and effect state in both locales", %{
    conn: conn,
    operator: operator,
    task_id: task_id
  } do
    assert {:ok, _index, index_html} = live(browser_conn(conn, operator), "/tasks")
    assert index_html =~ "GH-9"
    assert index_html =~ "/tasks/#{task_id}"

    assert {:ok, detail, detail_html} = live(browser_conn(conn, operator), "/tasks/#{task_id}")
    assert detail_html =~ "Task detail"
    assert detail_html =~ "GH-9"
    assert detail_html =~ "Queued"
    assert detail_html =~ "Effect succeeded"
    assert detail_html =~ "unit-live"
    assert detail_html =~ "backend"
    assert detail_html =~ "Profile"
    assert detail_html =~ "Model"
    assert detail_html =~ "backend-default"
    assert detail_html =~ "model-backend-primary"
    assert has_element?(detail, "[data-task-id='#{task_id}']")
    assert has_element?(detail, "[data-effect-status='succeeded']")

    {:ok, snapshot} = Coordination.snapshot(task_id)
    [unit] = snapshot.units

    for {{status, label}, index} <- Enum.with_index(english_task_statuses()) do
      send(
        detail.pid,
        {:coordination_updated, %{snapshot | status: status, version: snapshot.version + index + 1}}
      )

      assert render(detail) =~ label
    end

    english_unit_base = snapshot.version + length(english_task_statuses())

    for {{status, label}, index} <- Enum.with_index(english_unit_statuses()) do
      send(
        detail.pid,
        {:coordination_updated, %{snapshot | version: english_unit_base + index + 1, units: [%{unit | status: status}]}}
      )

      assert render(detail) =~ label
    end

    send(detail.pid, {:coordination_updated, %{snapshot | id: Ecto.UUID.generate()}})
    assert render(detail) =~ "GH-9"

    english_effect_base = english_unit_base + length(english_unit_statuses())

    for {{effect_status, label}, index} <- Enum.with_index(english_effects()) do
      effect =
        if effect_status,
          do: %{operation_id: Ecto.UUID.generate(), status: effect_status},
          else: nil

      send(
        detail.pid,
        {:coordination_updated,
         %{
           snapshot
           | version: english_effect_base + index + 1,
             effect: effect,
             effect_status: effect_status,
             configuration_revision: "short-ref",
             baseline: nil
         }}
      )

      assert render(detail) =~ label
    end

    assert {:ok, zh_detail, zh_html} =
             live(browser_conn(conn, operator), "/zh-CN/tasks/#{task_id}")

    assert zh_html =~ "任务详情"
    assert zh_html =~ "排队中"
    assert zh_html =~ "外部操作已记录"
    assert zh_html =~ "执行单元"
    assert zh_html =~ "执行档案"
    assert zh_html =~ "模型"
    assert zh_html =~ "backend-default"
    assert zh_html =~ "model-backend-primary"

    for {{status, label}, index} <- Enum.with_index(chinese_task_statuses()) do
      send(
        zh_detail.pid,
        {:coordination_updated, %{snapshot | status: status, version: snapshot.version + index + 1}}
      )

      assert render(zh_detail) =~ label
    end

    chinese_unit_base = snapshot.version + length(chinese_task_statuses())

    for {{status, label}, index} <- Enum.with_index(chinese_unit_statuses()) do
      send(
        zh_detail.pid,
        {:coordination_updated, %{snapshot | version: chinese_unit_base + index + 1, units: [%{unit | status: status}]}}
      )

      assert render(zh_detail) =~ label
    end

    chinese_effect_base = chinese_unit_base + length(chinese_unit_statuses())

    for {{effect_status, label}, index} <- Enum.with_index(chinese_effects()) do
      effect =
        if effect_status,
          do: %{operation_id: Ecto.UUID.generate(), status: effect_status},
          else: nil

      send(
        zh_detail.pid,
        {:coordination_updated,
         %{
           snapshot
           | version: chinese_effect_base + index + 1,
             effect: effect,
             effect_status: effect_status
         }}
      )

      assert render(zh_detail) =~ label
    end
  end

  test "task LiveView fails closed and missing task projections return to the task list", %{
    conn: conn,
    operator: operator
  } do
    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, SymphonyElixirWeb.TaskLive, session: %{})

    assert {:error, {:redirect, %{to: "/tasks"}}} =
             live(browser_conn(conn, operator), "/tasks/#{Ecto.UUID.generate()}")
  end

  test "task LiveView ignores stale coordination snapshots", %{
    conn: conn,
    operator: operator,
    task_id: task_id
  } do
    assert {:ok, detail, _html} = live(browser_conn(conn, operator), "/tasks/#{task_id}")
    {:ok, snapshot} = Coordination.snapshot(task_id)
    [unit] = snapshot.units

    newer_version = snapshot.version + 1

    version_three = %{
      snapshot
      | version: newer_version,
        status: :running,
        units: [%{unit | version: newer_version, status: :running}]
    }

    stale_cross_mixed = %{
      snapshot
      | version: snapshot.version,
        status: :planning,
        units: [%{unit | version: newer_version, status: :running}]
    }

    send(detail.pid, {:coordination_updated, version_three})
    assert render(detail) =~ "Running"
    assert render(detail) =~ ~r/<dd class="numeric">\s*#{newer_version}\s*<\/dd>/

    send(detail.pid, {:coordination_updated, stale_cross_mixed})
    html = render(detail)
    assert html =~ "Running"
    assert html =~ ~r/<dd class="numeric">\s*#{newer_version}\s*<\/dd>/
    refute html =~ "Planning"
  end

  test "empty task lists and role labels remain bilingual", %{conn: conn} do
    Repo.delete_all(UnitProjection)
    Repo.delete_all(TaskProjection)

    admin = insert_principal!([:administrator])
    viewer = insert_principal!([:viewer])

    assert {:ok, _admin_view, admin_html} = live(browser_conn(conn, admin), "/tasks")
    assert admin_html =~ "No tasks"
    assert admin_html =~ "Administrator"

    assert {:ok, _viewer_en_view, viewer_en_html} =
             live(browser_conn(conn, viewer), "/tasks")

    assert viewer_en_html =~ "Viewer"
    assert viewer_en_html =~ ~s(aria-label="Primary")
    assert viewer_en_html =~ ~s(aria-label="Session controls")

    assert {:ok, _admin_zh_view, admin_zh_html} =
             live(browser_conn(conn, admin), "/zh-CN/tasks")

    assert admin_zh_html =~ "管理员"
    assert admin_zh_html =~ ~s(aria-label="主导航")
    assert admin_zh_html =~ ~s(aria-label="会话控制")

    assert {:ok, _viewer_view, viewer_html} =
             live(browser_conn(conn, viewer), "/zh-CN/tasks")

    assert viewer_html =~ "暂无任务"
    assert viewer_html =~ "0 个任务"
    assert viewer_html =~ "查看者"
  end

  defp api_conn(conn, %Principal{} = principal) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-symphony-test-principal", principal.id)
  end

  defp browser_conn(conn, %Principal{} = principal) do
    conn
    |> recycle()
    |> init_test_session(%{"principal_id" => principal.id})
  end

  defp insert_principal!(roles) do
    {:ok, principal} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "task-live-#{System.unique_integer([:positive])}",
        roles: roles
      })

    principal
  end

  defp task_payload do
    %{
      "task" => %{
        "external_id" => "GH-9",
        "summary" => "Persist and recover a task",
        "baseline_commit" => String.duplicate("b", 40),
        "plan_revision" => 1,
        "units" => [
          %{
            "id" => "unit-live",
            "task_type" => "backend",
            "execution_profile_id" => "backend-default",
            "model_reference_id" => "model-backend-primary",
            "status" => "pending"
          }
        ]
      }
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

  defp english_task_statuses do
    [
      queued: "Queued",
      planning: "Planning",
      running: "Running",
      awaiting_intervention: "Awaiting intervention",
      integrating: "Integrating",
      validating: "Validating",
      review_ready: "Review ready",
      completed: "Completed",
      failed: "Failed",
      cancelled: "Cancelled"
    ]
  end

  defp english_unit_statuses do
    [
      pending: "Pending",
      runnable: "Runnable",
      running: "Running",
      blocked: "Blocked",
      awaiting_approval: "Awaiting approval",
      accepted: "Accepted",
      failed: "Failed",
      cancelled: "Cancelled"
    ]
  end

  defp chinese_task_statuses do
    [
      queued: "排队中",
      planning: "规划中",
      running: "运行中",
      awaiting_intervention: "等待干预",
      integrating: "集成中",
      validating: "验证中",
      review_ready: "评审就绪",
      completed: "已完成",
      failed: "失败",
      cancelled: "已取消"
    ]
  end

  defp chinese_unit_statuses do
    [
      pending: "待处理",
      runnable: "可执行",
      running: "运行中",
      blocked: "已阻塞",
      awaiting_approval: "等待批准",
      accepted: "已验收",
      failed: "失败",
      cancelled: "已取消"
    ]
  end

  defp english_effects do
    [
      {:succeeded, "Effect succeeded"},
      {:unknown, "Outcome unknown"},
      {:recovery_needed, "Recovery needed"},
      {nil, "Not started"}
    ]
  end

  defp chinese_effects do
    [
      {:succeeded, "外部操作已记录"},
      {:unknown, "结果未知"},
      {:recovery_needed, "需要恢复"},
      {nil, "未开始"}
    ]
  end
end
