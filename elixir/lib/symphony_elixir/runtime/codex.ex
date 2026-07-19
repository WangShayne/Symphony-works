defmodule SymphonyElixir.Runtime.Codex do
  @moduledoc """
  Runtime adapter for the V1 production Codex App Server protocol.
  """

  @behaviour SymphonyElixir.Runtime

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.Runtime
  alias SymphonyElixir.Runtime.{Session, TurnResult}

  @impl true
  def start_session(opts) when is_map(opts) do
    app_server = Map.get(opts, :app_server, AppServer)
    app_opts = Map.get(opts, :app_server_opts, [])

    with {:ok, workspace} <- fetch_required_string(opts, :workspace, :missing_workspace),
         {:ok, app_session} <- start_app_session(app_server, workspace, app_opts),
         {:ok, session_id} <- fetch_required_string(app_session, :thread_id, :invalid_startup_response) do
      {:ok,
       %Session{
         adapter: __MODULE__,
         runtime: :codex,
         session_id: session_id,
         adapter_state: %{app_server: app_server, app_session: app_session},
         metadata: %{
           workspace: workspace,
           model_reference: Map.get(opts, :model_reference)
         }
       }}
    end
  end

  @impl true
  def run_turn(
        %Session{
          runtime: :codex,
          adapter_state: %{app_server: app_server, app_session: app_session},
          session_id: session_id
        },
        input
      )
      when is_map(input) do
    with {:ok, prompt} <- fetch_required_string(input, :prompt, :missing_prompt),
         {:ok, result} <-
           run_app_turn(app_server, app_session, prompt, Map.get(input, :issue, %{}), Map.get(input, :app_server_opts, [])) do
      normalize_turn_result(result, session_id)
    end
  end

  @impl true
  def stop_session(%Session{
        runtime: :codex,
        adapter_state: %{app_server: app_server, app_session: app_session}
      }) do
    stop_app_session(app_server, app_session)
  end

  @impl true
  def capabilities(%{"capabilities" => capabilities}) when is_map(capabilities) do
    {:ok, Map.take(capabilities, ["structured_output", "tool_use", "context_window"])}
  end

  def capabilities(_model_reference) do
    {:error, {:runtime_error, :missing_capabilities}}
  end

  @impl true
  def health_check(model_reference, opts) when is_map(model_reference) do
    with {:ok, capabilities} <- capabilities(model_reference),
         :ok <- require_structured_output(capabilities),
         {:ok, model_id} <- fetch_required_string(model_reference, "model_id", :missing_model_id),
         {:ok, endpoint} <- fetch_required_string(model_reference, "endpoint", :missing_endpoint) do
      run_structured_plan_probe(model_reference, model_id, endpoint, capabilities, opts)
    end
  end

  defp start_app_session(app_server, workspace, app_opts, error \\ :codex_start_failed) do
    safe_app_call(
      fn -> app_server.start_session(workspace, app_opts) end,
      error,
      &normalize_app_ok(&1, error)
    )
  end

  defp run_app_turn(app_server, app_session, prompt, issue, app_opts, error \\ :codex_turn_failed) do
    safe_app_call(
      fn -> app_server.run_turn(app_session, prompt, issue, app_opts) end,
      error,
      &normalize_app_ok(&1, error)
    )
  end

  defp stop_app_session(app_server, app_session, error \\ :codex_stop_failed) do
    safe_app_call(fn -> app_server.stop_session(app_session) end, error, fn
      :ok -> :ok
      {:error, _reason} -> {:error, {:runtime_error, error}}
      _other -> {:error, {:runtime_error, error}}
    end)
  end

  defp safe_app_call(fun, error, normalize) when is_function(fun, 0) and is_function(normalize, 1) do
    fun.()
    |> normalize.()
  rescue
    _exception -> {:error, {:runtime_error, error}}
  catch
    _kind, _reason -> {:error, {:runtime_error, error}}
  end

  defp normalize_app_ok({:ok, result}, _error), do: {:ok, result}
  defp normalize_app_ok({:error, _reason}, error), do: {:error, {:runtime_error, error}}
  defp normalize_app_ok(_other, error), do: {:error, {:runtime_error, error}}
  defp require_structured_output(%{"structured_output" => true}), do: :ok

  defp require_structured_output(_capabilities) do
    {:error, {:runtime_error, :structured_output_unavailable}}
  end

  defp run_structured_plan_probe(model_reference, model_id, endpoint, capabilities, opts) do
    app_server =
      Keyword.get(opts, :app_server, Application.get_env(:symphony_elixir, :runtime_health_app_server, AppServer))

    with {:ok, provider_binding} <- provider_binding(model_reference, model_id, endpoint, opts),
         {:ok, workspace} <- probe_workspace(opts),
         app_opts <- health_probe_opts(opts, provider_binding),
         {:ok, app_session} <- start_app_session(app_server, workspace, app_opts, :codex_health_start_failed) do
      turn_result =
        with {:ok, result} <-
               run_app_turn(
                 app_server,
                 app_session,
                 probe_prompt(),
                 probe_issue(model_reference),
                 app_opts,
                 :codex_health_turn_failed
               ),
             :ok <- validate_probe_result(result) do
          {:ok,
           %{
             "runtime" => "codex",
             "status" => "passed",
             "model_id" => model_id,
             "endpoint" => endpoint,
             "structured_plan_probe" => %{"mode" => "read_only", "schema" => "passed"},
             "capabilities" => capabilities,
             "prices" => price_snapshot(model_reference)
           }}
        end

      case {turn_result, stop_app_session(app_server, app_session, :codex_health_stop_failed)} do
        {{:ok, evidence}, :ok} -> {:ok, evidence}
        {{:error, _reason} = error, _stop_result} -> error
        {{:ok, _evidence}, {:error, _reason} = error} -> error
      end
    end
  end

  defp probe_workspace(opts) do
    workspace =
      Keyword.get(opts, :workspace) ||
        Application.get_env(:symphony_elixir, :runtime_health_workspace) ||
        Path.join(Config.settings!().workspace.root, ".runtime-health")

    case File.mkdir_p(workspace) do
      :ok -> {:ok, workspace}
      {:error, _reason} -> {:error, {:runtime_error, :codex_health_start_failed}}
    end
  rescue
    _exception -> {:error, {:runtime_error, :codex_health_start_failed}}
  end

  defp probe_prompt do
    """
    Return only a JSON object matching this schema:
    {"type":"object","required":["task_type"],"properties":{"task_type":{"type":"string"}}}
    """
  end

  defp probe_issue(model_reference) do
    %{
      id: "runtime-capability-probe",
      identifier: "runtime-capability-probe",
      title: "Read-only structured plan probe",
      model_reference_id: Map.get(model_reference, "id")
    }
  end

  defp health_probe_opts(opts, nil) do
    opts
    |> Keyword.get(:app_server_opts, Application.get_env(:symphony_elixir, :runtime_health_app_server_opts, []))
    |> Keyword.put(:health_probe, true)
  end

  defp health_probe_opts(opts, provider_binding) do
    opts
    |> health_probe_opts(nil)
    |> Keyword.put(:provider_binding, provider_binding)
  end

  defp provider_binding(model_reference, model_id, endpoint, opts) do
    provider = Keyword.get(opts, :provider, %{})
    credential = Keyword.get(opts, :provider_credential)

    if is_binary(credential) and credential != "" do
      provider_id = Map.get(provider, "id", Map.get(model_reference, "provider_id", "symphony-health-provider"))
      provider_endpoint = Map.get(provider, "endpoint", endpoint)
      wire_api = Map.get(provider, "wire_api", "responses")

      with true <- provider_endpoint == endpoint,
           true <- Map.get(provider, "runtime_protocol", "codex_app_server") == "codex_app_server",
           true <- is_binary(provider_id) and provider_id != "",
           true <- wire_api == "responses",
           true <- valid_provider_endpoint?(endpoint) do
        {:ok,
         %{
           provider_id: provider_id,
           model_id: model_id,
           endpoint: endpoint,
           wire_api: wire_api,
           credential_env: "SYMPHONY_CODEX_PROVIDER_API_KEY",
           credential: credential
         }}
      else
        _invalid_binding -> {:error, {:runtime_error, :invalid_provider_binding}}
      end
    else
      {:ok, nil}
    end
  end

  defp validate_probe_result(%{result: %{"task_type" => task_type}}) when is_binary(task_type), do: :ok
  defp validate_probe_result(%{"result" => %{"task_type" => task_type}}) when is_binary(task_type), do: :ok

  defp validate_probe_result(_result) do
    {:error, {:runtime_error, :codex_health_invalid_response}}
  end

  defp normalize_turn_result(result, fallback_session_id) when is_map(result) do
    session_id = Map.get(result, :session_id, fallback_session_id)

    {:ok,
     %TurnResult{
       runtime: :codex,
       session_id: session_id,
       output: Map.get(result, :result),
       events: [Runtime.event(:codex, :turn_completed, session_id, %{})],
       metadata: Map.take(result, [:thread_id, :turn_id])
     }}
  end

  defp normalize_turn_result(_result, _fallback_session_id), do: {:error, {:runtime_error, :codex_invalid_response}}

  defp fetch_required_string(map, key, error) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing_or_blank -> {:error, {:runtime_error, error}}
    end
  end

  defp price_snapshot(%{"prices" => prices}) when is_map(prices) do
    Map.take(prices, ["input", "cached_input", "output"])
  end

  defp price_snapshot(_model_reference), do: %{}

  defp valid_provider_endpoint?(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _invalid ->
        false
    end
  end
end
