defmodule SymphonyElixirWeb.ConfigurationLive do
  @moduledoc """
  Minimal bootstrap Dashboard for the first persistent Automation Project.
  """

  use Phoenix.LiveView

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Identity
  alias SymphonyElixir.Identity.Authorization

  @health_atom_keys %{
    "repository" => :repository,
    "base_branch" => :base_branch,
    "evidence" => :evidence,
    "scope" => :scope,
    "transport" => :transport
  }

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
      default_capability_context_window: 64_000,
      default_structured_output: true,
      default_tool_use: true,
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
      [sanitized_project] = Document.for_project(project)["automation_projects"]
      document = Map.put(revision.document, "automation_projects", [sanitized_project])

      case Configuration.update_draft(revision.id, document, actor: actor) do
        {:ok, revision} -> {:noreply, assign(socket, revision: revision, exported: nil, error: nil, actor: actor)}
        {:error, reason} -> {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("bind_runtime_model", %{"runtime_model" => params}, %{assigns: %{revision: revision}} = socket)
      when not is_nil(revision) do
    authorize_event(socket, :write_configuration, fn actor ->
      document = runtime_model_document(revision.document, params)

      case Configuration.update_draft(revision.id, document, actor: actor) do
        {:ok, revision} ->
          {:noreply, assign(socket, revision: revision, exported: nil, error: nil, actor: actor)}

        {:error, reason} ->
          {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event(
        "configure_integration",
        %{"integration" => params},
        %{assigns: %{revision: revision}} = socket
      )
      when not is_nil(revision) do
    authorize_event(socket, :write_configuration, fn actor ->
      with {:ok, integration} <- normalize_integration(params),
           document <- upsert_integration(revision.document, integration),
           {:ok, revision} <- Configuration.update_draft(revision.id, document, actor: actor) do
        {:noreply, assign(socket, revision: revision, exported: nil, error: nil, actor: actor)}
      else
        {:error, reason} ->
          {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event(
        "create_task_type",
        %{"task_type" => params},
        %{assigns: %{revision: revision}} = socket
      )
      when not is_nil(revision) do
    authorize_event(socket, :write_configuration, fn actor ->
      document = task_type_document(revision.document, params)

      case Configuration.update_draft(revision.id, document, actor: actor) do
        {:ok, revision} ->
          {:noreply, assign(socket, revision: revision, exported: nil, error: nil, actor: actor)}

        {:error, reason} ->
          {:noreply, assign(socket, error: error_message(reason), actor: actor)}
      end
    end)
  end

  def handle_event("create_task_type", _params, socket) do
    authorize_event(socket, :write_configuration, fn actor ->
      {:noreply, assign(socket, error: "Invalid configuration", actor: actor)}
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

  defp error_message({:probe_failed, :integration, %{"integration" => %{"id" => id, "provider" => provider, "reason" => reason}}}) do
    "Integration health check failed / 集成健康检查失败: #{id} · #{provider} · #{reason}"
  end

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

  defp normalize_integration(params) when is_map(params) do
    id = params |> Map.get("id", "") |> String.trim()
    kind = params |> Map.get("kind", "") |> String.trim()
    provider = params |> Map.get("provider", "") |> String.trim()

    if id == "" or kind == "" or provider == "" do
      {:error, :invalid_integration}
    else
      settings =
        params
        |> Map.take([
          "endpoint",
          "api_base_url",
          "project_slug",
          "assignee",
          "owner",
          "repository",
          "project_id",
          "base_branch",
          "scenario",
          "webhook_secret_ref",
          "bot_actor_id"
        ])
        |> compact_strings()
        |> canonicalize_integration_settings(kind)
        |> maybe_put_state_ids(Map.get(params, "state_ids"))

      integration = %{
        "id" => id,
        "kind" => kind,
        "provider" => provider,
        "settings" => settings
      }

      {:ok, maybe_put_credential_ref(integration, Map.get(params, "credential_ref"))}
    end
  end

  defp normalize_integration(_params), do: {:error, :invalid_integration}

  defp canonicalize_integration_settings(settings, "source_control") do
    case Map.pop(settings, "endpoint") do
      {nil, settings} ->
        settings

      {endpoint, settings} ->
        Map.put_new(settings, "api_base_url", endpoint)
    end
  end

  defp canonicalize_integration_settings(settings, _kind), do: settings

  defp compact_strings(values) do
    Map.new(values, fn {key, value} -> {key, if(is_binary(value), do: String.trim(value), else: value)} end)
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp maybe_put_state_ids(settings, state_ids) when is_map(state_ids) do
    case compact_strings(state_ids) do
      state_ids when map_size(state_ids) > 0 -> Map.put(settings, "state_ids", state_ids)
      _state_ids -> settings
    end
  end

  defp maybe_put_state_ids(settings, _state_ids), do: settings

  defp maybe_put_credential_ref(integration, reference) when is_binary(reference) do
    case String.trim(reference) do
      "" -> integration
      reference -> Map.put(integration, "credential_ref", reference)
    end
  end

  defp maybe_put_credential_ref(integration, _reference), do: integration

  defp upsert_integration(document, integration) do
    integrations =
      document
      |> Map.get("integrations", [])
      |> Enum.reject(&(Map.get(&1, "id") == integration["id"]))
      |> Kernel.++([integration])

    Map.put(document, "integrations", integrations)
  end

  defp task_type_document(document, params) do
    id = field(params, "id", "general")

    task_type = %{
      "id" => id,
      "name" => field(params, "name", "General"),
      "profile_id" => field(params, "profile_id", "general-profile")
    }

    task_types =
      document
      |> Map.get("task_types", [])
      |> Enum.reject(&(Map.get(&1, "id") == id))
      |> Kernel.++([task_type])

    Map.put(document, "task_types", task_types)
  end

  defp project_value(revision, field) do
    revision.document
    |> Map.fetch!("automation_projects")
    |> hd()
    |> Map.get(field, "")
  end

  defp integration_health(nil), do: nil

  defp integration_health(revision) do
    revision.validation_evidence
    |> case do
      %{"probes" => probes} when is_list(probes) ->
        Enum.find(probes, &(is_map(&1) and Map.get(&1, "probe") == "integrations"))

      _evidence ->
        nil
    end
  end

  defp display_revision(nil, active), do: active
  defp display_revision(revision, _active), do: revision

  defp integration_kind_label("tracker"), do: "Tracker / 任务跟踪"
  defp integration_kind_label("source_control"), do: "Source Control / 源代码托管"
  defp integration_kind_label(kind), do: kind

  defp integration_health_summary(%{"health" => health}) when is_map(health) do
    evidence = health_value(health, "evidence")

    [
      health_value(health, "repository"),
      health_value(health, "base_branch"),
      health_value(evidence, "endpoint"),
      health_value(evidence, "scope"),
      health_value(evidence, "transport")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" · ", &health_display_value/1)
  end

  defp integration_health_summary(_item), do: ""

  defp health_display_value(:deterministic_fixture),
    do: "Deterministic fixture / 确定性夹具"

  defp health_display_value("deterministic_fixture"),
    do: "Deterministic fixture / 确定性夹具"

  defp health_display_value(value), do: to_string(value)

  defp health_value(value, key) when is_map(value) do
    Map.get(value, key) || Map.get(value, Map.get(@health_atom_keys, key))
  end

  defp health_value(_value, _key), do: nil

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
          <label>
            Tracker integration ref
            <input name="project[tracker_integration_ref]" placeholder="tracker-fixture" />
          </label>
          <label>
            Source Control integration ref
            <input name="project[source_control_integration_ref]" placeholder="delivery-fixture" />
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
          <label>
            Tracker integration ref
            <input name="project[tracker_integration_ref]" value={project_value(@revision, "tracker_integration_ref")} />
          </label>
          <label>
            Source Control integration ref
            <input name="project[source_control_integration_ref]" value={project_value(@revision, "source_control_integration_ref")} />
          </label>
          <button type="submit">Update draft</button>
        </form>

        <section :if={display_revision(@revision, @active)} id="integrations-panel" class="integration-panel">
          <div class="integration-heading">
            <div>
              <p class="eyebrow">Provider-neutral boundaries</p>
              <h2>Integrations / 集成</h2>
            </div>
          </div>

          <div class="integration-list" aria-live="polite">
            <article
              :for={integration <- Map.get(display_revision(@revision, @active).document, "integrations", [])}
              id={"integration-#{integration["id"]}"}
              class="integration-card"
            >
              <span class="integration-kind">{integration_kind_label(integration["kind"])}</span>
              <strong>{integration["id"]}</strong>
              <span>{integration["provider"]}</span>
            </article>
            <p
              :if={Map.get(display_revision(@revision, @active).document, "integrations", []) == []}
              class="empty-integrations"
            >
              No integrations configured / 尚未配置集成
            </p>
          </div>
        </section>

        <form
          :if={@revision && @revision.status == :draft}
          id="integration-form"
          phx-submit="configure_integration"
        >
          <div class="form-intro wide-field">
            <h2>Configure integration / 配置集成</h2>
          </div>
          <label>
            Integration ID / 集成 ID
            <input name="integration[id]" placeholder="tracker-main" required />
          </label>
          <label>
            Boundary / 边界
            <select name="integration[kind]" required>
              <option value="tracker">Tracker / 任务跟踪</option>
              <option value="source_control">Source Control / 源代码托管</option>
            </select>
          </label>
          <label>
            Provider / 提供商
            <select name="integration[provider]" required>
              <option value="fixture">Deterministic fixture / 确定性夹具</option>
              <option value="linear">Linear (Tracker only)</option>
              <option value="github">GitHub</option>
              <option value="gitlab">GitLab</option>
            </select>
          </label>
          <label class="wide-field">
            Secret reference UUID / 密钥引用 UUID
            <input
              name="integration[credential_ref]"
              autocomplete="off"
              placeholder="Not required for deterministic fixtures"
            />
          </label>
          <label class="wide-field">
            Webhook secret reference UUID / Webhook 密钥引用 UUID
            <input
              name="integration[webhook_secret_ref]"
              autocomplete="off"
              placeholder="Required for production Tracker adapters"
            />
          </label>
          <label>
            GitHub owner
            <input name="integration[owner]" placeholder="WangShayne" />
          </label>
          <label>
            Repository / 仓库
            <input name="integration[repository]" placeholder="Symphony-works" />
          </label>
          <label>
            Linear project slug
            <input name="integration[project_slug]" placeholder="engineering" />
          </label>
          <label>
            GitLab project ID
            <input name="integration[project_id]" placeholder="group/project" />
          </label>
          <label>
            Base branch / 目标分支
            <input name="integration[base_branch]" placeholder="main" />
          </label>
          <label>
            Endpoint / 端点
            <input name="integration[endpoint]" placeholder="Provider default" />
          </label>
          <label>
            Fixture scenario / 夹具场景
            <input name="integration[scenario]" value="healthy" />
          </label>
          <label>
            Bot actor ID / 机器人身份 ID
            <input name="integration[bot_actor_id]" placeholder="symphony-bot" />
          </label>
          <label>
            Linear assignee
            <input name="integration[assignee]" placeholder="Optional" />
          </label>
          <fieldset class="integration-state-ids wide-field">
            <legend>Linear workflow state IDs / Linear 工作流状态 ID</legend>
            <label>
              Backlog
              <input name="integration[state_ids][backlog]" autocomplete="off" />
            </label>
            <label>
              Unstarted
              <input name="integration[state_ids][unstarted]" autocomplete="off" />
            </label>
            <label>
              Started
              <input name="integration[state_ids][started]" autocomplete="off" />
            </label>
            <label>
              Completed
              <input name="integration[state_ids][completed]" autocomplete="off" />
            </label>
            <label>
              Cancelled
              <input name="integration[state_ids][cancelled]" autocomplete="off" />
            </label>
          </fieldset>
          <button type="submit">Save integration / 保存集成</button>
        </form>

        <form :if={@revision && @revision.status == :draft} id="task-type-form" phx-submit="create_task_type">
          <h2>Task type</h2>
          <label>
            Task type ID
            <input name="task_type[id]" value="general" required />
          </label>
          <label>
            Name
            <input name="task_type[name]" value="General" required />
          </label>
          <label>
            Execution profile ID
            <input name="task_type[profile_id]" value="general-profile" required />
          </label>
          <button type="submit">Save task type</button>
        </form>

        <section
          :if={integration_health(display_revision(@revision, @active))}
          id="integration-health"
          class="integration-health"
        >
          <div class="integration-heading">
            <div>
              <p class="eyebrow">Read-only validation</p>
              <h2>Integration health / 集成健康</h2>
            </div>
            <span class="health-summary">Healthy / 正常</span>
          </div>
          <ul>
            <li :for={item <- integration_health(display_revision(@revision, @active))["integrations"]}>
              <strong>{item["id"]}</strong>
              <span>
                {item["provider"]} · {integration_kind_label(item["kind"])}
                <small>{integration_health_summary(item)}</small>
              </span>
              <span class="health-chip">Healthy / 正常</span>
            </li>
          </ul>
        </section>

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
