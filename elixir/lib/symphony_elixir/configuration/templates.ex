defmodule SymphonyElixir.Configuration.Templates do
  @moduledoc """
  Starter task type and execution profile templates.
  """

  @template_names [
    {"general", "General"},
    {"frontend", "Frontend"},
    {"backend", "Backend"},
    {"documentation", "Documentation"},
    {"integration", "Integration"}
  ]

  @spec all() :: map()
  def all do
    %{
      "task_types" =>
        Enum.map(@template_names, fn {id, name} ->
          %{
            "id" => id,
            "name" => name,
            "profile_id" => "#{id}-profile",
            "active" => false
          }
        end),
      "execution_profiles" =>
        Enum.map(@template_names, fn {id, name} ->
          %{
            "id" => "#{id}-profile",
            "name" => "#{name} profile",
            "runtime" => "codex",
            "instructions" => "#{name} task execution template",
            "active" => false
          }
        end)
    }
  end
end
