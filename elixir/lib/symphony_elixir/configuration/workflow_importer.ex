defmodule SymphonyElixir.Configuration.WorkflowImporter do
  @moduledoc """
  Converts an upstream WORKFLOW.md into one database-backed draft document.
  """

  alias SymphonyElixir.Configuration.Document
  alias SymphonyElixir.Workflow

  @spec import(map()) :: {:ok, map()} | {:error, term()}
  def import(%{"content" => content}) when is_binary(content) do
    with {:ok, workflow} <- Workflow.parse(content) do
      {:ok, to_document(workflow)}
    end
  end

  def import(_input), do: {:error, :missing_workflow_source}

  defp to_document(%{config: config, prompt: prompt}) do
    tracker = Map.get(config, "tracker", %{})
    workspace = Map.get(config, "workspace", %{})
    codex = Map.get(config, "codex", %{})

    Document.for_project(%{
      "id" => "imported-workflow",
      "name" => "Imported WORKFLOW.md",
      "tracker" => %{
        "kind" => Map.get(tracker, "kind", "github"),
        "scope" => Map.get(tracker, "scope") || Map.get(tracker, "project_slug", "imported")
      },
      "repository" => %{
        "url" => Map.get(workspace, "repository_url", "imported://WORKFLOW.md"),
        "target_branch" => Map.get(workspace, "target_branch", "main")
      }
    })
    |> Map.put("task_types", [
      %{"id" => "general", "name" => "General", "profile_id" => "general-profile", "active" => false}
    ])
    |> Map.put("execution_profiles", [
      %{
        "id" => "general-profile",
        "name" => "General profile",
        "runtime" => "codex",
        "instructions" => prompt,
        "active" => false
      }
    ])
    |> Map.put("integrations", integrations(tracker, workspace, codex))
  end

  defp integrations(tracker, workspace, codex) do
    []
    |> maybe_add_tracker(tracker)
    |> maybe_add_workspace(workspace)
    |> maybe_add_codex(codex)
    |> Enum.reverse()
  end

  defp maybe_add_tracker(integrations, %{"api_key" => api_key})
       when is_binary(api_key) and api_key != "" do
    [%{"id" => "tracker", "kind" => "tracker", "credential_ref" => "secret:tracker"} | integrations]
  end

  defp maybe_add_tracker(integrations, _tracker), do: integrations

  defp maybe_add_workspace(integrations, workspace) when map_size(workspace) > 0 do
    [%{"id" => "workspace", "kind" => "workspace", "settings" => workspace} | integrations]
  end

  defp maybe_add_workspace(integrations, _workspace), do: integrations

  defp maybe_add_codex(integrations, codex) when map_size(codex) > 0 do
    [%{"id" => "codex", "kind" => "codex", "settings" => codex} | integrations]
  end

  defp maybe_add_codex(integrations, _codex), do: integrations
end
