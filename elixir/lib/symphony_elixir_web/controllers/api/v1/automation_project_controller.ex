defmodule SymphonyElixirWeb.Api.V1.AutomationProjectController do
  @moduledoc """
  Minimal versioned REST resource for bootstrapping one Automation Project.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.{Document, Revision, TaskPin}

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"project" => project}) do
    actor = conn.assigns.current_principal.id
    {:ok, revision} = Configuration.create_draft(Document.for_project(project), actor: actor)

    conn
    |> put_status(:created)
    |> json(%{data: serialize(revision)})
  end

  def create(conn, _params) do
    validation_error(conn, %{project: ["is required"]})
  end

  @spec templates(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def templates(conn, _params) do
    json(conn, %{data: Configuration.templates()})
  end

  @spec import_workflow(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def import_workflow(conn, %{"workflow" => workflow}) do
    actor = conn.assigns.current_principal.id

    case Configuration.import(Map.take(workflow, ["content"]), actor: actor) do
      {:ok, revision} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize(revision)})

      {:error, reason} ->
        validation_error(conn, reason)
    end
  end

  def import_workflow(conn, _params) do
    validation_error(conn, %{workflow: ["is required"]})
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "document" => document}) do
    actor = conn.assigns.current_principal.id

    case Configuration.update_draft(id, document, actor: actor) do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> validation_error(conn, reason)
    end
  end

  def update(conn, _params) do
    validation_error(conn, %{document: ["is required"]})
  end

  @spec validate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validate(conn, %{"id" => id}) do
    actor = conn.assigns.current_principal.id

    case Configuration.validate(id, actor: actor, probes: configured_probes()) do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> validation_error(conn, reason)
    end
  end

  @spec activate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def activate(conn, %{"id" => id}) do
    actor = conn.assigns.current_principal.id

    case Configuration.activate(id, actor: actor, probes: configured_probes()) do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> validation_error(conn, reason)
    end
  end

  @spec rollback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rollback(conn, %{"id" => id}) do
    actor = conn.assigns.current_principal.id

    case Configuration.rollback(id, actor: actor, probes: configured_probes()) do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> validation_error(conn, reason)
    end
  end

  @spec bind_provider_credential(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def bind_provider_credential(
        conn,
        %{"id" => id, "provider_id" => provider_id, "credential_ref" => credential_ref} = params
      ) do
    actor = conn.assigns.current_principal.id
    provider_params = Map.get(params, "provider", %{})
    provider = %{"id" => provider_id, "name" => Map.get(provider_params, "name", provider_id)}

    case Configuration.bind_provider_credential(id, provider, credential_ref, actor: actor) do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> validation_error(conn, reason)
    end
  end

  def bind_provider_credential(conn, _params) do
    validation_error(conn, :invalid_provider_credential_binding)
  end

  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, %{"id" => id}) do
    case Configuration.export(id, redacted: true) do
      {:ok, export} -> json(conn, %{data: export})
      {:error, :not_found} -> not_found(conn)
    end
  end

  @spec active(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def active(conn, _params) do
    case Configuration.active() do
      {:ok, revision} -> json(conn, %{data: serialize(revision)})
      {:error, :not_found} -> not_found(conn)
    end
  end

  @spec pin_task(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pin_task(conn, %{"task_id" => task_id}) do
    actor = conn.assigns.current_principal.id

    case Configuration.pin_for_task(task_id, actor: actor) do
      {:ok, pin} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_pin(pin)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, reason} ->
        validation_error(conn, reason)
    end
  end

  def pin_task(conn, _params) do
    validation_error(conn, %{task_id: ["is required"]})
  end

  @spec pinned_task(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pinned_task(conn, %{"task_id" => task_id}) do
    json(conn, %{data: serialize_pin(Configuration.pinned_for_task!(task_id))})
  rescue
    Ecto.NoResultsError -> not_found(conn)
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

  defp serialize_pin(%TaskPin{} = pin) do
    %{
      id: pin.id,
      task_id: pin.task_id,
      revision_id: pin.revision_id,
      content_hash: pin.content_hash,
      document: pin.document
    }
  end

  defp validation_error(conn, {:invalid_configuration, errors}) when is_list(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_configuration",
        message: "Configuration validation failed",
        details: Enum.map(errors, &validation_detail/1)
      }
    })
  end

  defp validation_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{code: "invalid_configuration", message: "Configuration validation failed"}
    })
  end

  defp validation_detail(%{path: path, message: message}) do
    %{path: path, message: message}
  end

  defp configured_probes do
    case Application.get_env(:symphony_elixir, :configuration_probes, []) do
      probes when is_list(probes) -> probes
      _other -> []
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Configuration revision not found"}})
  end
end
