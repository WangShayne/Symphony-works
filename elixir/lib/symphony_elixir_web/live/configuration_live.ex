defmodule SymphonyElixirWeb.ConfigurationLive do
  @moduledoc """
  Minimal bootstrap Dashboard for the first persistent Automation Project.
  """

  use Phoenix.LiveView

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Identity
  alias SymphonyElixir.Identity.Authorization

  @impl true
  def mount(_params, session, socket) do
    case trusted_admin_actor(session, :write_configuration) do
      {:ok, actor} -> mount_configuration(socket, actor, trusted_admin_context(session))
      {:error, _reason} -> {:ok, redirect(socket, to: "/auth/login")}
    end
  end

  defp mount_configuration(socket, actor, auth_context) do
    active =
      case Configuration.active() do
        {:ok, revision} -> revision
        {:error, :not_found} -> nil
      end

    {:ok,
     assign(socket,
       revision: nil,
       active: active,
       previous_active: nil,
       templates: nil,
       exported: nil,
       error: nil,
       actor: actor,
       auth_context: auth_context
     )}
  end

  @impl true
  def handle_event("create", params, socket) do
    authorize_event(socket, :write_configuration, fn actor ->
      result =
        case params do
          %{"project" => project} when is_map(project) ->
            Configuration.create_draft(Document.for_project(project), actor: actor)

          _invalid_params ->
            {:error, %{project: ["is required"]}}
        end

      case result do
        {:ok, revision} -> {:noreply, assign(socket, revision: revision, exported: nil, error: nil, actor: actor)}
        {:error, reason} -> {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("update_draft", %{"project" => project}, %{assigns: %{revision: revision}} = socket)
      when not is_nil(revision) do
    authorize_event(socket, :write_configuration, fn actor ->
      document = Document.for_project(project)

      case Configuration.update_draft(revision.id, document, actor: actor) do
        {:ok, revision} -> {:noreply, assign(socket, revision: revision, exported: nil, error: nil, actor: actor)}
        {:error, reason} -> {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("templates", _params, socket) do
    authorize_event(socket, :write_configuration, fn actor ->
      {:noreply, assign(socket, templates: Configuration.templates(), error: nil, actor: actor)}
    end)
  end

  def handle_event("import_workflow", %{"workflow" => workflow}, socket) do
    authorize_event(socket, :write_configuration, fn actor ->
      case Configuration.import(Map.take(workflow, ["content"]), actor: actor) do
        {:ok, revision} -> {:noreply, assign(socket, revision: revision, exported: nil, error: nil, actor: actor)}
        {:error, reason} -> {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("import_workflow", _params, socket) do
    authorize_event(socket, :write_configuration, fn actor ->
      {:noreply, assign(socket, error: "Invalid configuration", actor: actor)}
    end)
  end

  def handle_event("validate", _params, %{assigns: %{revision: revision}} = socket)
      when not is_nil(revision) do
    authorize_event(socket, :write_configuration, fn actor ->
      case Configuration.validate(revision.id, actor: actor, probes: configured_probes()) do
        {:ok, validated} -> {:noreply, assign(socket, revision: validated, error: nil, actor: actor)}
        {:error, reason} -> {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("activate", _params, %{assigns: %{revision: revision}} = socket)
      when not is_nil(revision) do
    authorize_event(socket, :write_configuration, fn actor ->
      previous_active = socket.assigns.active

      case Configuration.activate(revision.id, actor: actor, probes: configured_probes()) do
        {:ok, active} ->
          {:noreply,
           assign(socket,
             revision: active,
             active: active,
             previous_active: previous_active,
             exported: nil,
             error: nil,
             actor: actor
           )}

        {:error, reason} ->
          {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("export", _params, %{assigns: %{active: active}} = socket) when not is_nil(active) do
    authorize_event(socket, :write_configuration, fn actor ->
      case Configuration.export(active.id, redacted: true) do
        {:ok, exported} -> {:noreply, assign(socket, exported: Jason.encode!(exported), error: nil, actor: actor)}
        {:error, reason} -> {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("rollback", %{"id" => id}, socket) do
    authorize_event(socket, :write_configuration, fn actor ->
      case Configuration.rollback(id, actor: actor, probes: configured_probes()) do
        {:ok, active} ->
          socket =
            assign(socket,
              revision: active,
              active: active,
              previous_active: nil,
              exported: nil,
              error: nil,
              actor: actor
            )

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  defp error_message(:not_found), do: "Configuration revision not found"
  defp error_message({:invalid_configuration, [error | _]}), do: "Invalid configuration: #{format_error(error)}"
  defp error_message(_reason), do: "Invalid configuration"

  defp format_error(%{path: path, message: message}) do
    Enum.join(path, ".") <> " " <> message
  end

  defp configured_probes do
    case Application.get_env(:symphony_elixir, :configuration_probes, []) do
      probes when is_list(probes) -> probes
      _other -> []
    end
  end

  defp authorize_event(socket, action, fun) when is_function(fun, 1) do
    case trusted_admin_actor(socket.assigns.auth_context, action) do
      {:ok, actor} -> fun.(actor)
      {:error, _reason} -> {:noreply, redirect(socket, to: "/auth/login")}
    end
  end

  defp trusted_admin_actor(%{"bootstrap_admin" => true}, _action) do
    if Identity.bootstrap_retired?(), do: {:error, :unauthorized}, else: {:ok, "bootstrap-admin"}
  end

  defp trusted_admin_actor(%{"principal_id" => principal_id}, action) when is_binary(principal_id) do
    case Identity.get_principal(principal_id) do
      {:ok, principal} ->
        case Authorization.authorize(principal, action) do
          :ok -> {:ok, principal.id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trusted_admin_actor(_session, _action), do: {:error, :unauthorized}

  defp trusted_admin_context(%{"bootstrap_admin" => true}), do: %{"bootstrap_admin" => true}
  defp trusted_admin_context(%{"principal_id" => principal_id}) when is_binary(principal_id), do: %{"principal_id" => principal_id}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="configuration-page">
        <header>
          <p>Bootstrap administration</p>
          <h1>Automation Project</h1>
          <p>Create a database-backed draft, validate it, then atomically activate it.</p>
        </header>

        <form id="project-form" phx-submit="create">
          <label>
            Project ID
            <input name="project[id]" value="symphony" required />
          </label>
          <label>
            Name
            <input name="project[name]" value="Symphony" required />
          </label>
          <label>
            Tracker kind
            <input name="project[tracker][kind]" value="github" required />
          </label>
          <label>
            Tracker scope
            <input
              name="project[tracker][scope]"
              value="WangShayne/Symphony-works"
              required
            />
          </label>
          <label class="wide-field">
            Repository URL
            <input
              name="project[repository][url]"
              value="git@github.com:WangShayne/Symphony-works.git"
              required
            />
          </label>
          <label>
            Target branch
            <input name="project[repository][target_branch]" value="main" required />
          </label>
          <button type="submit">Create draft</button>
        </form>

        <section id="templates">
          <button type="button" phx-click="templates">Use starter templates</button>
          <ul :if={@templates}>
            <li :for={profile <- @templates["execution_profiles"]}>{profile["name"]}</li>
          </ul>
        </section>

        <form id="workflow-import-form" phx-submit="import_workflow">
          <textarea name="workflow[content]"></textarea>
          <button type="submit">Import WORKFLOW.md</button>
        </form>

        <p :if={@error} role="alert">{@error}</p>

        <section :if={@revision} id="revision-status">
          <h2>Draft revision</h2>
          <p>{@revision.document["automation_projects"] |> hd() |> Map.fetch!("name")}</p>
          <p>Revision {@revision.id}: {@revision.status}</p>
          <button :if={@revision.status == :draft} type="button" phx-click="validate">
            Validate
          </button>
          <p :if={@revision.status in [:validated, :active]}>All required checks passed</p>
          <button :if={@revision.status == :validated} type="button" phx-click="activate">
            Activate
          </button>
        </section>

        <form :if={@revision && @revision.status == :draft} id="draft-update-form" phx-submit="update_draft">
          <label>
            Project ID
            <input name="project[id]" value={@revision.document["automation_projects"] |> hd() |> Map.fetch!("id")} required />
          </label>
          <label>
            Name
            <input name="project[name]" value={@revision.document["automation_projects"] |> hd() |> Map.fetch!("name")} required />
          </label>
          <label>
            Tracker kind
            <input name="project[tracker][kind]" value={@revision.document["automation_projects"] |> hd() |> Map.fetch!("tracker") |> Map.fetch!("kind")} required />
          </label>
          <label>
            Tracker scope
            <input name="project[tracker][scope]" value={@revision.document["automation_projects"] |> hd() |> Map.fetch!("tracker") |> Map.fetch!("scope")} required />
          </label>
          <label class="wide-field">
            Repository URL
            <input name="project[repository][url]" value={@revision.document["automation_projects"] |> hd() |> Map.fetch!("repository") |> Map.fetch!("url")} required />
          </label>
          <label>
            Target branch
            <input name="project[repository][target_branch]" value={@revision.document["automation_projects"] |> hd() |> Map.fetch!("repository") |> Map.fetch!("target_branch")} required />
          </label>
          <button type="submit">Update draft</button>
        </form>

        <section :if={@active} id="active-revision">
          <h2>Active revision</h2>
          <p>{@active.document["automation_projects"] |> hd() |> Map.fetch!("name")}</p>
          <p>Revision {@active.id}</p>
          <button type="button" phx-click="export">Export</button>
        </section>

        <section :if={@previous_active} id="rollback">
          <button type="button" phx-click="rollback" phx-value-id={@previous_active.id}>
            Rollback
          </button>
        </section>

        <pre :if={@exported} id="configuration-export">{@exported}</pre>
    </section>
    """
  end
end
