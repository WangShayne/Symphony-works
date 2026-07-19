defmodule SymphonyElixirWeb.AuthTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Identity
  alias SymphonyElixir.Identity.Principal
  alias SymphonyElixir.Identity.{RoleList, StringList}
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore
  alias SymphonyElixirWeb.Auth.OIDC
  alias SymphonyElixirWeb.Auth.TrustedAdminPlug
  alias SymphonyElixirWeb.Configuration
  alias SymphonyElixirWeb.ConfigurationLive

  @bootstrap_token "test-bootstrap-token-with-32-bytes"

  defmodule FakeAssentOIDC do
    @moduledoc false

    def authorize_url(config) do
      send(Keyword.fetch!(config, :test_pid), {:assent_authorize_url, config})

      {:ok,
       %{
         url: "https://idp.example.test/authorize",
         session_params: %{state: "assent-state", nonce: Keyword.fetch!(config, :nonce), code_verifier: "verifier-1"}
       }}
    end

    def callback(config, params) do
      send(Keyword.fetch!(config, :test_pid), {:assent_callback, config, params})

      {:ok,
       %{
         user: %{
           "sub" => "delegated-admin",
           "email" => "delegated-admin@example.test",
           "name" => "Delegated Admin",
           "roles" => [:administrator]
         }
       }}
    end
  end

  test "browser and API routes require an authenticated principal", %{conn: conn} do
    assert TrustedAdminPlug.init(surface: :api) == [surface: :api]
    assert redirected_to(get(conn, "/tasks")) == "/auth/login"
    assert redirected_to(get(conn, "/configuration")) == "/auth/login"
    assert redirected_to(get(init_test_session(conn, %{"principal_id" => "malformed-principal-id"}), "/configuration")) == "/auth/login"
    assert redirected_to(get(init_test_session(conn, %{"principal_id" => Ecto.UUID.generate()}), "/configuration")) == "/auth/login"
    assert redirected_to(get(test_header_conn(conn, Ecto.UUID.generate()), "/configuration")) == "/auth/login"

    response =
      conn
      |> recycle()
      |> get("/api/v1/tasks")
      |> json_response(401)

    assert %{"error" => %{"code" => "unauthorized"}} = response
  end

  test "Viewer, Operator, and Administrator protect configuration actions", %{conn: conn} do
    viewer = insert_principal!(roles: [:viewer])
    operator = insert_principal!(roles: [:operator])
    admin = insert_principal!(roles: [:administrator])

    assert get(api_conn(conn, viewer), "/api/v1/tasks").status == 200
    assert get(api_conn(conn, viewer), "/api/v1/configuration").status == 403

    assert post(api_conn(conn, operator), "/api/v1/tasks/demo/retry").status == 202
    assert get(api_conn(conn, operator), "/api/v1/secrets").status == 403

    assert get(api_conn(conn, admin), "/api/v1/configuration").status == 200
    assert get(api_conn(conn, admin), "/api/v1/secrets").status == 200
  end

  test "post-retirement Administrators access real configuration browser surfaces", %{conn: conn} do
    admin = insert_principal!(roles: [:administrator])
    viewer = insert_principal!(roles: [:viewer])
    operator = insert_principal!(roles: [:operator])
    assert Identity.bootstrap_retired?()

    assert {:ok, _view, configuration_html} = live(browser_conn(conn, admin), "/configuration")
    assert configuration_html =~ "Automation Project"

    assert {:ok, _view, secrets_html} = live(browser_conn(conn, admin), "/configuration/secrets")
    assert secrets_html =~ "Secrets"

    assert get(browser_conn(conn, viewer), "/configuration").status == 403
    assert get(browser_conn(conn, operator), "/configuration/secrets").status == 403

    assert get(test_header_conn(conn, admin), "/configuration").status == 200
  end

  test "configuration LiveViews fail closed when mount receives stale or revoked sessions", %{conn: conn} do
    viewer = insert_principal!(roles: [:viewer])

    assert {:error, :not_found} = Identity.get_principal("malformed-principal-id")

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, ConfigurationLive, session: %{})

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, ConfigurationLive, session: %{"principal_id" => "malformed-principal-id"})

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, ConfigurationLive, session: %{"principal_id" => Ecto.UUID.generate()})

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, ConfigurationLive, session: %{"principal_id" => viewer.id})

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, Configuration.SecretLive, session: %{})

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, Configuration.SecretLive, session: %{"principal_id" => Ecto.UUID.generate()})

    assert {:error, {:redirect, %{to: "/auth/login"}}} =
             live_isolated(conn, Configuration.SecretLive, session: %{"principal_id" => viewer.id})
  end

  test "post-retirement Administrator service credentials access real configuration and secret REST actions", %{
    conn: conn
  } do
    _admin = insert_principal!(roles: [:administrator])
    assert Identity.bootstrap_retired?()

    {:ok, admin_token, _service} =
      Identity.create_service_credential(%{
        name: "admin-service",
        roles: [:administrator],
        scopes: ["configuration:write"]
      })

    {:ok, viewer_token, _service} =
      Identity.create_service_credential(%{
        name: "viewer-service",
        roles: [:viewer],
        scopes: ["tasks:read"]
      })

    {:ok, operator_token, _service} =
      Identity.create_service_credential(%{
        name: "operator-service",
        roles: [:operator],
        scopes: ["tasks:control"]
      })

    assert get(api_conn(conn, admin_token), "/api/v1/configuration/templates").status == 200

    create_project =
      conn
      |> api_conn(admin_token)
      |> post("/api/v1/automation-projects", %{"project" => valid_project()})

    assert create_project.status == 201

    create_secret =
      conn
      |> api_conn(admin_token)
      |> post("/api/v1/secrets", %{"secret" => %{"name" => "github", "value" => "api-secret-value"}})

    assert create_secret.status == 201

    assert get(api_conn(conn, viewer_token), "/api/v1/configuration/templates").status == 403
    assert post(api_conn(conn, operator_token), "/api/v1/secrets", %{"secret" => %{"name" => "github", "value" => "x"}}).status == 403

    header_admin = insert_principal!(roles: [:administrator])
    assert get(api_conn(conn, header_admin), "/api/v1/configuration/templates").status == 200
    assert get(api_conn(conn, Ecto.UUID.generate()), "/api/v1/configuration/templates").status == 401
    assert get(api_conn(conn, "not-a-valid-token"), "/api/v1/configuration/templates").status == 401
  end

  test "OIDC callback binds the first Administrator and permanently retires bootstrap", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{"oidc_state" => "state-1", "oidc_nonce" => "nonce-1"})
      |> get("/auth/oidc/callback", %{"code" => "admin-code", "state" => "state-1"})

    assert redirected_to(conn) == "/tasks"
    assert [%{roles: roles}] = Repo.all(Identity.PrincipalRecord)
    assert :administrator in roles
    assert Identity.bootstrap_retired?()

    assert build_conn()
           |> put_req_header("authorization", "Bearer #{@bootstrap_token}")
           |> get("/configuration")
           |> response(401)

    assert Identity.bootstrap_retired?()
  end

  test "OIDC callback rejects bad state and never binds a principal", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{"oidc_state" => "state-1", "oidc_nonce" => "nonce-1"})
      |> get("/auth/oidc/callback", %{"code" => "admin-code", "state" => "attacker"})

    assert redirected_to(conn) == "/auth/login?error=sign_in_failed"
    assert Repo.all(Identity.PrincipalRecord) == []
    refute Identity.bootstrap_retired?()
  end

  test "OIDC login rejects unsafe return URLs and callback rejects bad code", %{conn: conn} do
    assert {:error, :unavailable} = OIDC.authorize_url(nil)
    assert {:ok, _url, %{return_to: "/tasks"}} = OIDC.authorize_url("https://evil.example.test")

    assert html_response(get(conn, "/auth/login"), 200) =~ "Continue with OIDC"
    assert html_response(get(conn, "/auth/login", %{"error" => "sign_in_failed"}), 200) =~ "Sign in failed"

    login_conn = get(conn, "/auth/oidc/start", %{"return_to" => "https://evil.example.test"})
    assert redirected_to(login_conn) =~ "/auth/oidc/callback"
    assert get_session(login_conn, "return_to") == "/tasks"

    callback_conn =
      conn
      |> recycle()
      |> init_test_session(%{"oidc_state" => "state-1", "oidc_nonce" => "nonce-1"})
      |> get("/auth/oidc/callback", %{"code" => "bad-code", "state" => "state-1"})

    assert redirected_to(callback_conn) == "/auth/login?error=sign_in_failed"
  end

  test "production OIDC callback delegates complete params and exact session params to Assent" do
    previous_auth = Application.get_env(:symphony_elixir, :auth)
    previous_oidc = Application.get_env(:symphony_elixir, :oidc)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :auth, previous_auth)
      Application.put_env(:symphony_elixir, :oidc, previous_oidc)
    end)

    {:ok, secret_ref} = SecretStore.put("oidc-client-secret", "brokered-client-secret", actor: "test")

    Application.put_env(:symphony_elixir, :auth, mode: :oidc)

    Application.put_env(:symphony_elixir, :oidc,
      issuer: "https://issuer.example.test",
      client_id: "client-1",
      client_secret_ref: SecretStore.export_reference(secret_ref),
      redirect_uri: "https://symphony.example.test/auth/oidc/callback",
      oidc_strategy: FakeAssentOIDC,
      test_pid: self()
    )

    session_params = %{state: "state-1", nonce: "nonce-1", code_verifier: "verifier-1"}
    callback_params = %{"code" => "code-1", "state" => "state-1", "iss" => "https://issuer.example.test"}

    assert {:ok, "https://idp.example.test/authorize", authorize_session} = OIDC.authorize_url("/configuration")
    assert authorize_session.return_to == "/configuration"
    assert authorize_session.session_params.code_verifier == "verifier-1"

    assert_receive {:assent_authorize_url, authorize_config}
    assert Keyword.fetch!(authorize_config, :code_verifier) == true
    assert Keyword.fetch!(authorize_config, :client_secret) == "brokered-client-secret"
    refute Keyword.has_key?(authorize_config, :client_secret_ref)

    assert {:ok, %{subject: "delegated-admin", nonce: "nonce-1"}} =
             OIDC.callback(callback_params, %{
               "oidc_nonce" => "nonce-1",
               "oidc_session_params" => session_params
             })

    assert_receive {:assent_callback, config, ^callback_params}
    assert Keyword.fetch!(config, :session_params) == session_params
    assert Keyword.fetch!(config, :code_verifier) == true
    assert Keyword.fetch!(config, :client_secret) == "brokered-client-secret"
    refute Keyword.has_key?(config, :client_secret_ref)
  end

  test "service bearer authentication rejects malformed and revoked tokens", %{conn: conn} do
    assert conn
           |> put_req_header("authorization", "Bearer not-a-valid-token")
           |> get("/api/v1/tasks")
           |> json_response(401)
           |> get_in(["error", "code"]) == "unauthorized"

    {:ok, token, service} =
      Identity.create_service_credential(%{
        name: "ci",
        roles: [:operator],
        scopes: ["tasks:control"]
      })

    assert post(api_conn(conn, token), "/api/v1/tasks/demo/retry").status == 202
    assert :ok = Identity.revoke_service_credential(service.id)

    assert post(api_conn(conn, token), "/api/v1/tasks/demo/retry").status == 401
  end

  test "service bearer credentials persist only hashes and validate input" do
    {:ok, token, service} =
      Identity.create_service_credential(%{
        name: "deploy",
        roles: ["operator", :viewer],
        scopes: ["tasks:control", "tasks:control"]
      })

    refute service.token_hash == token
    assert byte_size(service.token_hash) == 32
    assert service.roles == [:operator, :viewer]
    assert service.scopes == ["tasks:control"]
    assert {:error, :not_found} = Identity.revoke_service_credential(Ecto.UUID.generate())
    assert {:error, changeset} = Identity.create_service_credential(%{name: "", roles: [:viewer], scopes: [""]})
    refute changeset.valid?

    assert {:ok, [:viewer, :administrator]} = RoleList.cast(["viewer", "administrator"])
    assert :error = RoleList.cast(["owner"])
    assert :error = RoleList.cast(["missing-role-#{System.unique_integer([:positive])}"])
    assert :error = RoleList.cast(:viewer)
    assert :error = RoleList.cast([:owner])
    assert :error = RoleList.load("[")
    assert :error = RoleList.load(:bad)
    assert :error = RoleList.dump(:viewer)
    assert {:ok, ["a"]} = StringList.cast(["a", "a"])
    assert :error = StringList.cast([""])
    assert :error = StringList.cast(:bad)
    assert :error = StringList.load(:bad)
    assert :error = StringList.dump(:bad)
  end

  test "OIDC principal mapping updates existing users and defaults to viewer after bootstrap retirement" do
    assert {:error, :not_found} = Identity.get_principal(Ecto.UUID.generate())

    {:error, changeset} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "bad-role",
        roles: [:owner]
      })

    refute changeset.valid?

    {:ok, admin} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "first-admin",
        roles: [:administrator]
      })

    assert :administrator in admin.roles
    assert Identity.bootstrap_retired?()

    {:ok, updated} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "first-admin",
        email: "updated@example.test",
        roles: [:administrator, :viewer]
      })

    assert updated.id == admin.id
    assert updated.email == "updated@example.test"

    {:ok, viewer} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "late-user"
      })

    assert viewer.roles == [:viewer]
    assert {:error, :unauthorized} = Identity.verify_service_token(nil)
  end

  test "English and Simplified Chinese navigation expose identical authorized keys", %{conn: conn} do
    admin = insert_principal!(roles: [:administrator])

    en = nav_keys(get(browser_conn(conn, admin), "/tasks"))
    zh = nav_keys(get(browser_conn(conn, admin), "/zh-CN/tasks"))

    assert en == zh
    assert en != []
    assert html_response(get(browser_conn(conn, admin), "/zh-CN/tasks"), 200) =~ "任务"
  end

  test "test principal injection is explicitly disabled outside test auth mode", %{conn: conn} do
    previous = Application.get_env(:symphony_elixir, :auth)
    admin = insert_principal!(roles: [:administrator])

    on_exit(fn -> Application.put_env(:symphony_elixir, :auth, previous) end)

    Application.put_env(:symphony_elixir, :auth, mode: :oidc)

    assert get(api_conn(conn, admin), "/api/v1/tasks").status == 401
  end

  test "production rejects test auth mode" do
    previous_auth = Application.get_env(:symphony_elixir, :auth)
    previous_env = Application.get_env(:symphony_elixir, :env)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :auth, previous_auth)
      Application.put_env(:symphony_elixir, :env, previous_env)
    end)

    Application.put_env(:symphony_elixir, :auth, mode: :test)
    Application.put_env(:symphony_elixir, :env, :prod)

    assert_raise ArgumentError, ~r/not allowed in production/, &Identity.validate_auth_configuration!/0
  end

  defp insert_principal!(attrs) do
    {:ok, principal} =
      Identity.upsert_oidc_principal(%{
        issuer: "https://issuer.example.test",
        subject: "subject-#{System.unique_integer([:positive])}",
        email: "user#{System.unique_integer([:positive])}@example.test",
        roles: Keyword.fetch!(attrs, :roles)
      })

    principal
  end

  defp api_conn(conn, %Principal{} = principal) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-symphony-test-principal", principal.id)
  end

  defp api_conn(conn, token) when is_binary(token) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp browser_conn(conn, %Principal{} = principal) do
    conn
    |> recycle()
    |> init_test_session(%{"principal_id" => principal.id})
  end

  defp test_header_conn(conn, %Principal{} = principal) do
    conn
    |> recycle()
    |> put_req_header("x-symphony-test-principal", principal.id)
  end

  defp test_header_conn(conn, principal_id) when is_binary(principal_id) do
    conn
    |> recycle()
    |> put_req_header("x-symphony-test-principal", principal_id)
  end

  defp nav_keys(conn) do
    conn
    |> html_response(200)
    |> Floki.parse_document!()
    |> Floki.attribute("[data-nav-key]", "data-nav-key")
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
end
