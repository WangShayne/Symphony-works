defmodule SymphonyElixir.Configuration.Document do
  @moduledoc """
  Validates the complete JSON-compatible configuration snapshot stored in a revision.

  The first tracer accepts one Automation Project without provider credentials.
  Later configuration slices extend the same document instead of creating parallel stores.
  """

  alias SymphonyElixir.Security.SecretStore

  @list_sections [
    "providers",
    "model_references",
    "task_types",
    "execution_profiles",
    "integrations",
    "tool_groups"
  ]
  @empty_map_sections ["budgets", "acceptance", "network", "retention"]
  @top_level_fields ["schema_version", "automation_projects", "routing"] ++
                      @list_sections ++ @empty_map_sections
  @project_fields [
    "id",
    "name",
    "tracker",
    "repository",
    "tracker_integration_ref",
    "source_control_integration_ref"
  ]
  @tracker_fields ["kind", "scope"]
  @repository_fields ["url", "target_branch"]
  @provider_fields ["id", "name", "runtime_protocol", "endpoint", "credential_ref"]
  @integration_kinds ["tracker", "source_control"]
  @integration_fields ["id", "kind", "provider", "credential_ref", "settings", "active"]
  @legacy_integration_fields ["id", "kind", "settings"]
  @integration_setting_fields [
    "endpoint",
    "api_base_url",
    "project_slug",
    "assignee",
    "owner",
    "repository",
    "project_id",
    "base_branch",
    "scenario",
    "fixture",
    "webhook_secret_ref",
    "bot_actor_id",
    "state_ids"
  ]
  @model_reference_fields [
    "id",
    "provider_id",
    "endpoint",
    "model_id",
    "credential_ref",
    "context_window",
    "capabilities",
    "prices"
  ]
  @routing_fields [
    "model_reference_id",
    "fallback_model_reference_id",
    "execution_fallback_model_reference_id",
    "profile"
  ]
  @routing_profile_fields [
    "id",
    "runtime",
    "readonly",
    "allow_mutation",
    "high_risk_tools",
    "required_capabilities"
  ]
  @execution_profile_fields [
    "id",
    "name",
    "runtime",
    "model_reference_id",
    "instructions",
    "required_capabilities",
    "active"
  ]
  @capability_fields ["structured_output", "tool_use", "context_window"]
  @price_fields ["input", "cached_input", "output"]

  @required_project_paths [
    ["id"],
    ["name"],
    ["tracker", "kind"],
    ["tracker", "scope"],
    ["repository", "url"],
    ["repository", "target_branch"]
  ]

  @type validation_error :: %{path: [String.t()], message: String.t()}

  @spec for_project(map()) :: map()
  def for_project(project) when is_map(project) do
    project =
      project
      |> Map.take(@project_fields)
      |> drop_blank_integration_refs()
      |> sanitize_nested_fields("tracker", @tracker_fields)
      |> sanitize_nested_fields("repository", @repository_fields)

    %{
      "schema_version" => 1,
      "automation_projects" => [project],
      "providers" => [],
      "model_references" => [],
      "task_types" => [],
      "execution_profiles" => [],
      "integrations" => [],
      "tool_groups" => [],
      "routing" => %{},
      "budgets" => %{},
      "acceptance" => %{},
      "network" => %{},
      "retention" => %{}
    }
  end

  @spec ensure_project_integration_refs(map()) :: map()
  def ensure_project_integration_refs(%{"automation_projects" => [project], "integrations" => integrations} = document)
      when is_map(project) and is_list(integrations) do
    project =
      project
      |> put_default_integration_ref("tracker_integration_ref", integrations, "tracker")
      |> put_default_integration_ref("source_control_integration_ref", integrations, "source_control")

    Map.put(document, "automation_projects", [project])
  end

  def ensure_project_integration_refs(document), do: document

  @spec validate(term()) :: {:ok, map()} | {:error, [validation_error()]}
  def validate(document) when is_map(document) do
    errors =
      []
      |> require_schema_version(document)
      |> require_automation_projects(document)
      |> require_list_sections(document, @list_sections)
      |> require_providers(document)
      |> require_model_references(document)
      |> validate_integrations(document)
      |> require_empty_sections(document, @empty_map_sections, %{})
      |> validate_routing(document)
      |> validate_task_types(document)
      |> validate_execution_profiles(document)
      |> validate_model_bindings(document)
      |> reject_unknown_fields(document, @top_level_fields, [])

    case errors do
      [] -> {:ok, document}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_document),
    do: {:error, [%{path: [], message: "configuration must be a JSON object"}]}

  @spec content_hash(map()) :: String.t()
  def content_hash(document) do
    document
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp require_schema_version(errors, %{"schema_version" => 1}), do: errors

  defp require_schema_version(errors, _document) do
    [%{path: ["schema_version"], message: "must equal 1"} | errors]
  end

  defp require_automation_projects(errors, %{"automation_projects" => [project]} = document) do
    validate_project(errors, project, 0, integration_context(document))
  end

  defp require_automation_projects(errors, _document) do
    [%{path: ["automation_projects"], message: "must contain exactly one project"} | errors]
  end

  defp require_providers(errors, %{"providers" => providers}) when is_list(providers) do
    providers
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {provider, index}, acc -> validate_provider(acc, provider, index) end)
  end

  defp require_providers(errors, _document), do: errors

  defp validate_project(errors, project, index, context) when is_map(project) do
    prefix = ["automation_projects", Integer.to_string(index)]

    errors
    |> require_project_paths(project, prefix)
    |> validate_project_integration_refs(project, prefix, context)
    |> reject_unknown_fields(project, @project_fields, prefix)
    |> reject_nested_unknown_fields(project, "tracker", @tracker_fields, prefix)
    |> reject_nested_unknown_fields(project, "repository", @repository_fields, prefix)
  end

  defp validate_project(errors, _project, index, _context) do
    [
      %{
        path: ["automation_projects", Integer.to_string(index)],
        message: "must be an object"
      }
      | errors
    ]
  end

  defp validate_provider(errors, provider, index) when is_map(provider) do
    prefix = ["providers", Integer.to_string(index)]

    errors
    |> require_provider_paths(provider, prefix)
    |> reject_unknown_fields(provider, @provider_fields, prefix)
    |> validate_secret_reference(provider, prefix)
  end

  defp validate_provider(errors, _provider, index) do
    [%{path: ["providers", Integer.to_string(index)], message: "must be an object"} | errors]
  end

  defp require_provider_paths(errors, provider, prefix) do
    Enum.reduce([["id"], ["name"], ["credential_ref"]], errors, fn path, acc ->
      case fetch_path(provider, path) do
        value when is_binary(value) and value != "" -> acc
        _ -> [%{path: prefix ++ path, message: "is required"} | acc]
      end
    end)
  end

  defp require_model_references(errors, %{"model_references" => references})
       when is_list(references) do
    references
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {reference, index}, acc ->
      validate_model_reference(acc, reference, index)
    end)
  end

  defp require_model_references(errors, _document), do: errors

  defp validate_model_reference(errors, reference, index) when is_map(reference) do
    prefix = ["model_references", Integer.to_string(index)]

    errors
    |> require_paths(reference, prefix, [
      ["id"],
      ["provider_id"],
      ["endpoint"],
      ["model_id"],
      ["credential_ref"]
    ])
    |> require_positive_integer(reference, prefix, "context_window")
    |> validate_capabilities(reference, prefix)
    |> validate_prices(reference, prefix)
    |> reject_unknown_fields(reference, @model_reference_fields, prefix)
    |> validate_secret_reference(reference, prefix)
  end

  defp validate_model_reference(errors, _reference, _index), do: errors

  defp validate_secret_reference(errors, %{"credential_ref" => reference}, prefix) when is_binary(reference) do
    if SecretStore.valid_reference_id?(reference) do
      errors
    else
      [%{path: prefix ++ ["credential_ref"], message: "must be an opaque secret reference"} | errors]
    end
  end

  defp validate_secret_reference(errors, _provider, _prefix), do: errors

  defp validate_routing(errors, %{"routing" => routing} = document) when is_map(routing) and map_size(routing) == 0 do
    if runtime_bindings_configured?(document) do
      errors
      |> require_path(routing, ["routing"], ["model_reference_id"])
      |> require_path(routing, ["routing"], ["fallback_model_reference_id"])
      |> require_path(routing, ["routing"], ["execution_fallback_model_reference_id"])
      |> then(&[%{path: ["routing", "profile"], message: "is required"} | &1])
    else
      errors
    end
  end

  defp validate_routing(errors, %{"routing" => routing, "model_references" => references})
       when is_map(routing) and is_list(references) do
    prefix = ["routing"]

    errors
    |> require_paths(routing, prefix, [
      ["model_reference_id"],
      ["fallback_model_reference_id"],
      ["execution_fallback_model_reference_id"]
    ])
    |> validate_routing_profile(routing, prefix)
    |> reject_unknown_fields(routing, @routing_fields, prefix)
  end

  defp validate_routing(errors, %{"routing" => _routing}) do
    [%{path: ["routing"], message: "must be an object"} | errors]
  end

  defp validate_routing(errors, _document), do: [%{path: ["routing"], message: "is required"} | errors]

  defp validate_routing_profile(errors, %{"profile" => profile}, prefix) when is_map(profile) do
    profile_prefix = prefix ++ ["profile"]

    errors
    |> require_paths(profile, profile_prefix, [["id"], ["runtime"]])
    |> require_boolean(profile, profile_prefix, "readonly", true)
    |> require_boolean(profile, profile_prefix, "allow_mutation", false)
    |> require_boolean(profile, profile_prefix, "high_risk_tools", false)
    |> validate_required_capabilities(profile, profile_prefix)
    |> reject_unknown_fields(profile, @routing_profile_fields, profile_prefix)
  end

  defp validate_routing_profile(errors, %{"profile" => _profile}, prefix) do
    [%{path: prefix ++ ["profile"], message: "must be an object"} | errors]
  end

  defp validate_routing_profile(errors, _routing, prefix) do
    [%{path: prefix ++ ["profile"], message: "is required"} | errors]
  end

  defp require_project_paths(errors, project, prefix) do
    Enum.reduce(@required_project_paths, errors, fn path, acc ->
      require_path(acc, project, prefix, path)
    end)
  end

  defp require_paths(errors, value, prefix, paths) do
    Enum.reduce(paths, errors, fn path, acc ->
      require_path(acc, value, prefix, path)
    end)
  end

  defp require_path(errors, value, prefix, path) do
    case fetch_path(value, path) do
      string when is_binary(string) and string != "" -> errors
      _other -> [%{path: prefix ++ path, message: "is required"} | errors]
    end
  end

  defp require_list_sections(errors, document, sections) do
    Enum.reduce(sections, errors, fn section, acc ->
      case Map.fetch(document, section) do
        {:ok, values} when is_list(values) -> require_object_list(acc, section, values)
        {:ok, _value} -> [%{path: [section], message: "must be a list"} | acc]
        :error -> [%{path: [section], message: "is required"} | acc]
      end
    end)
  end

  defp require_object_list(errors, section, values) do
    values
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {value, _index}, acc when is_map(value) ->
        acc

      {_value, index}, acc ->
        [%{path: [section, Integer.to_string(index)], message: "must be an object"} | acc]
    end)
  end

  defp validate_integrations(errors, %{"integrations" => integrations}) when is_list(integrations) do
    integrations
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {%{"kind" => kind} = integration, index}, acc when kind in @integration_kinds ->
        validate_integration(acc, integration, index)

      {%{"kind" => kind} = integration, index}, acc when kind in ["workspace", "codex"] ->
        prefix = ["integrations", Integer.to_string(index)]

        acc
        |> require_paths(integration, prefix, [["id"], ["kind"]])
        |> require_settings_object(Map.get(integration, "settings"), prefix)
        |> reject_unknown_fields(integration, @legacy_integration_fields, prefix)

      {integration, index}, acc when is_map(integration) ->
        prefix = ["integrations", Integer.to_string(index)]

        acc
        |> require_paths(integration, prefix, [["id"], ["kind"]])
        |> validate_integration_kind(Map.get(integration, "kind"), prefix)

      {_integration, _index}, acc ->
        acc
    end)
  end

  defp validate_integrations(errors, _document), do: errors

  defp validate_integration(errors, integration, index) do
    prefix = ["integrations", Integer.to_string(index)]
    kind = Map.get(integration, "kind")
    provider = Map.get(integration, "provider")
    settings = Map.get(integration, "settings")

    errors
    |> require_paths(integration, prefix, [["id"], ["kind"], ["provider"]])
    |> require_integration_settings(settings, prefix)
    |> validate_integration_kind(kind, prefix)
    |> validate_integration_provider(kind, provider, prefix)
    |> validate_integration_active(integration, prefix)
    |> validate_integration_credential(integration, provider, prefix)
    |> validate_integration_provider_settings(kind, provider, settings, prefix)
    |> validate_bot_actor_id(kind, provider, settings, prefix)
    |> reject_unknown_fields(integration, @integration_fields, prefix)
  end

  defp validate_integration_active(errors, %{"active" => value}, _prefix) when is_boolean(value) do
    errors
  end

  defp validate_integration_active(errors, %{"active" => _value}, prefix) do
    [%{path: prefix ++ ["active"], message: "must be a boolean"} | errors]
  end

  defp validate_integration_active(errors, _integration, _prefix), do: errors

  defp require_integration_settings(errors, settings, prefix) when is_map(settings) do
    reject_unknown_fields(errors, settings, @integration_setting_fields, prefix ++ ["settings"])
  end

  defp require_integration_settings(errors, _settings, prefix) do
    [%{path: prefix ++ ["settings"], message: "must be an object"} | errors]
  end

  defp require_settings_object(errors, settings, _prefix) when is_map(settings), do: errors

  defp require_settings_object(errors, _settings, prefix) do
    [%{path: prefix ++ ["settings"], message: "must be an object"} | errors]
  end

  defp validate_integration_kind(errors, kind, _prefix) when kind in ["tracker", "source_control"],
    do: errors

  defp validate_integration_kind(errors, kind, prefix) when is_binary(kind) and kind != "" do
    [%{path: prefix ++ ["kind"], message: "is not supported"} | errors]
  end

  defp validate_integration_kind(errors, _kind, _prefix), do: errors

  defp validate_integration_provider(errors, "tracker", provider, _prefix)
       when provider in ["fixture", "linear", "github", "gitlab"],
       do: errors

  defp validate_integration_provider(errors, "source_control", provider, _prefix)
       when provider in ["fixture", "github", "gitlab"],
       do: errors

  defp validate_integration_provider(errors, kind, provider, prefix)
       when kind in ["tracker", "source_control"] and is_binary(provider) and provider != "" do
    [%{path: prefix ++ ["provider"], message: "is not supported for #{kind}"} | errors]
  end

  defp validate_integration_provider(errors, _kind, _provider, _prefix), do: errors

  defp validate_integration_credential(errors, _integration, "fixture", _prefix), do: errors

  defp validate_integration_credential(errors, integration, _provider, prefix) do
    case Map.get(integration, "credential_ref") do
      reference when is_binary(reference) ->
        if SecretStore.valid_reference_id?(reference) do
          errors
        else
          [%{path: prefix ++ ["credential_ref"], message: "must be an opaque secret reference"} | errors]
        end

      _reference ->
        [%{path: prefix ++ ["credential_ref"], message: "is required"} | errors]
    end
  end

  defp validate_integration_provider_settings(errors, "tracker", "linear", settings, prefix) do
    errors
    |> require_setting_paths(settings, prefix, [
      ["project_slug"],
      ["webhook_secret_ref"],
      ["bot_actor_id"]
    ])
    |> validate_webhook_secret_reference(settings, prefix)
    |> validate_linear_state_ids(settings, prefix)
  end

  defp validate_integration_provider_settings(errors, "tracker", "github", settings, prefix) do
    errors
    |> require_setting_paths(settings, prefix, [
      ["owner"],
      ["repository"],
      ["webhook_secret_ref"],
      ["bot_actor_id"]
    ])
    |> validate_webhook_secret_reference(settings, prefix)
  end

  defp validate_integration_provider_settings(errors, "tracker", "gitlab", settings, prefix) do
    errors
    |> require_setting_paths(settings, prefix, [
      ["project_id"],
      ["webhook_secret_ref"],
      ["bot_actor_id"]
    ])
    |> validate_webhook_secret_reference(settings, prefix)
  end

  defp validate_integration_provider_settings(errors, "source_control", "fixture", settings, prefix) do
    require_setting_paths(errors, settings, prefix, [["repository"], ["base_branch"]])
  end

  defp validate_integration_provider_settings(errors, "source_control", provider, settings, prefix)
       when provider in ["github", "gitlab"] do
    require_setting_paths(errors, settings, prefix, [["repository"], ["base_branch"], ["bot_actor_id"]])
  end

  defp validate_integration_provider_settings(errors, _kind, _provider, _settings, _prefix), do: errors

  defp validate_bot_actor_id(errors, "source_control", provider, settings, prefix)
       when provider in ["github", "gitlab"] and is_map(settings) do
    case Map.get(settings, "bot_actor_id") do
      nil ->
        errors

      value when is_binary(value) ->
        if Regex.match?(~r/\A[1-9][0-9]*\z/, value) do
          errors
        else
          [%{path: prefix ++ ["settings", "bot_actor_id"], message: "must be a canonical positive decimal actor id"} | errors]
        end

      _invalid ->
        [%{path: prefix ++ ["settings", "bot_actor_id"], message: "must be a canonical positive decimal actor id"} | errors]
    end
  end

  defp validate_bot_actor_id(errors, _kind, _provider, _settings, _prefix), do: errors

  defp require_setting_paths(errors, settings, prefix, paths) when is_map(settings) do
    require_paths(errors, settings, prefix ++ ["settings"], paths)
  end

  defp require_setting_paths(errors, _settings, _prefix, _paths), do: errors

  defp validate_webhook_secret_reference(errors, settings, prefix) when is_map(settings) do
    case Map.get(settings, "webhook_secret_ref") do
      reference when is_binary(reference) ->
        if SecretStore.valid_reference_id?(reference) do
          errors
        else
          [
            %{
              path: prefix ++ ["settings", "webhook_secret_ref"],
              message: "must be an opaque secret reference"
            }
            | errors
          ]
        end

      _reference ->
        errors
    end
  end

  defp validate_webhook_secret_reference(errors, _settings, _prefix), do: errors

  defp validate_linear_state_ids(errors, settings, prefix) when is_map(settings) do
    case Map.get(settings, "state_ids") do
      state_ids when is_map(state_ids) and map_size(state_ids) > 0 ->
        Enum.reduce(state_ids, errors, &validate_linear_state_id(&1, &2, prefix))

      state_ids when is_map(state_ids) ->
        [%{path: prefix ++ ["settings", "state_ids"], message: "must contain at least one state"} | errors]

      nil ->
        [%{path: prefix ++ ["settings", "state_ids"], message: "is required"} | errors]

      _state_ids ->
        [%{path: prefix ++ ["settings", "state_ids"], message: "must be an object"} | errors]
    end
  end

  defp validate_linear_state_ids(errors, _settings, _prefix), do: errors

  defp validate_linear_state_id({state, state_id}, errors, prefix) do
    if nonempty_string?(state) and nonempty_string?(state_id) do
      errors
    else
      [
        %{
          path: prefix ++ ["settings", "state_ids", to_string(state)],
          message: "must map a non-empty state name to a non-empty ID"
        }
        | errors
      ]
    end
  end

  defp validate_project_integration_refs(errors, project, prefix, context) do
    errors
    |> validate_project_integration_ref(project, prefix, context, %{
      field: "tracker_integration_ref",
      kind: "tracker",
      label: "Tracker"
    })
    |> validate_project_integration_ref(project, prefix, context, %{
      field: "source_control_integration_ref",
      kind: "source_control",
      label: "Source Control"
    })
  end

  defp validate_project_integration_ref(errors, project, prefix, context, opts) do
    field = opts.field
    kind = opts.kind
    label = opts.label
    integrations_for_kind = Map.get(context.by_kind, kind, [])

    case Map.fetch(project, field) do
      {:ok, ref} when is_binary(ref) and ref != "" ->
        validate_bound_integration_ref(errors, ref, prefix ++ [field], context.by_id, kind, label)

      {:ok, _ref} ->
        [%{path: prefix ++ [field], message: "is required"} | errors]

      :error when integrations_for_kind == [] ->
        errors

      :error ->
        [%{path: prefix ++ [field], message: "is required"} | errors]
    end
  end

  defp validate_bound_integration_ref(errors, ref, path, integrations_by_id, kind, label) do
    case Map.fetch(integrations_by_id, ref) do
      {:ok, integration} ->
        cond do
          Map.get(integration, "kind") != kind ->
            [%{path: path, message: "must reference a #{label} integration"} | errors]

          integration_active?(integration) ->
            errors

          true ->
            [%{path: path, message: "must reference an active #{label} integration"} | errors]
        end

      :error ->
        [%{path: path, message: "must reference an existing #{label} integration"} | errors]
    end
  end

  defp integration_context(%{"integrations" => integrations}) when is_list(integrations) do
    integration_maps = Enum.filter(integrations, &is_map/1)

    %{
      by_id: Map.new(integration_maps, &{Map.get(&1, "id"), &1}),
      by_kind: Enum.group_by(integration_maps, &Map.get(&1, "kind"))
    }
  end

  defp integration_context(_document), do: %{by_id: %{}, by_kind: %{}}

  defp integration_active?(%{"active" => false}), do: false
  defp integration_active?(_integration), do: true

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_task_types(errors, %{"task_types" => task_types}) when is_list(task_types) do
    Enum.reduce(Enum.with_index(task_types), errors, fn
      {task_type, index}, acc when is_map(task_type) ->
        require_paths(acc, task_type, ["task_types", Integer.to_string(index)], [
          ["id"],
          ["name"],
          ["profile_id"]
        ])

      {_task_type, _index}, acc ->
        acc
    end)
  end

  defp validate_task_types(errors, _document), do: errors

  defp validate_execution_profiles(errors, %{"execution_profiles" => profiles})
       when is_list(profiles) do
    Enum.reduce(Enum.with_index(profiles), errors, fn
      {profile, index}, acc when is_map(profile) ->
        prefix = ["execution_profiles", Integer.to_string(index)]

        acc
        |> require_paths(profile, prefix, [
          ["id"],
          ["name"],
          ["runtime"],
          ["instructions"]
        ])
        |> require_active_model_reference(profile, prefix)
        |> validate_required_capabilities(profile, prefix)
        |> reject_unknown_fields(profile, @execution_profile_fields, prefix)

      {_profile, _index}, acc ->
        acc
    end)
  end

  defp validate_execution_profiles(errors, _document), do: errors

  defp runtime_bindings_configured?(document) do
    Map.get(document, "model_references", []) != [] or
      Enum.any?(Map.get(document, "execution_profiles", []), fn
        %{"active" => false} -> false
        profile when is_map(profile) -> true
        _profile -> false
      end)
  end

  defp require_active_model_reference(errors, %{"active" => false}, _prefix), do: errors

  defp require_active_model_reference(errors, profile, prefix) do
    require_path(errors, profile, prefix, ["model_reference_id"])
  end

  defp validate_model_bindings(errors, document) do
    references = model_reference_index(document)
    providers = provider_index(document)

    errors
    |> validate_provider_protocols(document)
    |> validate_model_provider_references(document, providers)
    |> validate_routing_model_bindings(document, references)
    |> validate_execution_model_bindings(document, references)
  end

  defp validate_provider_protocols(errors, %{"providers" => providers}) when is_list(providers) do
    Enum.reduce(Enum.with_index(providers), errors, fn
      {provider, index}, acc when is_map(provider) ->
        case Map.get(provider, "runtime_protocol") do
          "codex_app_server" ->
            acc

          value when is_binary(value) ->
            [%{path: ["providers", Integer.to_string(index), "runtime_protocol"], message: "must be codex_app_server"} | acc]

          _value ->
            acc
        end

      {_provider, _index}, acc ->
        acc
    end)
  end

  defp validate_provider_protocols(errors, _document), do: errors

  defp validate_model_provider_references(errors, %{"model_references" => references}, providers)
       when is_list(references) do
    Enum.reduce(Enum.with_index(references), errors, fn
      {reference, index}, acc when is_map(reference) ->
        provider_id = Map.get(reference, "provider_id")

        case Map.fetch(providers, provider_id) do
          {:ok, {provider, provider_index}} ->
            acc
            |> require_path(provider, ["providers", Integer.to_string(provider_index)], ["runtime_protocol"])
            |> require_path(provider, ["providers", Integer.to_string(provider_index)], ["endpoint"])

          :error ->
            [
              %{
                path: ["model_references", Integer.to_string(index), "provider_id"],
                message: "must reference an existing provider"
              }
              | acc
            ]
        end

      {_reference, _index}, acc ->
        acc
    end)
  end

  defp validate_model_provider_references(errors, _document, _providers), do: errors

  defp validate_routing_model_bindings(errors, %{"routing" => routing}, references)
       when is_map(routing) and map_size(routing) > 0 do
    errors
    |> validate_runtime_name(routing, ["routing", "profile"], "profile")
    |> validate_model_reference_id(routing, references, ["routing"], "model_reference_id")
    |> validate_model_reference_id(routing, references, ["routing"], "fallback_model_reference_id")
    |> validate_model_reference_id(routing, references, ["routing"], "execution_fallback_model_reference_id")
    |> validate_binding_capabilities(
      Map.get(routing, "fallback_model_reference_id"),
      routing_required_capabilities(routing),
      references,
      ["routing", "fallback_model_reference_id"]
    )
    |> validate_binding_capabilities(
      Map.get(routing, "model_reference_id"),
      routing_required_capabilities(routing),
      references,
      ["routing", "model_reference_id"]
    )
  end

  defp validate_routing_model_bindings(errors, _document, _references), do: errors

  defp validate_execution_model_bindings(errors, %{"execution_profiles" => profiles} = document, references)
       when is_list(profiles) do
    execution_fallback_model_id = execution_fallback_model_id(document)

    Enum.reduce(Enum.with_index(profiles), errors, fn
      {%{"active" => false}, _index}, acc ->
        acc

      {profile, index}, acc when is_map(profile) ->
        prefix = ["execution_profiles", Integer.to_string(index)]
        model_id = Map.get(profile, "model_reference_id")

        acc
        |> validate_runtime_name(profile, prefix, "runtime")
        |> validate_model_reference_id(profile, references, prefix, "model_reference_id")
        |> validate_binding_capabilities(
          model_id,
          Map.get(profile, "required_capabilities", %{}),
          references,
          prefix ++ ["model_reference_id"]
        )
        |> validate_binding_capabilities(
          execution_fallback_model_id,
          Map.get(profile, "required_capabilities", %{}),
          references,
          prefix ++ ["execution_fallback_model_reference_id"]
        )

      {_profile, _index}, acc ->
        acc
    end)
  end

  defp validate_execution_model_bindings(errors, _document, _references), do: errors

  defp execution_fallback_model_id(%{"routing" => %{"execution_fallback_model_reference_id" => model_id}}),
    do: model_id

  defp execution_fallback_model_id(_document), do: nil

  defp validate_model_reference_id(errors, value, references, prefix, field) do
    case Map.get(value, field) do
      nil ->
        errors

      id when is_binary(id) ->
        if Map.has_key?(references, id) do
          errors
        else
          [%{path: prefix ++ [field], message: "must reference an existing model"} | errors]
        end

      _other ->
        [%{path: prefix ++ [field], message: "must reference an existing model"} | errors]
    end
  end

  defp validate_runtime_name(errors, %{"profile" => %{"runtime" => runtime}}, prefix, _field) do
    validate_runtime_name(errors, %{"runtime" => runtime}, prefix, "runtime")
  end

  defp validate_runtime_name(errors, %{"runtime" => "codex"}, _prefix, _field), do: errors

  defp validate_runtime_name(errors, %{"runtime" => runtime}, prefix, field) when is_binary(runtime) do
    [%{path: prefix ++ [field], message: "must be compatible with codex_app_server"} | errors]
  end

  defp validate_runtime_name(errors, _value, _prefix, _field), do: errors

  defp validate_binding_capabilities(errors, model_id, required, references, path)
       when is_binary(model_id) and is_map(required) do
    case Map.fetch(references, model_id) do
      {:ok, model} -> enforce_capability_ceiling(errors, Map.get(model, "capabilities", %{}), required, path)
      :error -> errors
    end
  end

  defp validate_binding_capabilities(errors, _model_id, _required, _references, _path), do: errors

  defp routing_required_capabilities(%{"profile" => %{"required_capabilities" => capabilities}})
       when is_map(capabilities),
       do: capabilities

  defp routing_required_capabilities(_routing), do: %{}

  defp enforce_capability_ceiling(errors, capabilities, required, path) do
    capabilities = if is_map(capabilities), do: capabilities, else: %{}

    errors
    |> enforce_boolean_capability(capabilities, required, path, "structured_output")
    |> enforce_boolean_capability(capabilities, required, path, "tool_use")
    |> enforce_context_window(capabilities, required, path)
  end

  defp enforce_boolean_capability(errors, capabilities, required, path, capability) do
    if Map.get(required, capability) == true and Map.get(capabilities, capability) != true do
      [%{path: path, message: "must reference a model with #{capability} capability"} | errors]
    else
      errors
    end
  end

  defp enforce_context_window(errors, capabilities, required, path) do
    required_window = Map.get(required, "context_window")
    available_window = Map.get(capabilities, "context_window")

    if is_integer(required_window) and is_integer(available_window) and available_window < required_window do
      [%{path: path, message: "must reference a model with sufficient context_window capability"} | errors]
    else
      errors
    end
  end

  defp validate_capabilities(errors, %{"capabilities" => capabilities}, prefix)
       when is_map(capabilities) do
    errors
    |> require_boolean(capabilities, prefix ++ ["capabilities"], "structured_output", nil)
    |> require_boolean(capabilities, prefix ++ ["capabilities"], "tool_use", nil)
    |> require_positive_integer(capabilities, prefix ++ ["capabilities"], "context_window")
    |> reject_unknown_fields(capabilities, @capability_fields, prefix ++ ["capabilities"])
  end

  defp validate_capabilities(errors, _value, prefix) do
    [%{path: prefix ++ ["capabilities"], message: "is required"} | errors]
  end

  defp validate_required_capabilities(errors, %{"required_capabilities" => capabilities}, prefix)
       when is_map(capabilities) do
    errors
    |> validate_optional_boolean(capabilities, prefix ++ ["required_capabilities"], "structured_output")
    |> validate_optional_boolean(capabilities, prefix ++ ["required_capabilities"], "tool_use")
    |> validate_optional_positive_integer(capabilities, prefix ++ ["required_capabilities"], "context_window")
    |> reject_unknown_fields(capabilities, @capability_fields, prefix ++ ["required_capabilities"])
  end

  defp validate_required_capabilities(errors, _value, _prefix), do: errors

  defp validate_prices(errors, %{"prices" => prices}, prefix) when is_map(prices) do
    errors
    |> require_price(prices, prefix, "input")
    |> require_price(prices, prefix, "cached_input")
    |> require_price(prices, prefix, "output")
    |> reject_unknown_fields(prices, @price_fields, prefix ++ ["prices"])
  end

  defp validate_prices(errors, _value, prefix), do: [%{path: prefix ++ ["prices"], message: "is required"} | errors]

  defp require_price(errors, prices, prefix, field) do
    case Map.get(prices, field) do
      value when is_number(value) and value >= 0 -> errors
      _value -> [%{path: prefix ++ ["prices", field], message: "must be a non-negative number"} | errors]
    end
  end

  defp require_boolean(errors, value, prefix, field, expected) do
    case Map.get(value, field) do
      ^expected when is_boolean(expected) ->
        errors

      actual when is_boolean(actual) and is_nil(expected) ->
        errors

      _actual when is_nil(expected) ->
        [%{path: prefix ++ [field], message: "must be a boolean"} | errors]

      _actual ->
        [%{path: prefix ++ [field], message: "must be #{expected}"} | errors]
    end
  end

  defp validate_optional_boolean(errors, value, prefix, field) do
    case Map.get(value, field) do
      nil -> errors
      actual when is_boolean(actual) -> errors
      _actual -> [%{path: prefix ++ [field], message: "must be a boolean"} | errors]
    end
  end

  defp require_positive_integer(errors, value, prefix, field) do
    case Map.get(value, field) do
      actual when is_integer(actual) and actual > 0 -> errors
      _actual -> [%{path: prefix ++ [field], message: "must be a positive integer"} | errors]
    end
  end

  defp validate_optional_positive_integer(errors, value, prefix, field) do
    case Map.get(value, field) do
      nil -> errors
      actual when is_integer(actual) and actual > 0 -> errors
      _actual -> [%{path: prefix ++ [field], message: "must be a positive integer"} | errors]
    end
  end

  defp model_reference_index(%{"model_references" => references}) when is_list(references) do
    references
    |> Enum.filter(&is_map/1)
    |> Map.new(fn reference -> {Map.get(reference, "id"), reference} end)
  end

  defp model_reference_index(_document), do: %{}

  defp provider_index(%{"providers" => providers}) when is_list(providers) do
    providers
    |> Enum.with_index()
    |> Enum.filter(fn {provider, _index} -> is_map(provider) end)
    |> Map.new(fn {provider, index} -> {Map.get(provider, "id"), {provider, index}} end)
  end

  defp provider_index(_document), do: %{}

  defp require_empty_sections(errors, document, sections, empty_value) do
    Enum.reduce(sections, errors, fn section, acc ->
      case Map.fetch(document, section) do
        {:ok, ^empty_value} -> acc
        {:ok, _value} -> [%{path: [section], message: "must be empty during bootstrap"} | acc]
        :error -> [%{path: [section], message: "is required"} | acc]
      end
    end)
  end

  defp reject_nested_unknown_fields(errors, project, section, allowed_fields, prefix) do
    case Map.get(project, section) do
      value when is_map(value) -> reject_unknown_fields(errors, value, allowed_fields, prefix ++ [section])
      _other -> errors
    end
  end

  defp reject_unknown_fields(errors, value, allowed_fields, prefix) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_fields))
    |> Enum.reduce(errors, fn field, acc ->
      [%{path: prefix ++ [path_key(field)], message: "is not supported"} | acc]
    end)
  end

  defp fetch_path(value, []), do: value

  defp fetch_path(value, [field | rest]) when is_map(value) do
    value
    |> Map.get(field)
    |> fetch_path(rest)
  end

  defp fetch_path(_value, _path), do: nil

  defp sanitize_nested_fields(project, section, allowed_fields) do
    case Map.fetch(project, section) do
      {:ok, value} when is_map(value) -> Map.put(project, section, Map.take(value, allowed_fields))
      _other -> project
    end
  end

  defp drop_blank_integration_refs(project) do
    project
    |> drop_blank_field("tracker_integration_ref")
    |> drop_blank_field("source_control_integration_ref")
  end

  defp drop_blank_field(project, field) do
    case Map.get(project, field) do
      value when value in [nil, ""] -> Map.delete(project, field)
      _value -> project
    end
  end

  defp put_default_integration_ref(project, field, integrations, kind) do
    case Map.get(project, field) do
      value when is_binary(value) and value != "" ->
        project

      _value ->
        case active_integration_ids(integrations, kind) do
          [id] -> Map.put(project, field, id)
          _ids -> Map.delete(project, field)
        end
    end
  end

  defp active_integration_ids(integrations, kind) do
    integrations
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "kind") == kind and integration_active?(&1)))
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.filter(&nonempty_string?/1)
  end

  defp path_key(field) when is_binary(field), do: field
  defp path_key(field), do: inspect(field)
end
