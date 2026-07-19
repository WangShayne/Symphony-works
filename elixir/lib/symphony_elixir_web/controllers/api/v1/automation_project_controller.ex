defmodule SymphonyElixirWeb.Api.V1.AutomationProjectController do
  @moduledoc """
  Minimal versioned REST resource for bootstrapping one Automation Project.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.{Document, Revision}

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"project" => project}) do
    actor = conn.assigns.current_principal.id

    case Configuration.create_draft(Document.for_project(project), actor: actor) do
      {:ok, revision} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize(revision)})

      {:error, changeset} ->
        validation_error(conn, changeset)
    end
  end

  def create(conn, _params) do
    validation_error(conn, %{project: ["is required"]})
  end

  @spec validate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validate(conn, %{"id" => id}) do
    actor = conn.assigns.current_principal.id

    case Configuration.validate(id, actor: actor) do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> validation_error(conn, reason)
    end
  end

  @spec activate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def activate(conn, %{"id" => id}) do
    actor = conn.assigns.current_principal.id

    case Configuration.activate(id, actor: actor) do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> validation_error(conn, reason)
    end
  end

  @spec active(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def active(conn, _params) do
    case Configuration.active() do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp serialize(%Revision{} = revision) do
    %{
      id: revision.id,
      status: Atom.to_string(revision.status),
      schema_version: revision.schema_version,
      content_hash: revision.content_hash,
      document: revision.document,
      validation_evidence: revision.validation_evidence,
      validated_at: revision.validated_at,
      activated_at: revision.activated_at
    }
  end

  defp validation_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{code: "invalid_configuration", message: "Configuration validation failed"}
    })
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Configuration revision not found"}})
  end
end
