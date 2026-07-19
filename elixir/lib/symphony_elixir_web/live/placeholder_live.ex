defmodule SymphonyElixirWeb.PlaceholderLive do
  @moduledoc false

  use Phoenix.LiveView

  alias SymphonyElixir.Identity.Authorization
  alias SymphonyElixirWeb.Navigation

  @dialyzer {:nowarn_function, mount: 3}

  @impl true
  def mount(params, session, socket) do
    with principal_id when is_binary(principal_id) <- Map.get(session, "principal_id"),
         {:ok, principal} <- SymphonyElixir.Identity.get_principal(principal_id),
         locale <- Map.get(params, "locale", "en"),
         :ok <- Authorization.authorize(principal, :read_task) do
      {:ok,
       assign(socket,
         principal: principal,
         locale: locale,
         nav: Navigation.items(principal, locale),
         active_key: :tasks
       )}
    else
      _ -> {:ok, redirect(socket, to: "/auth/login")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="control-shell">
      <header class="control-topbar">
        <a class="control-brand" href={localized_path("/tasks", @locale)} aria-label="Symphony">
          <span class="brand-mark" aria-hidden="true">S</span>
          <span>
            <strong>Symphony</strong>
            <small>{if @locale == "zh-CN", do: "控制台", else: "Control"}</small>
          </span>
        </a>

        <nav class="control-nav" aria-label="Primary">
          <a
            :for={item <- @nav}
            href={localized_path(item.path, @locale)}
            class={if item.key == @active_key, do: "active"}
            aria-current={if item.key == @active_key, do: "page", else: nil}
            data-nav-key={item.key}
          >
            {item.label}
          </a>
        </nav>

        <div class="control-actions" aria-label="Session controls">
          <span class="role-pill">{role_label(@principal.roles, @locale)}</span>
          <a class={if @locale == "en", do: "locale-link active", else: "locale-link"} href="/tasks">EN</a>
          <a class={if @locale == "zh-CN", do: "locale-link active", else: "locale-link"} href="/zh-CN/tasks">中文</a>
          <a class="account-link" href="/auth/logout">{if @locale == "zh-CN", do: "退出", else: "Sign out"}</a>
        </div>
      </header>

      <section class="workspace-header" aria-labelledby="workspace-title">
        <p class="eyebrow">{if @locale == "zh-CN", do: "工作区", else: "Workspace"}</p>
        <h1 id="workspace-title">{if @locale == "zh-CN", do: "任务", else: "Tasks"}</h1>
      </section>
    </main>
    """
  end

  defp localized_path(path, "zh-CN"), do: "/zh-CN" <> path
  defp localized_path(path, _locale), do: path

  defp role_label(roles, "zh-CN") do
    cond do
      :administrator in roles -> "管理员"
      :operator in roles -> "操作员"
      true -> "查看者"
    end
  end

  defp role_label(roles, _locale) do
    cond do
      :administrator in roles -> "Administrator"
      :operator in roles -> "Operator"
      true -> "Viewer"
    end
  end
end
