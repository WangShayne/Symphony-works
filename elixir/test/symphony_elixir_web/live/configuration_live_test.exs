defmodule SymphonyElixirWeb.ConfigurationLiveTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.{Document, Revision}
  alias SymphonyElixir.Repo

  @bootstrap_token "test-bootstrap-token-with-32-bytes"

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
