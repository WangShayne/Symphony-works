defmodule SymphonyElixir.Identity.AuthorizationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Identity.Authorization
  alias SymphonyElixir.Identity.Principal

  test "roles separate read, task control, and secret management" do
    viewer = %Principal{id: "v", subject: "viewer@example.test", roles: [:viewer]}
    operator = %Principal{id: "o", subject: "operator@example.test", roles: [:operator]}
    admin = %Principal{id: "a", subject: "admin@example.test", roles: [:administrator]}

    assert :ok = Authorization.authorize(viewer, :read_task)
    assert {:error, :forbidden} = Authorization.authorize(viewer, :retry_task)
    assert {:error, :forbidden} = Authorization.authorize(viewer, :write_configuration)

    assert :ok = Authorization.authorize(operator, :read_task)
    assert :ok = Authorization.authorize(operator, :create_task)
    assert :ok = Authorization.authorize(operator, :retry_task)
    assert {:error, :forbidden} = Authorization.authorize(operator, :write_secret)

    assert :ok = Authorization.authorize(admin, :read_task)
    assert :ok = Authorization.authorize(admin, :retry_task)
    assert :ok = Authorization.authorize(admin, :write_secret)
  end

  test "localized navigation is derived from the same authorization decisions" do
    viewer = %Principal{id: "v", subject: "viewer@example.test", roles: [:viewer]}
    admin = %Principal{id: "a", subject: "admin@example.test", roles: [:administrator]}

    viewer_en = Authorization.authorized_navigation(viewer, "en") |> Enum.map(& &1.key)
    viewer_zh = Authorization.authorized_navigation(viewer, "zh-CN") |> Enum.map(& &1.key)
    admin_en = Authorization.authorized_navigation(admin, "en") |> Enum.map(& &1.key)
    admin_zh = Authorization.authorized_navigation(admin, "zh-CN") |> Enum.map(& &1.key)

    assert viewer_en == viewer_zh
    assert admin_en == admin_zh
    assert :tasks in viewer_en
    refute :secrets in viewer_en
    assert :secrets in admin_en
  end

  test "unknown actors and actions are denied without raising" do
    assert {:error, :unauthorized} = Authorization.authorize(nil, :read_task)
    assert {:error, :unauthorized} = Authorization.authorize(%{}, :read_task)

    viewer = %Principal{id: "v", subject: "viewer@example.test", roles: [:viewer]}

    assert {:error, :forbidden} = Authorization.authorize(viewer, :unknown_action)
    assert :create_task = Authorization.action_for_path("POST", "/api/v1/tasks")
    assert :create_task = Authorization.action_for_path("POST", "/api/v1/tasks/")
    assert :read_task = Authorization.action_for_path("GET", "/api/v1/tasks")
    assert :write_secret = Authorization.action_for_path("GET", "/api/v1/secrets")
    assert :write_configuration = Authorization.action_for_path("GET", "/api/v1/configuration")
    assert :retry_task = Authorization.action_for_path("POST", "/api/v1/tasks/demo/retry")
    assert :read_task = Authorization.action_for_path("GET", "")
    assert :read_task = Authorization.action_for_path("GET", "/api/v1/tasks")
    assert :read_task = Authorization.action_for_path("GET", "/api/v1/unknown")
    assert :write_secret = Authorization.action_for_path("GET", "/configuration/secrets")
    assert :write_configuration = Authorization.action_for_path("GET", "/configuration")
    assert :read_task = Authorization.action_for_path("GET", "/unknown")
  end
end
