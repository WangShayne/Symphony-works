defmodule SymphonyElixirWeb.ConfigurationLive do
  @moduledoc """
  Minimal bootstrap Dashboard for the first persistent Automation Project.
  """

  use Phoenix.LiveView

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document

  @impl true
  def mount(_params, %{"bootstrap_admin" => true}, socket) do
    active =
      case Configuration.active() do
        {:ok, revision} -> revision
        {:error, :not_found} -> nil
      end

    {:ok, assign(socket, revision: nil, active: active, error: nil)}
  end

  @impl true
  def handle_event("create", params, socket) do
    result =
      case params do
        %{"project" => project} when is_map(project) ->
          Configuration.create_draft(Document.for_project(project), actor: "bootstrap-admin")

        _invalid_params ->
          {:error, %{project: ["is required"]}}
      end

    case result do
      {:ok, revision} -> {:noreply, assign(socket, revision: revision, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event("validate", _params, %{assigns: %{revision: revision}} = socket)
      when not is_nil(revision) do
    case Configuration.validate(revision.id, actor: "bootstrap-admin") do
      {:ok, validated} -> {:noreply, assign(socket, revision: validated, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event("activate", _params, %{assigns: %{revision: revision}} = socket)
      when not is_nil(revision) do
    case Configuration.activate(revision.id, actor: "bootstrap-admin") do
      {:ok, active} ->
        {:noreply, assign(socket, revision: active, active: active, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  defp error_message(:not_found), do: "Configuration revision not found"
  defp error_message(_reason), do: "Invalid configuration"

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
          <label>
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

        <p :if={@error} role="alert">{@error}</p>

        <section :if={@revision} id="revision-status">
          <h2>Draft revision</h2>
          <p>Revision {@revision.id}: {@revision.status}</p>
          <button :if={@revision.status == :draft} type="button" phx-click="validate">
            Validate
          </button>
          <p :if={@revision.status in [:validated, :active]}>All required checks passed</p>
          <button :if={@revision.status == :validated} type="button" phx-click="activate">
            Activate
          </button>
        </section>

        <section :if={@active} id="active-revision">
          <h2>Active revision</h2>
          <p>{@active.document["automation_projects"] |> hd() |> Map.fetch!("name")}</p>
          <p>Revision {@active.id}</p>
        </section>
    </section>
    """
  end
end
