defmodule SymphonyElixirWeb.ConfigurationLiveTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.{Document, Revision}
  alias SymphonyElixir.Identity
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore

  @bootstrap_token "test-bootstrap-token-with-32-bytes"

  defmodule FailingProbe do
    @behaviour SymphonyElixir.Configuration.Probe

    @impl true
    def validate(_document), do: {:error, {:model, %{"message" => "offline", "api_key" => "secret"}}}
  end

  defmodule FakeHealthAppServer do
    def start_session(_workspace, opts) do
      true = Keyword.fetch!(opts, :health_probe)

      {:ok, %{thread_id: "probe-thread"}}
    end

    def run_turn(%{thread_id: "probe-thread"}, _prompt, %{identifier: "runtime-capability-probe"}, opts) do
      true = Keyword.fetch!(opts, :health_probe)

      {:ok, %{result: %{"task_type" => "general"}}}
    end

    def stop_session(%{thread_id: "probe-thread"}), do: :ok
  end

  defmodule LeakyIntegrationHealth do
    def health_check(%{"credential" => credential}) do
      {:error, %{"code" => "denied", "message" => credential}}
    end
  end

  defmodule SourceControlEndpointHealth do
    def health_check(%{
          "kind" => "source_control",
          "provider" => "github",
          "credential" => "source-control-live-secret",
          "settings" => %{"api_base_url" => "https://source-control.example.test/api/v4"}
        }) do
      {:ok, %{status: :healthy, evidence: %{"endpoint" => "custom"}}}
    end

    def health_check(_integration), do: {:error, %{"code" => "missing_api_base_url"}}
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :runtime_health_app_server)
    Application.put_env(:symphony_elixir, :runtime_health_app_server, FakeHealthAppServer)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :runtime_health_app_server, previous)
    end)
  end

  test "bootstrap Administrator creates, validates, and activates an Automation Project", %{
    conn: conn
  } do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")

    assert {:ok, view, html} = live(conn, "/configuration")
    assert html =~ "Automation Project"

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    assert render(view) =~ "Draft revision"

    view
    |> form("#draft-update-form", project: put_in(valid_project(), ["name"], "Edited Symphony"))
    |> render_submit()

    assert render(view) =~ "Edited Symphony"

    view
    |> element("button", "Validate")
    |> render_click()

    assert render(view) =~ "All required checks passed"

    view
    |> element("button", "Activate")
    |> render_click()

    assert render(view) =~ "Active revision"
    assert render(view) =~ "Symphony"
  end

  test "bootstrap Administrator opens Configuration through the admin route alias", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")

    assert {:ok, _view, html} = live(conn, "/admin/configuration")
    assert html =~ "Automation Project"
  end

  test "Administrator configures independent fixture integrations and sees health evidence", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    assert {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> form("#integration-form",
      integration: %{
        "id" => "tracker-fixture",
        "kind" => "tracker",
        "provider" => "fixture",
        "credential_ref" => "",
        "scenario" => "healthy",
        "owner" => "",
        "repository" => "",
        "project_slug" => "",
        "project_id" => "",
        "base_branch" => "",
        "endpoint" => "",
        "state_ids" => %{
          "started" => "state-started",
          "completed" => "state-completed",
          "cancelled" => "state-cancelled"
        }
      }
    )
    |> render_submit()

    assert get_in(Repo.one!(Revision).document, [
             "integrations",
             Access.at(0),
             "settings",
             "state_ids"
           ]) == %{
             "started" => "state-started",
             "completed" => "state-completed",
             "cancelled" => "state-cancelled"
           }

    view
    |> form("#integration-form",
      integration: %{
        "id" => "delivery-fixture",
        "kind" => "source_control",
        "provider" => "fixture",
        "credential_ref" => "",
        "scenario" => "healthy",
        "owner" => "",
        "repository" => "WangShayne/Symphony-works",
        "project_slug" => "",
        "project_id" => "",
        "base_branch" => "main",
        "endpoint" => "https://source-control.example.test/api/v4"
      }
    )
    |> render_submit()

    delivery_settings =
      Repo.one!(Revision).document
      |> get_in(["integrations", Access.at(1), "settings"])

    assert delivery_settings["api_base_url"] == "https://source-control.example.test/api/v4"
    refute Map.has_key?(delivery_settings, "endpoint")
    persisted_project = Repo.one!(Revision).document["automation_projects"] |> hd()
    assert persisted_project["tracker_integration_ref"] == "tracker-fixture"
    assert persisted_project["source_control_integration_ref"] == "delivery-fixture"

    view
    |> form("#integration-form",
      integration: %{
        "id" => "delivery-default",
        "kind" => "source_control",
        "provider" => "fixture",
        "credential_ref" => "",
        "repository" => "WangShayne/Symphony-works",
        "base_branch" => "main",
        "endpoint" => ""
      }
    )
    |> render_submit()

    default_delivery_settings =
      Repo.one!(Revision).document
      |> get_in(["integrations", Access.at(2), "settings"])

    refute Map.has_key?(default_delivery_settings, "api_base_url")
    refute Map.has_key?(default_delivery_settings, "endpoint")

    html = render(view)
    assert html =~ "Integrations / 集成"
    assert html =~ "tracker-fixture"
    assert html =~ "delivery-fixture"
    assert html =~ "delivery-default"

    view
    |> form("#draft-update-form", project: put_in(valid_project(), ["name"], "Symphony Integrations"))
    |> render_submit()

    html = render(view)
    assert html =~ "Symphony Integrations"
    assert html =~ "tracker-fixture"
    assert html =~ "delivery-fixture"

    view
    |> form("#task-type-form",
      task_type: %{
        "id" => "review",
        "name" => "Review",
        "profile_id" => "general-profile"
      }
    )
    |> render_submit()

    assert Repo.one!(Revision).document["task_types"] == [
             %{"id" => "review", "name" => "Review", "profile_id" => "general-profile"}
           ]

    view
    |> form("#task-type-form",
      task_type: %{
        "id" => "review",
        "name" => "Review updated",
        "profile_id" => "review-profile"
      }
    )
    |> render_submit()

    assert Repo.one!(Revision).document["task_types"] == [
             %{"id" => "review", "name" => "Review updated", "profile_id" => "review-profile"}
           ]

    view
    |> element("button", "Validate")
    |> render_click()

    html = render(view)
    assert html =~ "Integration health / 集成健康"
    assert html =~ "Healthy / 正常"
    assert html =~ "Deterministic fixture / 确定性夹具"
    refute html =~ "credential_ref"
  end

  test "Dashboard rejects malformed integration form events without corrupting draft", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    assert {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    assert render_submit(view, "configure_integration", %{"integration" => "bad"}) =~
             "Invalid configuration"

    assert render_submit(view, "configure_integration", %{
             "integration" => %{
               "id" => "tracker-fixture",
               "kind" => "tracker",
               "provider" => "fixture",
               "scenario" => "healthy"
             }
           }) =~ "tracker-fixture"

    integration = Repo.one!(Revision).document["integrations"] |> hd()
    refute Map.has_key?(integration, "credential_ref")
    refute Map.has_key?(integration["settings"], "state_ids")
  end

  test "Dashboard stores Source Control endpoint as api_base_url and health uses it", %{conn: conn} do
    previous = Application.get_env(:symphony_elixir, :integration_health_adapters)

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "source_control" => SourceControlEndpointHealth
    })

    on_exit(fn -> Application.put_env(:symphony_elixir, :integration_health_adapters, previous) end)

    assert {:ok, reference} =
             SecretStore.put("live-source-control", "source-control-live-secret", actor: "admin")

    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    assert {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> form("#integration-form",
      integration: %{
        "id" => "delivery-github",
        "kind" => "source_control",
        "provider" => "github",
        "credential_ref" => reference.id,
        "repository" => "WangShayne/Symphony-works",
        "base_branch" => "main",
        "endpoint" => "https://source-control.example.test/api/v4"
      }
    )
    |> render_submit()

    settings = Repo.one!(Revision).document |> get_in(["integrations", Access.at(0), "settings"])
    assert settings["api_base_url"] == "https://source-control.example.test/api/v4"
    refute Map.has_key?(settings, "endpoint")

    view
    |> element("button", "Validate")
    |> render_click()

    html = render(view)
    assert html =~ "Integration health / 集成健康"
    assert html =~ "Healthy / 正常"
    assert html =~ "custom"
    refute html =~ "missing_api_base_url"
    refute html =~ "source-control-live-secret"
    refute html =~ reference.id
  end

  test "Dashboard shows useful redacted integration health failures", %{conn: conn} do
    previous = Application.get_env(:symphony_elixir, :integration_health_adapters)

    Application.put_env(:symphony_elixir, :integration_health_adapters, %{
      "tracker" => LeakyIntegrationHealth
    })

    on_exit(fn -> Application.put_env(:symphony_elixir, :integration_health_adapters, previous) end)

    assert {:ok, api_reference} =
             SecretStore.put("dashboard-tracker-api", "dashboard-api-secret", actor: "admin")

    assert {:ok, webhook_reference} =
             SecretStore.put("dashboard-webhook", "dashboard-webhook-secret", actor: "admin")

    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    assert {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> form("#integration-form",
      integration: %{
        "id" => "tracker-main",
        "kind" => "tracker",
        "provider" => "github",
        "credential_ref" => api_reference.id,
        "webhook_secret_ref" => webhook_reference.id,
        "bot_actor_id" => "symphony-bot",
        "owner" => "WangShayne",
        "repository" => "Symphony-works",
        "project_slug" => "",
        "project_id" => "",
        "base_branch" => "",
        "endpoint" => "",
        "scenario" => "healthy"
      }
    )
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    html = render(view)
    assert html =~ "Integration health check failed / 集成健康检查失败"
    assert html =~ "tracker-main"
    assert html =~ "github"
    assert html =~ "denied"
    refute html =~ "dashboard-api-secret"
    refute html =~ "dashboard-webhook-secret"
    refute html =~ api_reference.id
    refute html =~ webhook_reference.id
  end

  test "Dashboard displays an existing active revision and validation errors", %{conn: conn} do
    {:ok, draft} =
      Configuration.create_draft(
        Document.for_project(valid_project()),
        actor: "bootstrap-admin"
      )

    {:ok, _active} = Configuration.activate(draft.id, actor: "bootstrap-admin")

    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, html} = live(conn, "/configuration")
    assert html =~ "Active revision"

    invalid = put_in(valid_project(), ["repository", "url"], "")

    view
    |> form("#project-form", project: invalid)
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    assert render(view) =~ "Invalid configuration"
    refute render(view) =~ "{:invalid_configuration"
  end

  test "Dashboard reload displays persisted active integration health evidence", %{conn: conn} do
    document =
      valid_project()
      |> Document.for_project()
      |> Map.put("integrations", [
        %{
          "id" => "tracker-fixture",
          "kind" => "tracker",
          "provider" => "fixture",
          "settings" => %{"scenario" => "healthy"}
        }
      ])

    assert {:ok, draft} = Configuration.create_draft(document, actor: "bootstrap-admin")
    assert {:ok, _active} = Configuration.activate(draft.id, actor: "bootstrap-admin")

    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    assert {:ok, _view, html} = live(conn, "/configuration")

    assert html =~ "Integration health / 集成健康"
    assert html =~ "tracker-fixture"
    assert html =~ "Deterministic fixture / 确定性夹具"
  end

  test "Dashboard renders persisted health with atom-key evidence and malformed items", %{conn: conn} do
    document = Document.for_project(valid_project())
    assert {:ok, draft} = Configuration.create_draft(document, actor: "bootstrap-admin")

    evidence = %{
      "probes" => [
        %{
          "probe" => "integrations",
          "status" => "passed",
          "integrations" => [
            %{
              "id" => "tracker-atom",
              "kind" => "tracker",
              "provider" => "fixture",
              "status" => "passed",
              "health" => %{evidence: %{scope: "atom/scope", transport: :deterministic_fixture}}
            },
            %{"id" => "missing-health", "kind" => "tracker", "provider" => "fixture"}
          ]
        }
      ]
    }

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _active} =
             draft
             |> Ecto.Changeset.change(%{
               status: :active,
               validation_evidence: evidence,
               validated_by: "bootstrap-admin",
               validated_at: now,
               activated_by: "bootstrap-admin",
               activated_at: now
             })
             |> Repo.update()

    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    assert {:ok, _view, html} = live(conn, "/configuration")

    assert html =~ "atom/scope"
    assert html =~ "Deterministic fixture / 确定性夹具"
    assert html =~ "missing-health"
  end

  test "Dashboard binds runtime models, probes, and activates compatible profiles", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    {:ok, credential_ref} = SecretStore.put("codex-provider-token", "plain-provider-token", actor: "admin")

    view
    |> form("#runtime-model-form",
      runtime_model: %{
        "provider_id" => "codex-provider",
        "provider_name" => "Codex Provider",
        "endpoint" => "http://127.0.0.1:4010",
        "credential_ref" => credential_ref.id,
        "execution_profile_id" => "general-profile",
        "roles" => %{
          "routing" =>
            runtime_model_role_params("route-primary", "codex-route-main", %{
              "context_window" => "128000",
              "capability_context_window" => "64000",
              "structured_output" => "true",
              "tool_use" => "true",
              "input_price" => "0.10",
              "cached_input_price" => "0.02",
              "output_price" => "0.40"
            }),
          "routing_fallback" =>
            runtime_model_role_params("route-fallback", "codex-route-backup", %{
              "context_window" => "64000",
              "capability_context_window" => "64000",
              "structured_output" => "true",
              "tool_use" => "true",
              "input_price" => "0.20",
              "cached_input_price" => "0.03",
              "output_price" => "0.50"
            }),
          "execution_fallback" =>
            runtime_model_role_params("exec-fallback", "codex-exec-backup", %{
              "context_window" => "96000",
              "capability_context_window" => "64000",
              "structured_output" => "true",
              "tool_use" => "true",
              "input_price" => "0.30",
              "cached_input_price" => "0.04",
              "output_price" => "0.60"
            }),
          "task" =>
            runtime_model_role_params("task-primary", "codex-task-main", %{
              "context_window" => "256000",
              "capability_context_window" => "128000",
              "structured_output" => "true",
              "tool_use" => "false",
              "input_price" => "0.40",
              "cached_input_price" => "0.05",
              "output_price" => "0.70"
            })
        }
      }
    )
    |> render_submit()

    assert render(view) =~ "Runtime models"

    view
    |> element("button", "Validate")
    |> render_click()

    assert render(view) =~ "All required checks passed"

    view
    |> element("button", "Activate")
    |> render_click()

    assert render(view) =~ "Active revision"
    active = Configuration.active!()

    assert get_in(active.document, ["routing", "model_reference_id"]) == "route-primary"
    assert get_in(active.document, ["routing", "fallback_model_reference_id"]) == "route-fallback"
    assert get_in(active.document, ["routing", "execution_fallback_model_reference_id"]) == "exec-fallback"
    assert get_in(active.document, ["execution_profiles", Access.at(0), "model_reference_id"]) == "task-primary"

    references_by_id = Map.new(active.document["model_references"], &{&1["id"], &1})

    assert Map.keys(references_by_id) |> Enum.sort() == [
             "exec-fallback",
             "route-fallback",
             "route-primary",
             "task-primary"
           ]

    assert references_by_id["route-primary"]["model_id"] == "codex-route-main"
    assert references_by_id["route-primary"]["context_window"] == 128_000

    assert references_by_id["route-primary"]["capabilities"] == %{
             "structured_output" => true,
             "tool_use" => true,
             "context_window" => 64_000
           }

    assert references_by_id["route-primary"]["prices"] == %{
             "input" => 0.10,
             "cached_input" => 0.02,
             "output" => 0.40
           }

    assert references_by_id["route-fallback"]["model_id"] == "codex-route-backup"
    assert references_by_id["route-fallback"]["context_window"] == 64_000

    assert references_by_id["route-fallback"]["capabilities"] == %{
             "structured_output" => true,
             "tool_use" => true,
             "context_window" => 64_000
           }

    assert references_by_id["route-fallback"]["prices"] == %{
             "input" => 0.20,
             "cached_input" => 0.03,
             "output" => 0.50
           }

    assert references_by_id["exec-fallback"]["model_id"] == "codex-exec-backup"
    assert references_by_id["exec-fallback"]["context_window"] == 96_000

    assert references_by_id["exec-fallback"]["capabilities"] == %{
             "structured_output" => true,
             "tool_use" => true,
             "context_window" => 64_000
           }

    assert references_by_id["exec-fallback"]["prices"] == %{
             "input" => 0.30,
             "cached_input" => 0.04,
             "output" => 0.60
           }

    assert references_by_id["task-primary"]["model_id"] == "codex-task-main"
    assert references_by_id["task-primary"]["context_window"] == 256_000

    assert references_by_id["task-primary"]["capabilities"] == %{
             "structured_output" => true,
             "tool_use" => false,
             "context_window" => 128_000
           }

    assert references_by_id["task-primary"]["prices"] == %{
             "input" => 0.40,
             "cached_input" => 0.05,
             "output" => 0.70
           }

    assert get_in(active.document, ["routing", "profile", "required_capabilities"]) == %{
             "structured_output" => true,
             "tool_use" => true,
             "context_window" => 64_000
           }

    assert get_in(active.document, ["execution_profiles", Access.at(0), "required_capabilities"]) == %{
             "structured_output" => true,
             "tool_use" => false,
             "context_window" => 64_000
           }
  end

  test "Dashboard model binding handles stale drafts and invalid numeric defaults", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    Repo.delete_all(Revision)

    assert view
           |> form("#runtime-model-form",
             runtime_model: %{
               "provider_id" => "codex-provider",
               "provider_name" => "Codex Provider",
               "endpoint" => "http://127.0.0.1:4010",
               "credential_ref" => "00000000-0000-0000-0000-000000000001",
               "execution_profile_id" => "general-profile",
               "roles" => %{}
             }
           )
           |> render_submit() =~ "Configuration revision not found"

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> form("#runtime-model-form",
      runtime_model: %{
        "provider_id" => "codex-provider",
        "provider_name" => "",
        "endpoint" => "http://127.0.0.1:4010",
        "credential_ref" => "00000000-0000-0000-0000-000000000001",
        "execution_profile_id" => "general-profile",
        "roles" => %{
          "routing" =>
            runtime_model_role_params("routing-model", "codex-routing", %{
              "context_window" => "not-a-number",
              "capability_context_window" => "not-a-number",
              "structured_output" => "false",
              "tool_use" => "true",
              "input_price" => "not-a-number",
              "cached_input_price" => "-1",
              "output_price" => "2.25"
            })
        }
      }
    )
    |> render_submit()

    [latest] = Repo.all(Revision)
    assert get_in(latest.document, ["providers", Access.at(0), "name"]) == "Codex Provider"
    assert get_in(latest.document, ["model_references", Access.at(0), "context_window"]) == 128_000
    assert get_in(latest.document, ["model_references", Access.at(0), "capabilities", "structured_output"]) == false

    assert get_in(latest.document, ["model_references", Access.at(0), "prices"]) == %{
             "input" => 0,
             "cached_input" => 0,
             "output" => 2.25
           }

    render_submit(view, "bind_runtime_model", %{
      "runtime_model" => %{
        "provider_id" => "codex-provider",
        "provider_name" => "Codex Provider",
        "endpoint" => "http://127.0.0.1:4010",
        "credential_ref" => "00000000-0000-0000-0000-000000000001",
        "execution_profile_id" => "general-profile",
        "roles" => %{
          "routing" =>
            runtime_model_role_params("routing-model", "codex-routing", %{
              "context_window" => "128000",
              "capability_context_window" => "96000",
              "structured_output" => "maybe",
              "tool_use" => "true",
              "input_price" => "0",
              "cached_input_price" => "0",
              "output_price" => "0"
            })
        }
      }
    })

    [latest] = Repo.all(Revision)
    assert get_in(latest.document, ["model_references", Access.at(0), "capabilities", "structured_output"]) == true
  end

  test "Dashboard task type creation handles stale drafts", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    Repo.delete_all(Revision)

    assert view
           |> form("#task-type-form",
             task_type: %{"id" => "review", "name" => "Review", "profile_id" => "general-profile"}
           )
           |> render_submit() =~ "Configuration revision not found"
  end

  test "Dashboard rejects plaintext runtime credentials before persistence", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    assert view
           |> form("#runtime-model-form",
             runtime_model: %{
               "provider_id" => "codex-provider",
               "provider_name" => "Codex Provider",
               "endpoint" => "http://127.0.0.1:4010",
               "credential_ref" => "sk-plaintext-runtime-secret",
               "execution_profile_id" => "general-profile",
               "roles" => %{}
             }
           )
           |> render_submit() =~ "Invalid configuration"

    [latest] = Repo.all(Revision)
    refute inspect(latest.document) =~ "sk-plaintext-runtime-secret"
  end

  test "Dashboard reports a malformed create request without crashing", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    assert render_submit(view, "create", %{}) =~ "Invalid configuration"
    assert has_element?(view, ~s([role="alert"]))
  end

  test "mounted bootstrap Dashboard cannot create after bootstrap retires", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    assert {:ok, _admin} =
             Identity.upsert_oidc_principal(%{
               issuer: "https://issuer.example.test",
               subject: "retiring-admin",
               email: "admin@example.test",
               roles: [:administrator]
             })

    assert Repo.aggregate(Revision, :count) == 0

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    assert_redirect(view, "/auth/login")
    assert Repo.aggregate(Revision, :count) == 0
  end

  test "mounted bootstrap Dashboard cannot configure integrations after bootstrap retires", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    assert {:ok, _admin} =
             Identity.upsert_oidc_principal(%{
               issuer: "https://issuer.example.test",
               subject: "retiring-integration-admin",
               email: "admin@example.test",
               roles: [:administrator]
             })

    view
    |> form("#integration-form",
      integration: %{"id" => "tracker-fixture", "kind" => "tracker", "provider" => "fixture"}
    )
    |> render_submit()

    assert_redirect(view, "/auth/login")
  end

  test "mounted bootstrap Dashboard cannot create task types after bootstrap retires", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    assert {:ok, _admin} =
             Identity.upsert_oidc_principal(%{
               issuer: "https://issuer.example.test",
               subject: "retiring-task-type-admin",
               email: "admin@example.test",
               roles: [:administrator]
             })

    render_submit(view, "create_task_type", %{})

    assert_redirect(view, "/auth/login")
  end

  test "Dashboard reports when a validated revision disappears before activation", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    Repo.delete_all(Revision)

    assert view
           |> element("button", "Activate")
           |> render_click() =~ "Configuration revision not found"

    assert has_element?(view, ~s([role="alert"]))
    refute has_element?(view, "#active-revision")
  end

  test "Dashboard reports when a draft disappears before update", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    Repo.delete_all(Revision)

    assert view
           |> form("#draft-update-form", project: put_in(valid_project(), ["name"], "Missing"))
           |> render_submit() =~ "Configuration revision not found"
  end

  test "Dashboard imports workflow, exports redacted configuration, and rolls back", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> element("button", "Use starter templates")
    |> render_click()

    assert render(view) =~ "General profile"

    view
    |> form("#workflow-import-form", workflow: %{"content" => workflow_content()})
    |> render_submit()

    assert render(view) =~ "Imported WORKFLOW.md"

    view
    |> form("#integration-form",
      integration: %{
        "id" => "tracker",
        "kind" => "tracker",
        "provider" => "fixture",
        "credential_ref" => "",
        "webhook_secret_ref" => "",
        "bot_actor_id" => "",
        "scenario" => "healthy",
        "owner" => "",
        "repository" => "",
        "project_slug" => "",
        "project_id" => "",
        "base_branch" => "",
        "endpoint" => ""
      }
    )
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    view
    |> element("button", "Activate")
    |> render_click()

    assert render(view) =~ "Active revision"

    view
    |> element("button", "Export")
    |> render_click()

    exported = render(view)
    refute exported =~ "ghp_live_secret"
    refute exported =~ "api_key"

    view
    |> form("#project-form", project: put_in(valid_project(), ["name"], "Replacement"))
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    view
    |> element("button", "Activate")
    |> render_click()

    assert render(view) =~ "Replacement"

    view
    |> element("button", "Rollback")
    |> render_click()

    assert render(view) =~ "Imported WORKFLOW.md"
  end

  test "Dashboard normalizes invalid import, stale export, and rollback errors", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    assert render_submit(view, "import_workflow", %{}) =~ "Invalid configuration"
    assert render_submit(view, "import_workflow", %{"workflow" => %{}}) =~ "Invalid configuration"

    assert render_submit(view, "import_workflow", %{"workflow" => %{"path" => "/etc/passwd"}}) =~
             "Invalid configuration"

    refute render(view) =~ "root:"

    view
    |> form("#workflow-import-form", workflow: %{"content" => "---\n["})
    |> render_submit()

    assert render(view) =~ "Invalid configuration"

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    view
    |> element("button", "Activate")
    |> render_click()

    Repo.delete_all(Revision)

    view
    |> element("button", "Export")
    |> render_click()

    assert render(view) =~ "Configuration revision not found"

    assert render_click(view, "rollback", %{"id" => Ecto.UUID.generate()}) =~
             "Configuration revision not found"
  end

  test "Dashboard activation invokes configured probes without exposing probe details", %{conn: conn} do
    previous = Application.get_env(:symphony_elixir, :configuration_probes)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :configuration_probes, previous)
    end)

    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    Application.put_env(:symphony_elixir, :configuration_probes, [FailingProbe])

    view
    |> element("button", "Activate")
    |> render_click()

    html = render(view)
    assert html =~ "Invalid configuration"
    refute html =~ "secret"
    refute html =~ "offline"
  end

  test "Dashboard treats invalid probe configuration as no probes", %{conn: conn} do
    previous = Application.get_env(:symphony_elixir, :configuration_probes)
    Application.put_env(:symphony_elixir, :configuration_probes, :invalid)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :configuration_probes, previous)
    end)

    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    view
    |> form("#project-form", project: valid_project())
    |> render_submit()

    view
    |> element("button", "Validate")
    |> render_click()

    view
    |> element("button", "Activate")
    |> render_click()

    assert render(view) =~ "Active revision"
  end

  defp valid_project do
    %{
      "id" => "symphony",
      "name" => "Symphony",
      "tracker" => %{"kind" => "github", "scope" => "WangShayne/Symphony-works"},
      "repository" => %{
        "url" => "git@github.com:WangShayne/Symphony-works.git",
        "target_branch" => "main"
      }
    }
  end

  defp runtime_model_role_params(reference_id, model_id, attrs) do
    Map.merge(attrs, %{"reference_id" => reference_id, "model_id" => model_id})
  end

  defp workflow_content do
    """
    ---
    tracker:
      kind: github
      project_slug: WangShayne/Symphony-works
      api_key: ghp_live_secret
    codex:
      command: codex app-server
    ---
    Imported LiveView prompt.
    """
  end
end
