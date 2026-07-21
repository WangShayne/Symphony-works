defmodule SymphonyElixirWeb.TaskRecoveryTest do
  use ExUnit.Case, async: false
  use SymphonyElixir.RuntimeTestHarness, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias SymphonyElixir.{Configuration, Coordination, Identity, Repo, RuntimeTestHarness}
  alias SymphonyElixir.Configuration.{Document, Revision, TaskPin}
  alias SymphonyElixir.Coordination.{Lease, TaskProjection, UnitProjection}
  alias SymphonyElixir.Effects.Record, as: EffectRecord
  alias SymphonyElixir.Identity.{BootstrapState, Principal, PrincipalRecord, ServiceCredential}

  @endpoint SymphonyElixirWeb.Endpoint

  setup %{runtime_harness: runtime_harness} do
    unless Process.whereis(SymphonyElixirWeb.Endpoint) do
      start_supervised!(SymphonyElixirWeb.Endpoint)
    end

    Sandbox.mode(Repo, :auto)
    RuntimeTestHarness.stop_default_runtime!(runtime_harness)
    assert_runtime_lease_released!()
    clean_persistence!()
    RuntimeTestHarness.restart_default_runtime!(runtime_harness)

    on_exit(fn ->
      unless Process.whereis(Repo) do
        {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
      end

      if Process.whereis(Repo) do
        Sandbox.mode(Repo, :auto)
        RuntimeTestHarness.stop_default_runtime!(runtime_harness)
        assert_runtime_lease_released!()
        clean_persistence!()
        RuntimeTestHarness.restart_default_runtime!(runtime_harness)
        Sandbox.mode(Repo, :manual)
      end
    end)

    :ok
  end

  test "authenticated task creation renders the same durable projection after Repo restart" do
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    {:ok, active} = Configuration.activate(draft.id, actor: "bootstrap-admin")
    operator = insert_principal!([:operator])
    key = "task-restart-#{System.unique_integer([:positive])}"

    created =
      build_conn()
      |> api_conn(operator)
      |> put_req_header("idempotency-key", key)
      |> post("/api/v1/tasks", task_payload())

    data = json_response(created, 201)["data"]
    task_id = data["id"]
    assert data["configuration_revision_id"] == active.id

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(SymphonyElixir.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    restored =
      build_conn()
      |> api_conn(operator)
      |> get("/api/v1/tasks/#{task_id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert restored["id"] == task_id
    assert restored["configuration_revision_id"] == active.id
    assert restored["effect"]["status"] == "succeeded"
    assert [%{"id" => "unit-restart", "status" => "pending"}] = restored["units"]

    assert {:ok, snapshot} = Coordination.snapshot(task_id)
    assert snapshot.version == restored["version"]

    assert {:ok, _view, html} =
             live(browser_conn(operator), "/tasks/#{task_id}")

    assert html =~ "Task detail"
    assert html =~ "GH-RESTART"
    assert html =~ "Effect succeeded"
    assert html =~ "unit-restart"
  end

  defp api_conn(conn, %Principal{} = principal) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-symphony-test-principal", principal.id)
  end

  defp browser_conn(%Principal{} = principal) do
    build_conn()
    |> init_test_session(%{"principal_id" => principal.id})
  end

  defp insert_principal!(roles) do
    {:ok, principal} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "task-restart-#{System.unique_integer([:positive])}",
        roles: roles
      })

    principal
  end

  defp clean_persistence! do
    Repo.delete_all(EffectRecord)
    Repo.delete_all(UnitProjection)
    Repo.delete_all(TaskProjection)
    Repo.delete_all(Lease)
    Repo.delete_all(TaskPin)
    Repo.delete_all(Revision)
    Repo.delete_all(BootstrapState)
    Repo.delete_all(ServiceCredential)
    Repo.delete_all(PrincipalRecord)
  end

  defp assert_runtime_lease_released! do
    owner_id = "task-recovery-cleanup-#{System.unique_integer([:positive])}"
    assert {:ok, lease} = Coordination.acquire_lease(owner_id, ttl_ms: 30_000)
    assert :ok = Coordination.release_lease(lease)
  end

  defp task_payload do
    %{
      "task" => %{
        "external_id" => "GH-RESTART",
        "summary" => "Recover the persisted task",
        "baseline_commit" => String.duplicate("c", 40),
        "plan_revision" => 1,
        "units" => [
          %{
            "id" => "unit-restart",
            "task_type" => "backend",
            "execution_profile_id" => "backend-default",
            "model_reference_id" => "model-backend-primary"
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
end
