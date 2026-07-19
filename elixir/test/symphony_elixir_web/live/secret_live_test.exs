defmodule SymphonyElixirWeb.SecretLiveTest do
  use SymphonyElixirWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.{Document, Revision}
  alias SymphonyElixir.Identity
  alias SymphonyElixir.Repo
  alias SymphonyElixir.Security.SecretStore

  @bootstrap_token "test-bootstrap-token-with-32-bytes"

  test "secret form never re-renders plaintext after create or replace", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")

    assert {:ok, view, html} = live(conn, "/configuration/secrets")
    assert html =~ "Secrets"

    html =
      view
      |> form("#secret-form", secret: %{"name" => "github", "value" => "plain-value"})
      |> render_submit()

    assert html =~ "Secret reference"
    refute html =~ "plain-value"

    html =
      view
      |> form("#secret-form", secret: %{"name" => "github", "value" => "replacement-value"})
      |> render_submit()

    assert html =~ "Secret reference"
    refute html =~ "replacement-value"

    html =
      view
      |> form("#secret-form", secret: %{"name" => "github", "value" => ""})
      |> render_submit()

    assert html =~ "Secret could not be stored"
  end

  test "secret form reports malformed submissions without echoing plaintext", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")

    assert {:ok, view, _html} = live(conn, "/configuration/secrets")

    html = render_submit(view, "save", %{})

    assert html =~ "Secret could not be stored"
    refute html =~ "plain-value"

    html = render_submit(view, "save", %{"secret" => %{"name" => "github", "value" => "plain-value"}})

    assert html =~ "Secret reference"
    refute html =~ "plain-value"

    html =
      render_submit(view, "save", %{
        "secret" => %{"reference_id" => Ecto.UUID.generate(), "name" => "github", "value" => "plain-value"}
      })

    assert html =~ "Secret could not be stored"
    refute html =~ "plain-value"
  end

  test "mounted bootstrap secrets Dashboard cannot store after bootstrap retires", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")
    {:ok, view, _html} = live(conn, "/configuration/secrets")

    assert {:ok, _admin} =
             Identity.upsert_oidc_principal(%{
               issuer: "https://issuer.example.test",
               subject: "retiring-admin",
               email: "admin@example.test",
               roles: [:administrator]
             })

    before_references = SecretStore.list_references()
    refute Enum.any?(before_references, &(&1.name == "github"))

    view
    |> form("#secret-form", secret: %{"name" => "github", "value" => "plain-value"})
    |> render_submit()

    assert_redirect(view, "/auth/login")

    after_references = SecretStore.list_references()
    refute Enum.any?(after_references, &(&1.name == "github"))
    assert MapSet.new(after_references, & &1.id) == MapSet.new(before_references, & &1.id)
  end

  test "dashboard lists persisted references and replaces a selected secret after remount", %{conn: conn} do
    {:ok, reference} = SecretStore.put("linear-api-token", "old-value", actor: "bootstrap-admin")
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")

    assert {:ok, view, html} = live(conn, "/configuration/secrets")

    assert html =~ "Existing secrets"
    assert html =~ reference.id
    assert html =~ "linear-api-token"
    refute html =~ "old-value"

    html =
      view
      |> form("#secret-form",
        secret: %{"reference_id" => reference.id, "name" => "linear-api-token", "value" => "new-value"}
      )
      |> render_submit()

    assert html =~ "Secret reference"
    refute html =~ "new-value"
    assert {:ok, "new-value"} = SecretStore.fetch(reference)

    remount_conn = build_conn() |> put_req_header("authorization", "Bearer #{@bootstrap_token}")
    assert {:ok, _view, remount_html} = live(remount_conn, "/configuration/secrets")
    assert remount_html =~ reference.id
    assert remount_html =~ "linear-api-token"
    refute remount_html =~ "old-value"
    refute remount_html =~ "new-value"
  end

  test "dashboard binds an opaque reference to a draft provider without exposing plaintext", %{conn: conn} do
    {:ok, reference} = SecretStore.put("linear-api-token", "plain-value", actor: "bootstrap-admin")
    {:ok, draft} = Configuration.create_draft(valid_document(), actor: "bootstrap-admin")
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")

    assert {:ok, view, _html} = live(conn, "/configuration/secrets")

    html =
      view
      |> form("#provider-credential-form",
        binding: %{
          "revision_id" => draft.id,
          "provider_id" => "linear",
          "provider_name" => "Linear",
          "secret_id" => reference.id
        }
      )
      |> render_submit()

    assert html =~ "Provider credential bound"
    refute html =~ "plain-value"

    revision = Repo.get!(Revision, draft.id)

    assert revision.document["providers"] == [
             %{
               "id" => "linear",
               "name" => "Linear",
               "credential_ref" => reference.id
             }
           ]

    refute Jason.encode!(revision.document) =~ "plain-value"
    refute Jason.encode!(revision.document) =~ "linear-api-token"
  end

  test "dashboard reports malformed provider binding without exposing plaintext", %{conn: conn} do
    {:ok, reference} = SecretStore.put("linear-api-token", "plain-value", actor: "bootstrap-admin")
    conn = put_req_header(conn, "authorization", "Bearer #{@bootstrap_token}")

    assert {:ok, view, _html} = live(conn, "/configuration/secrets")

    html =
      render_submit(view, "bind_provider", %{
        "binding" => %{
          "revision_id" => Ecto.UUID.generate(),
          "provider_id" => "linear",
          "provider_name" => "Linear",
          "secret_id" => reference.id
        }
      })

    assert html =~ "Provider credential could not be bound"
    refute html =~ "plain-value"

    html =
      render_submit(view, "bind_provider", %{
        "binding" => %{
          "revision_id" => Ecto.UUID.generate(),
          "provider_id" => "linear",
          "provider_name" => "Linear",
          "secret_id" => Ecto.UUID.generate()
        }
      })

    assert html =~ "Provider credential could not be bound"

    html = render_submit(view, "bind_provider", %{})
    assert html =~ "Provider credential could not be bound"
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
