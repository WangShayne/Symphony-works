defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :trusted_admin_api do
    plug(:accepts, ["json"])
    plug(SymphonyElixirWeb.Auth.TrustedAdminPlug, surface: :api)
  end

  pipeline :authenticated_browser do
    plug(SymphonyElixirWeb.Auth.SessionPlug)
  end

  pipeline :authenticated_api do
    plug(:accepts, ["json"])
    plug(SymphonyElixirWeb.Auth.BearerPlug)
  end

  pipeline :api_read_task do
    plug(SymphonyElixirWeb.Plugs.Authorize, action: :read_task)
  end

  pipeline :api_create_task do
    plug(SymphonyElixirWeb.Plugs.Authorize, action: :create_task)
  end

  pipeline :api_retry_task do
    plug(SymphonyElixirWeb.Plugs.Authorize, action: :retry_task)
  end

  pipeline :api_write_configuration do
    plug(SymphonyElixirWeb.Plugs.Authorize, action: :write_configuration)
  end

  pipeline :api_write_secret do
    plug(SymphonyElixirWeb.Plugs.Authorize, action: :write_secret)
  end

  pipeline :trusted_admin_browser do
    plug(SymphonyElixirWeb.Auth.TrustedAdminPlug, surface: :browser)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    get("/auth/login", Auth.Controller, :login)
    get("/auth/logout", Auth.Controller, :logout)
    get("/auth/oidc/start", Auth.Controller, :start)
    get("/auth/oidc/callback", Auth.Controller, :callback)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :authenticated_browser])

    live("/tasks", TaskLive, :index)
    live("/tasks/:id", TaskLive, :show)
    live("/:locale/tasks", TaskLive, :index)
    live("/:locale/tasks/:id", TaskLive, :show)
    live("/interventions", PlaceholderLive, :index)
    live("/projects", PlaceholderLive, :index)
    live("/models", PlaceholderLive, :index)
    live("/profiles", PlaceholderLive, :index)
    live("/integrations", PlaceholderLive, :index)
    live("/audit", PlaceholderLive, :index)
    live("/health", PlaceholderLive, :index)
    live("/backups", PlaceholderLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :trusted_admin_browser])

    live("/admin/configuration", ConfigurationLive, :index)
    live("/configuration", ConfigurationLive, :index)
    live("/configuration/secrets", Configuration.SecretLive, :index)
  end

  scope "/api/v1", SymphonyElixirWeb.Api.V1 do
    pipe_through(:trusted_admin_api)

    post("/automation-projects", AutomationProjectController, :create)
    get("/configuration/templates", AutomationProjectController, :templates)
    post("/configuration-revisions/import-workflow", AutomationProjectController, :import_workflow)
    patch("/configuration-revisions/:id", AutomationProjectController, :update)
    post("/secrets", SecretController, :create)
    patch("/secrets/:id", SecretController, :replace)

    post(
      "/configuration-revisions/:id/providers/:provider_id/credential-ref",
      AutomationProjectController,
      :bind_provider_credential
    )

    post("/configuration-revisions/:id/validate", AutomationProjectController, :validate)
    post("/configuration-revisions/:id/activate", AutomationProjectController, :activate)
    post("/configuration-revisions/:id/rollback", AutomationProjectController, :rollback)
    get("/configuration-revisions/:id/export", AutomationProjectController, :export)
    get("/configuration-revisions/active", AutomationProjectController, :active)
    post("/configuration-task-pins", AutomationProjectController, :pin_task)
    get("/configuration-task-pins/:task_id", AutomationProjectController, :pinned_task)
  end

  scope "/api/v1", SymphonyElixirWeb.Api.V1 do
    pipe_through([:authenticated_api, :api_read_task])

    get("/tasks", TaskController, :index)
    get("/tasks/:id", TaskController, :show)
  end

  scope "/api/v1", SymphonyElixirWeb.Api.V1 do
    pipe_through([:authenticated_api, :api_create_task])

    post("/tasks", TaskController, :create)
  end

  scope "/api/v1", SymphonyElixirWeb.Api.V1 do
    pipe_through([:authenticated_api, :api_retry_task])

    post("/tasks/:id/retry", PlaceholderController, :accepted)
  end

  scope "/api/v1", SymphonyElixirWeb.Api.V1 do
    pipe_through([:authenticated_api, :api_write_configuration])

    get("/configuration", PlaceholderController, :index, resource: "configuration")
  end

  scope "/api/v1", SymphonyElixirWeb.Api.V1 do
    pipe_through([:authenticated_api, :api_write_secret])

    get("/secrets", PlaceholderController, :index, resource: "secrets")
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/runner/health", RunnerHealthController, :show)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runner/health", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
