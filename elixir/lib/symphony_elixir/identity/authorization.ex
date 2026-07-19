defmodule SymphonyElixir.Identity.Authorization do
  @moduledoc """
  Single authorization policy for browser routes, REST routes, and localized navigation.
  """

  alias SymphonyElixir.Identity.Principal

  @navigation [
    %{key: :tasks, path: "/tasks", label: %{"en" => "Tasks", "zh-CN" => "任务"}, action: :read_task},
    %{key: :interventions, path: "/interventions", label: %{"en" => "Interventions", "zh-CN" => "干预"}, action: :retry_task},
    %{key: :configuration, path: "/configuration", label: %{"en" => "Configuration", "zh-CN" => "配置"}, action: :write_configuration},
    %{key: :secrets, path: "/configuration/secrets", label: %{"en" => "Secrets", "zh-CN" => "密钥"}, action: :write_secret},
    %{key: :audit, path: "/audit", label: %{"en" => "Audit", "zh-CN" => "审计"}, action: :read_audit},
    %{key: :health, path: "/health", label: %{"en" => "Health", "zh-CN" => "健康"}, action: :read_health},
    %{key: :backups, path: "/backups", label: %{"en" => "Backups", "zh-CN" => "备份"}, action: :write_configuration}
  ]

  @read_actions [:read_task, :read_configuration, :read_audit, :read_health]
  @operator_actions [:retry_task, :cancel_task]
  @admin_actions [:write_configuration, :write_secret, :manage_identity]

  @spec authorize(Principal.t() | map() | nil, atom()) :: :ok | {:error, :unauthorized | :forbidden}
  def authorize(nil, _action), do: {:error, :unauthorized}

  def authorize(%{roles: roles}, action) when is_list(roles) do
    cond do
      :administrator in roles -> :ok
      action in @read_actions and (:viewer in roles or :operator in roles) -> :ok
      action in @operator_actions and :operator in roles -> :ok
      action in @admin_actions -> {:error, :forbidden}
      true -> {:error, :forbidden}
    end
  end

  def authorize(_principal, _action), do: {:error, :unauthorized}

  @spec authorized_navigation(Principal.t(), String.t()) :: [map()]
  def authorized_navigation(%Principal{} = principal, locale) do
    Enum.flat_map(@navigation, fn item ->
      if authorize(principal, item.action) == :ok do
        [Map.put(item, :label, localized_label(item.label, locale))]
      else
        []
      end
    end)
  end

  @spec action_for_path(String.t(), String.t()) :: atom()
  def action_for_path(_method, path) do
    cond do
      String.starts_with?(path, "/api/v1/secrets") -> :write_secret
      String.starts_with?(path, "/api/v1/configuration") -> :write_configuration
      String.contains?(path, "/retry") -> :retry_task
      String.starts_with?(path, "/api/v1/tasks") -> :read_task
      String.starts_with?(path, "/configuration/secrets") -> :write_secret
      String.starts_with?(path, "/configuration") -> :write_configuration
      true -> :read_task
    end
  end

  defp localized_label(labels, "zh-CN"), do: Map.fetch!(labels, "zh-CN")
  defp localized_label(labels, _locale), do: Map.fetch!(labels, "en")
end
