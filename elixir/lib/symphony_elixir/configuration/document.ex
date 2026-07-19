defmodule SymphonyElixir.Configuration.Document do
  @moduledoc """
  Validates the complete JSON-compatible configuration snapshot stored in a revision.

  The first tracer accepts one Automation Project without provider credentials.
  Later configuration slices extend the same document instead of creating parallel stores.
  """

  @list_sections [
    "providers",
    "model_references",
    "task_types",
    "execution_profiles",
    "integrations",
    "tool_groups"
  ]
  @empty_map_sections ["routing", "budgets", "acceptance", "network", "retention"]
  @top_level_fields ["schema_version", "automation_projects"] ++
                      @list_sections ++ @empty_map_sections
  @project_fields ["id", "name", "tracker", "repository"]
  @tracker_fields ["kind", "scope"]
  @repository_fields ["url", "target_branch"]

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

  @spec validate(term()) :: {:ok, map()} | {:error, [validation_error()]}
  def validate(document) when is_map(document) do
    errors =
      []
      |> require_schema_version(document)
      |> require_automation_projects(document)
      |> require_list_sections(document, @list_sections)
      |> require_empty_sections(document, @empty_map_sections, %{})
      |> validate_task_types(document)
      |> validate_execution_profiles(document)
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

  defp require_automation_projects(errors, %{"automation_projects" => [project]}) do
    validate_project(errors, project, 0)
  end

  defp require_automation_projects(errors, _document) do
    [%{path: ["automation_projects"], message: "must contain exactly one project"} | errors]
  end

  defp validate_project(errors, project, index) when is_map(project) do
    prefix = ["automation_projects", Integer.to_string(index)]

    errors
    |> require_project_paths(project, prefix)
    |> reject_unknown_fields(project, @project_fields, prefix)
    |> reject_nested_unknown_fields(project, "tracker", @tracker_fields, prefix)
    |> reject_nested_unknown_fields(project, "repository", @repository_fields, prefix)
  end

  defp validate_project(errors, _project, index) do
    [
      %{
        path: ["automation_projects", Integer.to_string(index)],
        message: "must be an object"
      }
      | errors
    ]
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
        require_paths(acc, profile, ["execution_profiles", Integer.to_string(index)], [
          ["id"],
          ["name"],
          ["runtime"],
          ["instructions"]
        ])

      {_profile, _index}, acc ->
        acc
    end)
  end

  defp validate_execution_profiles(errors, _document), do: errors

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

  defp path_key(field) when is_binary(field), do: field
  defp path_key(field), do: inspect(field)
end
