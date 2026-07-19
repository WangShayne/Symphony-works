defmodule SymphonyElixirWeb.ConfigurationLive do
  @moduledoc """
  Minimal bootstrap Dashboard for the first persistent Automation Project.
  """

  use Phoenix.LiveView

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Identity
  alias SymphonyElixir.Identity.Authorization

  @runtime_model_roles [
    %{
      key: "routing",
      label: "Routing model",
      reference_field: "routing_model_reference_id",
      default_reference_id: "routing-model",
      default_model_id: "codex-routing-model",
      default_context_window: 128_000,
      default_capability_context_window: 64_000,
      default_structured_output: true,
      default_tool_use: true,
      default_input_price: "0",
      default_cached_input_price: "0",
      default_output_price: "0"
    },
    %{
      key: "routing_fallback",
      label: "Routing fallback model",
      reference_field: "routing_fallback_model_reference_id",
      default_reference_id: "routing-fallback-model",
      default_model_id: "codex-routing-fallback",
      default_context_window: 64_000,
      default_capability_context_window: 32_000,
      default_structured_output: true,
      default_tool_use: false,
      default_input_price: "0",
      default_cached_input_price: "0",
      default_output_price: "0"
    },
    %{
      key: "execution_fallback",
      label: "Execution fallback model",
      reference_field: "execution_fallback_model_reference_id",
      default_reference_id: "execution-fallback-model",
      default_model_id: "codex-execution-fallback",
      default_context_window: 128_000,
      default_capability_context_window: 64_000,
      default_structured_output: true,
      default_tool_use: true,
      default_input_price: "0",
      default_cached_input_price: "0",
      default_output_price: "0"
    },
    %{
      key: "task",
      label: "Task primary model",
      reference_field: "task_model_reference_id",
      default_reference_id: "task-model",
      default_model_id: "codex-task-primary",
      default_context_window: 128_000,
      default_capability_context_window: 96_000,
      default_structured_output: true,
      default_tool_use: true,
      default_input_price: "0",
      default_cached_input_price: "0",
      default_output_price: "0"
    }
  ]

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
       auth_context: auth_context,
       runtime_model_roles: @runtime_model_roles
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

  def handle_event("bind_runtime_model", %{"runtime_model" => params}, %{assigns: %{revision: revision}} = socket)
      when not is_nil(revision) do
    document = runtime_model_document(revision.document, params)

    case Configuration.update_draft(revision.id, document, actor: "bootstrap-admin") do
      {:ok, revision} -> {:noreply, assign(socket, revision: revision, exported: nil, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_message(reason))}
    end
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

  defp runtime_model_document(document, params) do
    provider_id = field(params, "provider_id", "codex-provider")
    endpoint = field(params, "endpoint", "http://127.0.0.1:4010")
    credential_ref = field(params, "credential_ref", "00000000-0000-0000-0000-000000000001")
    profile_id = field(params, "execution_profile_id", "general-profile")
    references = runtime_model_references(params, provider_id, endpoint, credential_ref)
    references_by_role = Map.new(references, fn {role, reference} -> {role.key, reference} end)

    routing_reference = Map.fetch!(references_by_role, "routing")
    routing_fallback_reference = Map.fetch!(references_by_role, "routing_fallback")
    execution_fallback_reference = Map.fetch!(references_by_role, "execution_fallback")
    task_reference = Map.fetch!(references_by_role, "task")

    document
    |> Map.put("providers", [
      %{
        "id" => provider_id,
        "name" => field(params, "provider_name", "Codex Provider"),
        "runtime_protocol" => "codex_app_server",
        "endpoint" => endpoint,
        "credential_ref" => credential_ref
      }
    ])
    |> Map.put("model_references", Enum.map(references, fn {_role, reference} -> reference end))
    |> Map.put("routing", %{
      "model_reference_id" => routing_reference["id"],
      "fallback_model_reference_id" => routing_fallback_reference["id"],
      "execution_fallback_model_reference_id" => execution_fallback_reference["id"],
      "profile" => %{
        "id" => "routing-profile",
        "runtime" => "codex",
        "readonly" => true,
        "allow_mutation" => false,
        "high_risk_tools" => false,
        "required_capabilities" => required_capabilities(routing_reference)
      }
    })
    |> Map.put("execution_profiles", [
      %{
        "id" => profile_id,
        "name" => field(params, "execution_profile_name", "General"),
        "runtime" => "codex",
        "model_reference_id" => task_reference["id"],
        "instructions" => field(params, "instructions", "Implement the accepted task."),
        "required_capabilities" => required_capabilities(task_reference)
      }
    ])
  end

  defp runtime_model_references(params, provider_id, endpoint, credential_ref) do
    roles = Map.get(params, "roles", %{})

    Enum.map(@runtime_model_roles, fn role ->
      role_params = Map.get(roles, role.key, %{})
      {role, runtime_model_reference(params, role_params, role, provider_id, endpoint, credential_ref)}
    end)
  end

  defp runtime_model_reference(params, role_params, role, provider_id, endpoint, credential_ref) do
    reference_id =
      role_params
      |> field("reference_id", field(params, role.reference_field, role.default_reference_id))

    context_window =
      role_params
      |> field("context_window", to_string(role.default_context_window))
      |> parse_positive_integer(role.default_context_window)

    capability_context_window =
      role_params
      |> field("capability_context_window", to_string(role.default_capability_context_window))
      |> parse_positive_integer(role.default_capability_context_window)

    capabilities = %{
      "structured_output" => parse_boolean(Map.get(role_params, "structured_output"), role.default_structured_output),
      "tool_use" => parse_boolean(Map.get(role_params, "tool_use"), role.default_tool_use),
      "context_window" => capability_context_window
    }

    prices = %{
      "input" => parse_non_negative_number(Map.get(role_params, "input_price"), 0),
      "cached_input" => parse_non_negative_number(Map.get(role_params, "cached_input_price"), 0),
      "output" => parse_non_negative_number(Map.get(role_params, "output_price"), 0)
    }

    model_reference(
      reference_id,
      provider_id,
      endpoint,
      field(role_params, "model_id", role.default_model_id),
      credential_ref,
      context_window,
      capabilities,
      prices
    )
  end

  defp required_capabilities(%{"capabilities" => capabilities}) do
    %{
      "structured_output" => capabilities["structured_output"],
      "tool_use" => capabilities["tool_use"],
      "context_window" => min(capabilities["context_window"], 64_000)
    }
  end

  defp model_reference(id, provider_id, endpoint, model_id, credential_ref, context_window, capabilities, prices) do
    %{
      "id" => id,
      "provider_id" => provider_id,
      "endpoint" => endpoint,
      "model_id" => model_id,
      "credential_ref" => credential_ref,
      "context_window" => context_window,
      "capabilities" => capabilities,
      "prices" => prices
    }
  end

  defp field(params, field, default) do
    case Map.get(params, field, default) do
      value when is_binary(value) and value != "" -> value
      _value -> default
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp parse_boolean(value, default) do
    case value |> to_string() |> String.downcase() |> String.trim() do
      truthy when truthy in ["true", "1", "on", "yes"] -> true
      falsy when falsy in ["false", "0", "off", "no"] -> false
      _other -> default
    end
  end

  defp parse_non_negative_number(value, default) do
    value = to_string(value)

    case Integer.parse(value) do
      {integer, ""} when integer >= 0 ->
        integer

      _other ->
        case Float.parse(value) do
          {float, ""} when float >= 0 -> float
          _other -> default
        end
    end
  end

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

        <form :if={@revision && @revision.status == :draft} id="runtime-model-form" phx-submit="bind_runtime_model">
          <h2>Runtime models</h2>
          <label>
            Provider ID
            <input name="runtime_model[provider_id]" value="codex-provider" required />
          </label>
          <label>
            Provider name
            <input name="runtime_model[provider_name]" value="Codex Provider" required />
          </label>
          <label>
            Codex endpoint
            <input name="runtime_model[endpoint]" value="http://127.0.0.1:4010" required />
          </label>
          <label>
            Credential reference
            <input name="runtime_model[credential_ref]" value="00000000-0000-0000-0000-000000000001" required />
          </label>
          <label>
            Execution profile
            <input name="runtime_model[execution_profile_id]" value="general-profile" required />
          </label>
          <fieldset :for={role <- @runtime_model_roles}>
            <legend>{role.label}</legend>
            <label>
              Reference ID
              <input
                name={"runtime_model[roles][#{role.key}][reference_id]"}
                value={role.default_reference_id}
                required
              />
            </label>
            <label>
              Model ID
              <input
                name={"runtime_model[roles][#{role.key}][model_id]"}
                value={role.default_model_id}
                required
              />
            </label>
            <label>
              Context window
              <input
                name={"runtime_model[roles][#{role.key}][context_window]"}
                value={role.default_context_window}
                required
              />
            </label>
            <label>
              Capability context window
              <input
                name={"runtime_model[roles][#{role.key}][capability_context_window]"}
                value={role.default_capability_context_window}
                required
              />
            </label>
            <label>
              Structured output
              <input
                type="hidden"
                name={"runtime_model[roles][#{role.key}][structured_output]"}
                value="false"
              />
              <input
                type="checkbox"
                name={"runtime_model[roles][#{role.key}][structured_output]"}
                value="true"
                checked={role.default_structured_output}
              />
            </label>
            <label>
              Tool use
              <input
                type="hidden"
                name={"runtime_model[roles][#{role.key}][tool_use]"}
                value="false"
              />
              <input
                type="checkbox"
                name={"runtime_model[roles][#{role.key}][tool_use]"}
                value="true"
                checked={role.default_tool_use}
              />
            </label>
            <label>
              Input price
              <input
                name={"runtime_model[roles][#{role.key}][input_price]"}
                value={role.default_input_price}
                required
              />
            </label>
            <label>
              Cached input price
              <input
                name={"runtime_model[roles][#{role.key}][cached_input_price]"}
                value={role.default_cached_input_price}
                required
              />
            </label>
            <label>
              Output price
              <input
                name={"runtime_model[roles][#{role.key}][output_price]"}
                value={role.default_output_price}
                required
              />
            </label>
          </fieldset>
          <button type="submit">Bind runtime models</button>
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
