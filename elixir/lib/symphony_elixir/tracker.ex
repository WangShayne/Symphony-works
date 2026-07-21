defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Security.{CredentialBroker, SecretStore}
  alias SymphonyElixir.Tracker.EndpointPolicy
  alias SymphonyElixir.Tracker.Issue

  @adapters %{
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory
  }

  @integration_adapters %{
    "fixture" => SymphonyElixir.Tracker.Adapters.Fixture,
    "github" => SymphonyElixir.Tracker.Adapters.GitHub,
    "gitlab" => SymphonyElixir.Tracker.Adapters.GitLab,
    "linear" => SymphonyElixir.Tracker.Adapters.Linear
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}

  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      validate_config: 1

  @doc """
  Probes a normalized tracker integration without exposing its credential.

  String-key and atom-key configuration maps are accepted. Provider adapters
  return only normalized, redacted evidence through this seam.
  """
  @spec health_check(term(), term()) :: {:ok, map()} | {:error, map()}
  def health_check(config, opts \\ []) do
    if is_map(config) and is_list(opts) do
      with {:ok, provider} <- integration_provider(config),
           {:ok, adapter} <- integration_adapter(provider) do
        invoke_integration(provider, adapter, :health_check, [config], opts)
      end
    else
      integration_error(nil, :invalid_config, "tracker config must be a map")
    end
  end

  @doc """
  Fetches issues that satisfy every explicit eligibility criterion.

  The criteria map accepts `states`, `required_labels`, and optional
  `assignee_id`. Matching is provider-neutral and case-insensitive for states
  and labels.
  """
  @spec fetch_eligible(term(), term(), term()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_eligible(config, criteria, opts \\ []) do
    if is_map(config) and is_map(criteria) and is_list(opts) do
      with {:ok, provider} <- integration_provider(config),
           {:ok, adapter} <- integration_adapter(provider) do
        invoke_integration(provider, adapter, :fetch_eligible, [config, criteria], opts)
      end
    else
      integration_error(nil, :invalid_request, "tracker config and eligibility must be maps")
    end
  end

  @doc "Returns normalized issues in the caller's requested identifier order."
  @spec fetch_by_ids(term(), term(), term()) :: {:ok, [Issue.t()]} | {:error, map()}
  def fetch_by_ids(config, issue_ids, opts \\ []) do
    if is_map(config) and is_list(issue_ids) and is_list(opts) do
      with {:ok, provider} <- integration_provider(config),
           {:ok, adapter} <- integration_adapter(provider) do
        invoke_integration(provider, adapter, :fetch_by_ids, [config, issue_ids], opts)
      end
    else
      integration_error(nil, :invalid_request, "tracker config and issue ids are invalid")
    end
  end

  @doc "Verifies and normalizes a provider webhook into one idempotent reconciliation signal."
  @spec normalize_webhook(term(), term(), term()) :: {:ok, map()} | {:error, map()}
  def normalize_webhook(config, request, opts \\ []) do
    if is_map(config) and is_map(request) and is_list(opts) do
      with {:ok, provider} <- integration_provider(config),
           {:ok, adapter} <- integration_adapter(provider) do
        invoke_integration(provider, adapter, :normalize_webhook, [config, request], opts)
      end
    else
      integration_error(nil, :invalid_request, "tracker config and webhook request are invalid")
    end
  end

  @doc "Transitions one issue using a normalized target state."
  @spec transition_issue(term(), term(), term(), term()) ::
          {:ok, map()} | {:error, map()}
  def transition_issue(config, issue_id, target_state, opts \\ []) do
    if is_map(config) and is_binary(issue_id) and is_list(opts) do
      with {:ok, provider} <- integration_provider(config),
           {:ok, adapter} <- integration_adapter(provider) do
        invoke_integration(
          provider,
          adapter,
          :transition_issue,
          [config, issue_id, target_state],
          opts
        )
      end
    else
      integration_error(nil, :invalid_request, "tracker transition request is invalid")
    end
  end

  @doc "Creates or updates the single stable progress comment for an issue."
  @spec upsert_progress(term(), term(), term(), term()) ::
          {:ok, map()} | {:error, map()}
  def upsert_progress(config, issue_id, progress, opts \\ []) do
    if is_map(config) and is_binary(issue_id) and is_binary(progress) and is_list(opts) do
      with {:ok, provider} <- integration_provider(config),
           {:ok, adapter} <- integration_adapter(provider) do
        invoke_integration(provider, adapter, :upsert_progress, [config, issue_id, progress], opts)
      end
    else
      integration_error(nil, :invalid_request, "tracker progress request is invalid")
    end
  end

  @doc "Appends or updates the single stable final-summary comment for an issue."
  @spec append_final_summary(term(), term(), term(), term()) ::
          {:ok, map()} | {:error, map()}
  def append_final_summary(config, issue_id, summary, opts \\ []) do
    if is_map(config) and is_binary(issue_id) and is_binary(summary) and is_list(opts) do
      with {:ok, provider} <- integration_provider(config),
           {:ok, adapter} <- integration_adapter(provider) do
        invoke_integration(
          provider,
          adapter,
          :append_final_summary,
          [config, issue_id, summary],
          opts
        )
      end
    else
      integration_error(nil, :invalid_request, "tracker final summary request is invalid")
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    adapter().fetch_issues_by_ids(issue_ids)
  end

  @doc """
  Captures the selected adapter and effective tracker settings for one
  app-server session so tool advertisement and execution cannot drift across a
  workflow reload.
  """
  @spec bind_agent_tools() :: map()
  def bind_agent_tools do
    tracker_settings = Config.settings!().tracker
    adapter = adapter_for_settings!(tracker_settings)

    %{
      adapter: adapter,
      tracker_settings: tracker_settings,
      tool_specs: adapter_agent_tool_specs(adapter),
      secret_environment_names: adapter_secret_environment_names(adapter, tracker_settings)
    }
  end

  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings},
        tool,
        arguments,
        opts \\ []
      ) do
    execute_agent_tool_with_adapter(
      adapter,
      tool,
      arguments,
      Keyword.put(opts, :tracker_settings, tracker_settings)
    )
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker
    |> adapter_for_settings!()
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_for_settings!(%{kind: kind}) do
    {:ok, adapter} = adapter_for_kind(kind)
    adapter
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp integration_provider(config) do
    case Map.get(config, "provider", Map.get(config, :provider)) do
      provider when is_binary(provider) and provider != "" ->
        {:ok, provider |> String.trim() |> String.downcase()}

      _other ->
        integration_error(nil, :missing_provider, "tracker provider is required")
    end
  end

  defp integration_adapter(provider) do
    case Map.fetch(@integration_adapters, provider) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> integration_error(provider, :unsupported_provider, "tracker provider is unsupported")
    end
  end

  defp integration_error(provider, code, message) do
    {:error,
     %{
       provider: provider,
       code: code,
       retryable: false,
       message: message
     }}
  end

  defp invoke_integration(provider, adapter, operation, [config | _rest] = arguments, opts) do
    with {:ok, endpoint_policy} <- validate_integration_config(provider, config, operation, opts) do
      do_invoke_integration(
        provider,
        adapter,
        operation,
        arguments,
        maybe_put_endpoint_policy(opts, endpoint_policy)
      )
    end
  end

  defp do_invoke_integration(provider, adapter, :health_check, [config | rest], opts) do
    {sanitized_config, health_opts, runtime_secrets} = runtime_health_context(config, opts)
    arguments = [sanitized_config | rest]

    if provider == "fixture" or Keyword.has_key?(health_opts, :credential) do
      safe_adapter_call(provider, adapter, :health_check, arguments ++ [health_opts])
      |> reject_plaintext_result(provider, runtime_secrets)
    else
      invoke_brokered_integration(provider, adapter, :health_check, arguments, health_opts)
    end
  end

  defp do_invoke_integration("fixture", adapter, operation, arguments, opts) do
    safe_adapter_call("fixture", adapter, operation, arguments ++ [opts])
  end

  defp do_invoke_integration(provider, adapter, operation, arguments, opts) do
    invoke_brokered_integration(provider, adapter, operation, arguments, opts)
  end

  defp invoke_brokered_integration(provider, adapter, operation, arguments, opts) do
    credential_ref = credential_reference(operation, hd(arguments))
    broker = Keyword.get(opts, :credential_broker, CredentialBroker)

    case broker.with_secret(credential_ref, credential_purpose(operation), fn credential ->
           safe_adapter_call(
             provider,
             adapter,
             operation,
             arguments ++ [Keyword.put(opts, :credential, credential)]
           )
         end) do
      {:ok, result} -> {:ok, result}
      {:error, %{code: _code} = error} -> {:error, sanitize_error(provider, error)}
      {:error, reason} -> normalize_integration_error(provider, reason)
    end
  rescue
    _exception -> integration_error(provider, :credential_unavailable, "tracker credential is unavailable")
  catch
    _kind, _reason -> integration_error(provider, :credential_unavailable, "tracker credential is unavailable")
  end

  defp safe_adapter_call(provider, adapter, operation, arguments) do
    adapter
    |> apply(operation, arguments)
    |> normalize_adapter_result(provider)
  rescue
    _exception -> integration_error(provider, :adapter_failed, "tracker adapter failed")
  catch
    _kind, _reason -> integration_error(provider, :adapter_failed, "tracker adapter failed")
  end

  defp normalize_adapter_result({:error, %{code: _code} = error}, provider),
    do: {:error, sanitize_error(provider, error)}

  defp normalize_adapter_result(result, _provider), do: result

  defp credential_purpose(:health_check), do: :tracker_health_check
  defp credential_purpose(:fetch_eligible), do: :tracker_fetch_eligible
  defp credential_purpose(:fetch_by_ids), do: :tracker_fetch_by_ids
  defp credential_purpose(:normalize_webhook), do: :tracker_normalize_webhook
  defp credential_purpose(:transition_issue), do: :tracker_transition_issue
  defp credential_purpose(:upsert_progress), do: :tracker_upsert_progress
  defp credential_purpose(:append_final_summary), do: :tracker_append_final_summary

  defp credential_reference(:normalize_webhook, config) do
    config
    |> config_value(:settings, %{})
    |> config_value(:webhook_secret_ref)
  end

  defp credential_reference(_operation, config), do: config_value(config, :credential_ref)

  defp normalize_integration_error(provider, reason)
       when reason in [:not_found, :invalid_reference, :invalid_callback, :callback_failed] do
    integration_error(provider, :credential_unavailable, "tracker credential is unavailable")
  end

  defp normalize_integration_error(provider, :plaintext_returned) do
    integration_error(provider, :unsafe_provider_response, "tracker provider returned unsafe data")
  end

  defp normalize_integration_error(provider, _reason) do
    integration_error(provider, :adapter_failed, "tracker adapter failed")
  end

  defp sanitize_error(provider, error) do
    error
    |> Map.take([:code, :retryable, :message, :retry_after_ms])
    |> Map.put(:provider, provider)
  end

  defp runtime_health_context(config, opts) do
    credential = config_value(config, :credential)
    webhook_secret = config_value(config, :webhook_secret)

    sanitized_config =
      config
      |> Map.delete(:credential)
      |> Map.delete("credential")
      |> Map.delete(:webhook_secret)
      |> Map.delete("webhook_secret")

    runtime_opts =
      opts
      |> maybe_put_runtime_secret(:credential, credential)
      |> maybe_put_runtime_secret(:webhook_secret, webhook_secret)

    runtime_secrets =
      [credential, webhook_secret]
      |> Enum.filter(&present_string?/1)

    {sanitized_config, runtime_opts, runtime_secrets}
  end

  defp maybe_put_runtime_secret(opts, key, value) do
    if present_string?(value), do: Keyword.put(opts, key, value), else: opts
  end

  defp reject_plaintext_result(result, _provider, []), do: result

  defp reject_plaintext_result(result, provider, plaintexts) do
    if Enum.any?(plaintexts, &contains_plaintext?(result, &1)) do
      integration_error(provider, :unsafe_provider_response, "tracker provider returned unsafe data")
    else
      result
    end
  end

  defp contains_plaintext?(value, plaintext) when is_binary(value),
    do: String.contains?(value, plaintext)

  defp contains_plaintext?(value, plaintext) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.any?(&contains_plaintext?(&1, plaintext))
  end

  defp contains_plaintext?(value, plaintext) when is_list(value),
    do: Enum.any?(value, &contains_plaintext?(&1, plaintext))

  defp contains_plaintext?(value, plaintext) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      contains_plaintext?(key, plaintext) or contains_plaintext?(item, plaintext)
    end)
  end

  defp contains_plaintext?(_value, _plaintext), do: false

  defp config_value(config, key, default \\ nil) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp validate_integration_config("fixture", config, _operation, _opts) do
    if is_map(config_value(config, :settings, %{})) do
      {:ok, nil}
    else
      integration_error("fixture", :invalid_config, "tracker integration configuration is invalid")
    end
  end

  defp validate_integration_config(provider, config, operation, opts) do
    settings = config_value(config, :settings, %{})
    reference = credential_reference(operation, config)

    if valid_integration_config?(provider, settings, reference, operation) do
      endpoint = config_value(settings, :endpoint, default_endpoint(provider))

      endpoint_policy(provider, endpoint, opts)
    else
      integration_error(provider, :invalid_config, "tracker integration configuration is invalid")
    end
  end

  defp valid_integration_config?(provider, settings, reference, operation) when is_map(settings) do
    Enum.all?([
      SecretStore.valid_reference_id?(reference),
      valid_scope?(provider, settings),
      valid_actor?(operation, settings)
    ])
  end

  defp valid_integration_config?(_provider, _settings, _reference, _operation), do: false

  defp endpoint_policy(provider, endpoint, opts) do
    policy_opts = [trusted_origins: trusted_origins(provider, opts)]

    policy_opts =
      case Keyword.get(opts, :endpoint_resolver) do
        resolver when is_function(resolver, 1) or is_function(resolver, 2) ->
          Keyword.put(policy_opts, :resolver, resolver)

        _other ->
          policy_opts
      end

    case EndpointPolicy.validate(endpoint, policy_opts) do
      {:ok, policy} -> {:ok, policy}
      {:error, _reason} -> integration_error(provider, :invalid_config, "tracker integration configuration is invalid")
    end
  end

  defp trusted_origins(provider, opts) do
    case Keyword.fetch(opts, :endpoint_trusted_origins) do
      {:ok, origins} ->
        origins

      :error ->
        configured = Config.tracker_trusted_origins()

        case configured do
          origins_by_provider when is_map(origins_by_provider) ->
            Map.get(
              origins_by_provider,
              provider,
              Map.get(origins_by_provider, known_provider_atom(provider), default_trusted_origins(provider))
            )

          _other ->
            default_trusted_origins(provider)
        end
    end
  end

  defp maybe_put_endpoint_policy(opts, nil), do: opts
  defp maybe_put_endpoint_policy(opts, policy), do: Keyword.put(opts, :endpoint_policy, policy)

  defp known_provider_atom("github"), do: :github
  defp known_provider_atom("gitlab"), do: :gitlab
  defp known_provider_atom("linear"), do: :linear

  defp default_trusted_origins("github"), do: ["https://api.github.com"]
  defp default_trusted_origins("gitlab"), do: ["https://gitlab.com"]
  defp default_trusted_origins("linear"), do: ["https://api.linear.app"]

  defp valid_scope?("github", settings) do
    Enum.all?([
      present_string?(config_value(settings, :owner)),
      present_string?(config_value(settings, :repository))
    ])
  end

  defp valid_scope?("gitlab", settings), do: present_string?(config_value(settings, :project_id))
  defp valid_scope?("linear", settings), do: present_string?(config_value(settings, :project_slug))

  defp valid_actor?(operation, settings) when operation in [:upsert_progress, :append_final_summary] do
    present_string?(config_value(settings, :bot_actor_id))
  end

  defp valid_actor?(_operation, _settings), do: true

  defp default_endpoint("github"), do: "https://api.github.com"
  defp default_endpoint("gitlab"), do: "https://gitlab.com/api/v4"
  defp default_endpoint("linear"), do: "https://api.linear.app/graphql"

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
