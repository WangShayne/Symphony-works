defmodule SymphonyElixirWeb.TaskLive do
  @moduledoc false

  use Phoenix.LiveView

  alias SymphonyElixir.{Coordination, Identity}
  alias SymphonyElixir.Identity.Authorization
  alias SymphonyElixirWeb.Navigation

  @dialyzer {:nowarn_function, mount: 3}

  @impl true
  def mount(params, session, socket) do
    with principal_id when is_binary(principal_id) <- Map.get(session, "principal_id"),
         {:ok, principal} <- Identity.get_principal(principal_id),
         :ok <- Authorization.authorize(principal, :read_task) do
      locale = Map.get(params, "locale", "en")

      socket =
        assign(socket,
          principal: principal,
          locale: locale,
          nav: Navigation.items(principal, locale),
          active_key: :tasks,
          tasks: [],
          task: nil
        )

      mount_view(socket.assigns.live_action, params, socket)
    else
      _reason -> {:ok, redirect(socket, to: "/auth/login")}
    end
  end

  @impl true
  def handle_info({:coordination_updated, %{id: id} = task}, %{assigns: %{task: %{id: id}}} = socket) do
    {:noreply, assign(socket, task: task)}
  end

  def handle_info({:coordination_updated, _task}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="control-shell task-workspace">
      <header class="control-topbar">
        <a class="control-brand" href={localized_path("/tasks", @locale)} aria-label="Symphony">
          <span class="brand-mark" aria-hidden="true">S</span>
          <span>
            <strong>Symphony</strong>
            <small>{if @locale == "zh-CN", do: "控制台", else: "Control"}</small>
          </span>
        </a>

        <nav class="control-nav" aria-label={if @locale == "zh-CN", do: "主导航", else: "Primary"}>
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

        <div
          class="control-actions"
          aria-label={if @locale == "zh-CN", do: "会话控制", else: "Session controls"}
        >
          <span class="role-pill">{role_label(@principal.roles, @locale)}</span>
          <a
            class={if @locale == "en", do: "locale-link active", else: "locale-link"}
            href={locale_path(@live_action, @task, "en")}
          >EN</a>
          <a
            class={if @locale == "zh-CN", do: "locale-link active", else: "locale-link"}
            href={locale_path(@live_action, @task, "zh-CN")}
          >中文</a>
          <a class="account-link" href="/auth/logout">
            {if @locale == "zh-CN", do: "退出", else: "Sign out"}
          </a>
        </div>
      </header>

      <%= if @live_action == :index do %>
        <section class="workspace-header task-page-heading" aria-labelledby="workspace-title">
          <div>
            <p class="eyebrow">{if @locale == "zh-CN", do: "工作区", else: "Workspace"}</p>
            <h1 id="workspace-title">{if @locale == "zh-CN", do: "任务", else: "Tasks"}</h1>
          </div>
          <p class="task-count">{task_count_label(length(@tasks), @locale)}</p>
        </section>

        <section class="task-list" aria-label={if @locale == "zh-CN", do: "任务列表", else: "Task list"}>
          <a
            :for={task <- @tasks}
            class="task-row"
            href={localized_path("/tasks/#{task.id}", @locale)}
            data-task-id={task.id}
          >
            <span class="task-row-primary">
              <strong>{task.external_id || task.id}</strong>
              <small>{task_summary(task)}</small>
            </span>
            <span class="task-row-reference mono">{short_reference(task.configuration_revision)}</span>
            <span class={status_class(task.status)}>{status_label(task.status, @locale)}</span>
          </a>

          <p :if={@tasks == []} class="task-empty">
            {if @locale == "zh-CN", do: "暂无任务", else: "No tasks"}
          </p>
        </section>
      <% else %>
        <section class="task-detail" data-task-id={@task.id}>
          <header class="task-detail-heading">
            <div>
              <a class="task-back-link" href={localized_path("/tasks", @locale)}>
                {if @locale == "zh-CN", do: "任务", else: "Tasks"}
              </a>
              <p class="eyebrow">{if @locale == "zh-CN", do: "任务详情", else: "Task detail"}</p>
              <h1>{@task.external_id || @task.id}</h1>
              <p class="task-objective">{task_summary(@task)}</p>
            </div>
            <span id="task-status" class={status_class(@task.status)}>
              {status_label(@task.status, @locale)}
            </span>
          </header>

          <dl class="task-state-strip">
            <div>
              <dt>{if @locale == "zh-CN", do: "协调版本", else: "Coordination version"}</dt>
              <dd class="numeric">{@task.version}</dd>
            </div>
            <div>
              <dt>{if @locale == "zh-CN", do: "计划版本", else: "Plan revision"}</dt>
              <dd class="mono">{@task.plan_revision || "-"}</dd>
            </div>
            <div>
              <dt>{if @locale == "zh-CN", do: "配置版本", else: "Configuration revision"}</dt>
              <dd class="mono">{short_reference(@task.configuration_revision)}</dd>
            </div>
            <div data-effect-status={atom_string(@task.effect_status)}>
              <dt>{if @locale == "zh-CN", do: "外部操作", else: "External effect"}</dt>
              <dd>{effect_label(@task.effect_status, @locale)}</dd>
            </div>
          </dl>

          <div class="task-detail-grid">
            <section class="task-section" aria-labelledby="task-coordinates-title">
              <h2 id="task-coordinates-title">
                {if @locale == "zh-CN", do: "任务坐标", else: "Task coordinates"}
              </h2>
              <dl class="task-metadata">
                <div>
                  <dt>{if @locale == "zh-CN", do: "任务 ID", else: "Task ID"}</dt>
                  <dd class="mono">{@task.id}</dd>
                </div>
                <div>
                  <dt>{if @locale == "zh-CN", do: "基线提交", else: "Baseline commit"}</dt>
                  <dd class="mono">{short_reference(@task.baseline)}</dd>
                </div>
                <div>
                  <dt>{if @locale == "zh-CN", do: "关联 ID", else: "Correlation ID"}</dt>
                  <dd class="mono">{@task.correlation_id}</dd>
                </div>
                <div>
                  <dt>{if @locale == "zh-CN", do: "操作 ID", else: "Operation ID"}</dt>
                  <dd class="mono">{effect_operation_id(@task.effect)}</dd>
                </div>
              </dl>
            </section>

            <section class="task-section task-units" aria-labelledby="execution-units-title">
              <div class="task-section-heading">
                <h2 id="execution-units-title">
                  {if @locale == "zh-CN", do: "执行单元", else: "Execution units"}
                </h2>
                <span class="numeric">{length(@task.units)}</span>
              </div>
              <div class="unit-table-wrap">
                <table class="unit-table">
                  <thead>
                    <tr>
                      <th>{if @locale == "zh-CN", do: "单元", else: "Unit"}</th>
                      <th>{if @locale == "zh-CN", do: "类型", else: "Type"}</th>
                      <th>{if @locale == "zh-CN", do: "执行档案", else: "Profile"}</th>
                      <th>{if @locale == "zh-CN", do: "状态", else: "Status"}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={unit <- @task.units} data-unit-id={unit.id}>
                      <td class="mono">{unit.id}</td>
                      <td>{unit.task_type || "-"}</td>
                      <td class="mono">{unit.execution_profile || "-"}</td>
                      <td><span class={status_class(unit.status)}>{status_label(unit.status, @locale)}</span></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          </div>
        </section>
      <% end %>
    </main>
    """
  end

  defp mount_view(:index, _params, socket) do
    {:ok, assign(socket, tasks: Coordination.list(%{}))}
  end

  defp mount_view(:show, %{"id" => id}, socket) do
    if connected?(socket), do: :ok = Coordination.subscribe(id)

    case Coordination.snapshot(id) do
      {:ok, task} ->
        {:ok, assign(socket, task: task)}

      {:error, :not_found} ->
        {:ok, redirect(socket, to: localized_path("/tasks", socket.assigns.locale))}
    end
  end

  defp localized_path(path, "zh-CN"), do: "/zh-CN" <> path
  defp localized_path(path, _locale), do: path

  defp locale_path(:show, %{id: id}, locale), do: localized_path("/tasks/#{id}", locale)
  defp locale_path(_action, _task, locale), do: localized_path("/tasks", locale)

  defp task_summary(%{data: data}) when is_map(data) do
    Map.get(data, "summary") || Map.get(data, :summary) || "-"
  end

  defp task_count_label(count, "zh-CN"), do: "#{count} 个任务"
  defp task_count_label(count, _locale), do: "#{count} tasks"

  defp status_label(:queued, "zh-CN"), do: "排队中"
  defp status_label(:planning, "zh-CN"), do: "规划中"
  defp status_label(:running, "zh-CN"), do: "运行中"
  defp status_label(:awaiting_intervention, "zh-CN"), do: "等待干预"
  defp status_label(:integrating, "zh-CN"), do: "集成中"
  defp status_label(:validating, "zh-CN"), do: "验证中"
  defp status_label(:review_ready, "zh-CN"), do: "评审就绪"
  defp status_label(:pending, "zh-CN"), do: "待处理"
  defp status_label(:runnable, "zh-CN"), do: "可执行"
  defp status_label(:blocked, "zh-CN"), do: "已阻塞"
  defp status_label(:awaiting_approval, "zh-CN"), do: "等待批准"
  defp status_label(:accepted, "zh-CN"), do: "已验收"
  defp status_label(:completed, "zh-CN"), do: "已完成"
  defp status_label(:failed, "zh-CN"), do: "失败"
  defp status_label(:cancelled, "zh-CN"), do: "已取消"
  defp status_label(:queued, _locale), do: "Queued"
  defp status_label(:planning, _locale), do: "Planning"
  defp status_label(:running, _locale), do: "Running"
  defp status_label(:awaiting_intervention, _locale), do: "Awaiting intervention"
  defp status_label(:integrating, _locale), do: "Integrating"
  defp status_label(:validating, _locale), do: "Validating"
  defp status_label(:review_ready, _locale), do: "Review ready"
  defp status_label(:pending, _locale), do: "Pending"
  defp status_label(:runnable, _locale), do: "Runnable"
  defp status_label(:blocked, _locale), do: "Blocked"
  defp status_label(:awaiting_approval, _locale), do: "Awaiting approval"
  defp status_label(:accepted, _locale), do: "Accepted"
  defp status_label(:completed, _locale), do: "Completed"
  defp status_label(:failed, _locale), do: "Failed"
  defp status_label(:cancelled, _locale), do: "Cancelled"

  defp effect_label(:succeeded, "zh-CN"), do: "外部操作已记录"
  defp effect_label(:unknown, "zh-CN"), do: "结果未知"
  defp effect_label(:recovery_needed, "zh-CN"), do: "需要恢复"
  defp effect_label(nil, "zh-CN"), do: "未开始"
  defp effect_label(:succeeded, _locale), do: "Effect succeeded"
  defp effect_label(:unknown, _locale), do: "Outcome unknown"
  defp effect_label(:recovery_needed, _locale), do: "Recovery needed"
  defp effect_label(nil, _locale), do: "Not started"

  defp status_class(:accepted), do: "task-status task-status-success"
  defp status_class(:review_ready), do: "task-status task-status-success"
  defp status_class(:completed), do: "task-status task-status-success"
  defp status_class(:planning), do: "task-status task-status-running"
  defp status_class(:runnable), do: "task-status task-status-running"
  defp status_class(:running), do: "task-status task-status-running"
  defp status_class(:integrating), do: "task-status task-status-running"
  defp status_class(:validating), do: "task-status task-status-running"
  defp status_class(:awaiting_intervention), do: "task-status task-status-danger"
  defp status_class(:blocked), do: "task-status task-status-danger"
  defp status_class(:failed), do: "task-status task-status-danger"
  defp status_class(_status), do: "task-status task-status-pending"

  defp effect_operation_id(%{operation_id: operation_id}) when is_binary(operation_id),
    do: operation_id

  defp effect_operation_id(_effect), do: "-"

  defp short_reference(value) when is_binary(value) and byte_size(value) > 16,
    do: String.slice(value, 0, 12)

  defp short_reference(value) when is_binary(value), do: value
  defp short_reference(_value), do: "-"

  defp atom_string(nil), do: ""
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)

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
