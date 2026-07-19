defmodule SymphonyElixirWeb.ConfigurationLiveTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.{Document, Revision}
  alias SymphonyElixir.Repo

  @bootstrap_token "test-bootstrap-token-with-32-bytes"

  defmodule FailingProbe do
    @behaviour SymphonyElixir.Configuration.Probe

    @impl true
    def validate(_document), do: {:error, {:model, %{"message" => "offline", "api_key" => "secret"}}}
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

  test "Dashboard reports a malformed create request without crashing", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration")

    assert render_submit(view, "create", %{}) =~ "Invalid configuration"
    assert has_element?(view, ~s([role="alert"]))
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
    assert exported =~ "[REDACTED]"

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
