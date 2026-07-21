defmodule SymphonyElixir.SourceControl.EffectAdapter do
  @moduledoc """
  Bridges durable Effect Records to Source Control mutations.

  Records contain replay-safe intent and credential references only. An unknown
  GitHub pull-request or GitLab merge-request create remains unknown: Scheme C
  cannot safely establish ownership by listing requests or repeating a create.
  """

  alias SymphonyElixir.Configuration
  alias SymphonyElixir.Effects.Record
  alias SymphonyElixir.Security.CredentialBroker
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.ChangeRequest

  @runtime_keys ~w(
    credential
    credential_ref
    webhook_secret_ref
    transport
    endpoint_resolver
    git_endpoint_resolver
  )
  @supported_actions ~w(
    ensure_remote_branch
    push_branch
    ensure_change_request
    set_draft
    close_or_comment
  )
  @intent_keys %{
    "ensure_remote_branch" => ~w(config branch),
    "push_branch" => ~w(config branch commit_sha expected_remote_sha),
    "ensure_change_request" => ~w(attrs),
    "set_draft" => ~w(config change_request draft),
    "close_or_comment" => ~w(config change_request action body)
  }
  @providers ~w(fixture github gitlab)

  @spec prepare(map()) :: {:ok, map()} | {:error, :invalid_effect}
  def prepare(attrs) when is_map(attrs) do
    with {:ok, action} <- normalize_action(value(attrs, :action)),
         {:ok, intent} <- normalize_intent(action, value(attrs, :intent)),
         {:ok, config} <- config_for(action, intent),
         {:ok, provider} <- provider(config),
         {:ok, target} <- repository(config) do
      {:ok,
       attrs
       |> drop_keys([:provider, "provider", :target, "target", :action, "action", :intent, "intent"])
       |> Map.put(:action, action)
       |> Map.put(:provider, provider)
       |> Map.put(:target, target)
       |> Map.put(:intent, intent)}
    else
      _invalid -> {:error, :invalid_effect}
    end
  end

  def prepare(_attrs), do: {:error, :invalid_effect}

  @spec execute(Record.t()) :: {:ok, map()} | {:error, atom()} | {:unknown, atom()}
  def execute(%Record{} = record) do
    with {:ok, invocation} <- invocation(record) do
      invocation
      |> with_runtime_credential(&dispatch(record, &1))
      |> normalize_execution_result()
    end
  end

  @spec reconcile(Record.t()) :: {:applied, map()} | {:unknown, atom()}
  def reconcile(%Record{action: "ensure_change_request", provider: provider})
      when provider in ["github", "gitlab"],
      do: {:unknown, :change_request_reconciliation_required}

  def reconcile(%Record{provider: "fixture"} = record) do
    case execute(record) do
      {:ok, result} -> {:applied, result}
      {status, reason} when status in [:error, :unknown] -> {:unknown, reason}
    end
  end

  def reconcile(%Record{provider: provider}) when provider in ["github", "gitlab"],
    do: {:unknown, :source_control_reconciliation_required}

  def reconcile(%Record{}), do: {:unknown, :invalid_source_control_effect}

  defp invocation(%Record{action: action, intent: intent} = record) do
    with {:ok, action} <- normalize_action(action),
         {:ok, intent} <- normalize_intent(action, intent),
         {:ok, intent_config} <- config_for(action, intent),
         {:ok, runtime} <- pinned_runtime(record, intent_config),
         :ok <- validate_change_request_identity(action, intent, runtime.config),
         {:ok, intent} <- put_invocation_config(action, intent, runtime.config) do
      {:ok,
       %{
         action: action,
         intent: intent,
         config: runtime.config,
         credential_ref: runtime.credential_ref
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  defp dispatch(record, %{action: "ensure_remote_branch", intent: intent}) do
    source_control().ensure_remote_branch(
      value(intent, :config),
      value(intent, :branch),
      operation_opts(record)
    )
  end

  defp dispatch(record, %{action: "push_branch", intent: intent}) do
    opts =
      record
      |> operation_opts()
      |> Keyword.put(:expected_remote_sha, value(intent, :expected_remote_sha))

    source_control().push_branch(
      value(intent, :config),
      value(intent, :branch),
      value(intent, :commit_sha),
      opts
    )
  end

  defp dispatch(record, %{action: "ensure_change_request", intent: intent}) do
    source_control().ensure_change_request(value(intent, :attrs), operation_opts(record))
  end

  defp dispatch(record, %{action: "set_draft", intent: intent}) do
    with {:ok, change_request} <- change_request(value(intent, :change_request)),
         draft when is_boolean(draft) <- value(intent, :draft) do
      source_control().set_draft(
        value(intent, :config),
        change_request,
        Keyword.put(operation_opts(record), :draft, draft)
      )
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp dispatch(record, %{action: "close_or_comment", intent: intent}) do
    with {:ok, change_request} <- change_request(value(intent, :change_request)),
         {:ok, action} <- close_or_comment_action(value(intent, :action)) do
      opts =
        record
        |> operation_opts()
        |> Keyword.put(:action, action)
        |> maybe_put_body(value(intent, :body))

      source_control().close_or_comment(value(intent, :config), change_request, opts)
    end
  end

  defp with_runtime_credential(
         %{config: config, credential_ref: credential_ref} = invocation,
         fun
       ) do
    case {provider_value(config), credential_ref} do
      {"fixture", _reference} ->
        fun.(invocation)

      {_provider, reference} when is_binary(reference) and byte_size(reference) > 0 ->
        CredentialBroker.with_secret(reference, :source_control_effect, fn credential ->
          invocation
          |> put_invocation_credential(credential)
          |> fun.()
        end)

      {_provider, _missing} ->
        {:error, :missing_credential_reference}
    end
  end

  defp pinned_runtime(%Record{} = record, config) do
    with integration_id when is_binary(integration_id) and byte_size(integration_id) > 0 <-
           value(config, :id),
         {:ok, revision} <- Configuration.pinned_revision_for_task(record.task_id),
         integrations when is_list(integrations) <- value(revision.document, :integrations),
         {:ok, integration} <- unique_integration(integrations, integration_id),
         :ok <- validate_pinned_integration(integration, record),
         runtime_config <- json_value(integration) do
      {:ok,
       %{
         config: runtime_config,
         credential_ref: value(integration, :credential_ref)
       }}
    else
      _invalid -> {:error, :missing_credential_reference}
    end
  rescue
    _exception -> {:error, :missing_credential_reference}
  end

  defp unique_integration(integrations, integration_id) do
    if Enum.all?(integrations, &valid_integration_entry?/1) do
      case Enum.filter(integrations, &(value(&1, :id) == integration_id)) do
        [integration] -> {:ok, integration}
        _missing_or_ambiguous -> {:error, :missing_credential_reference}
      end
    else
      {:error, :missing_credential_reference}
    end
  end

  defp valid_integration_entry?(integration) when is_map(integration) do
    Enum.all?([value(integration, :id), value(integration, :kind)], fn field ->
      is_binary(field) and String.trim(field) != ""
    end) and is_map(value(integration, :settings))
  end

  defp valid_integration_entry?(_integration), do: false

  defp validate_pinned_integration(
         integration,
         %Record{provider: expected_provider, target: expected_target}
       ) do
    with "source_control" <- value(integration, :kind),
         ^expected_provider <- provider_value(integration),
         {:ok, ^expected_target} <- repository(integration) do
      :ok
    else
      _mismatch -> {:error, :missing_credential_reference}
    end
  end

  defp put_invocation_config("ensure_change_request", intent, config) do
    attrs = value(intent, :attrs)
    {:ok, Map.put(intent, "attrs", Map.put(attrs, "repo", config))}
  end

  defp put_invocation_config(_action, intent, config),
    do: {:ok, Map.put(intent, "config", config)}

  defp put_invocation_credential(
         %{action: "ensure_change_request", intent: intent} = invocation,
         credential
       ) do
    attrs = value(intent, :attrs)
    repo = attrs |> value(:repo) |> Map.put("credential", credential)
    updated_attrs = Map.put(attrs, "repo", repo)
    %{invocation | intent: Map.put(intent, "attrs", updated_attrs), config: repo}
  end

  defp put_invocation_credential(%{intent: intent, config: config} = invocation, credential) do
    updated_config = Map.put(config, "credential", credential)
    %{invocation | intent: Map.put(intent, "config", updated_config), config: updated_config}
  end

  defp normalize_execution_result({:ok, result}), do: {:ok, json_value(result)}
  defp normalize_execution_result({:error, :unknown_outcome}), do: {:unknown, :unknown_outcome}
  defp normalize_execution_result({:error, reason}) when is_atom(reason), do: {:error, reason}

  defp operation_opts(%Record{} = record),
    do: [operation_id: record.operation_id, dedupe_key: record.dedupe_hash]

  defp config_for("ensure_change_request", intent) do
    case value(intent, :attrs) do
      attrs when is_map(attrs) -> map_value(attrs, :repo)
      _invalid -> {:error, :invalid_effect}
    end
  end

  defp config_for(_action, intent), do: map_value(intent, :config)

  defp map_value(map, key) when is_map(map) do
    case value(map, key) do
      nested when is_map(nested) -> {:ok, nested}
      _invalid -> {:error, :invalid_effect}
    end
  end

  defp provider(config) do
    case provider_value(config) do
      provider when provider in @providers -> {:ok, provider}
      _invalid -> {:error, :invalid_effect}
    end
  end

  defp provider_value(config) do
    case value(config, :provider) do
      provider when is_binary(provider) -> provider
      _invalid -> nil
    end
  end

  defp repository(config) do
    settings = value(config, :settings)

    case settings && value(settings, :repository) do
      repository when is_binary(repository) ->
        case String.trim(repository) do
          "" -> {:error, :invalid_effect}
          target -> {:ok, target}
        end

      _invalid ->
        {:error, :invalid_effect}
    end
  end

  defp normalize_action(action) when is_atom(action), do: normalize_action(Atom.to_string(action))
  defp normalize_action(action) when action in @supported_actions, do: {:ok, action}
  defp normalize_action(_action), do: {:error, :invalid_effect}

  defp normalize_intent(action, intent) when is_map(intent) do
    {:ok, intent |> json_value() |> Map.take(Map.fetch!(@intent_keys, action))}
  rescue
    _exception -> {:error, :invalid_effect}
  end

  defp normalize_intent(_action, _intent), do: {:error, :invalid_effect}

  defp validate_change_request_identity(action, intent, config)
       when action in ["set_draft", "close_or_comment"] do
    with {:ok, change_request} <- change_request(value(intent, :change_request)),
         {:ok, provider} <- provider(config),
         {:ok, repository} <- repository(config),
         :ok <- exact_match(Atom.to_string(change_request.provider), provider),
         :ok <- exact_match(change_request.repository, repository),
         :ok <- validate_base_branch(change_request, config) do
      :ok
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp validate_change_request_identity(_action, _intent, _config), do: :ok

  defp validate_base_branch(%ChangeRequest{base_branch: base_branch}, config) do
    base =
      config
      |> value(:settings)
      |> value(:base_branch)

    case base do
      expected when is_binary(expected) and expected != "" -> exact_match(base_branch, expected)
      _missing -> :ok
    end
  end

  defp exact_match(value, expected) when is_binary(value) and value == expected, do: :ok
  defp exact_match(_value, _expected), do: {:error, :invalid_configuration}

  defp json_value(%struct{} = value) when is_atom(struct),
    do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, map_value}, normalized ->
      key = json_key(key)

      if key in @runtime_keys,
        do: normalized,
        else: Map.put(normalized, key, json_value(map_value))
    end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp json_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_value(_value),
    do: raise(ArgumentError, "non-persistable source-control effect value")

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(_key), do: raise(ArgumentError, "non-persistable source-control effect key")

  defp change_request(attrs) when is_map(attrs) do
    with {:ok, provider} <- change_request_provider(value(attrs, :provider)),
         external_id when is_binary(external_id) <- value(attrs, :external_id),
         repository when is_binary(repository) <- value(attrs, :repository),
         head_branch when is_binary(head_branch) <- value(attrs, :head_branch),
         base_branch when is_binary(base_branch) <- value(attrs, :base_branch),
         draft when is_boolean(draft) <- draft_value(attrs),
         {:ok, disposition} <- disposition(value(attrs, :disposition)) do
      {:ok,
       %ChangeRequest{
         provider: provider,
         external_id: external_id,
         number: value(attrs, :number),
         url: value(attrs, :url),
         repository: repository,
         head_branch: head_branch,
         base_branch: base_branch,
         title: value(attrs, :title),
         draft?: draft,
         disposition: disposition
       }}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp change_request(_attrs), do: {:error, :invalid_configuration}

  defp change_request_provider("fixture"), do: {:ok, :fixture}
  defp change_request_provider("github"), do: {:ok, :github}
  defp change_request_provider("gitlab"), do: {:ok, :gitlab}
  defp change_request_provider(_provider), do: {:error, :invalid_configuration}

  defp disposition("created"), do: {:ok, :created}
  defp disposition("updated"), do: {:ok, :updated}
  defp disposition("reconciled"), do: {:ok, :reconciled}
  defp disposition(_disposition), do: {:error, :invalid_configuration}

  defp close_or_comment_action("close"), do: {:ok, :close}
  defp close_or_comment_action("comment"), do: {:ok, :comment}
  defp close_or_comment_action(_action), do: {:error, :invalid_configuration}

  defp maybe_put_body(opts, body) when is_binary(body), do: Keyword.put(opts, :body, body)
  defp maybe_put_body(opts, _body), do: opts

  defp draft_value(attrs) do
    if Map.has_key?(attrs, "draft?"), do: Map.get(attrs, "draft?"), else: value(attrs, :draft)
  end

  defp drop_keys(map, keys), do: Enum.reduce(keys, map, &Map.delete(&2, &1))

  defp source_control do
    Application.get_env(:symphony_elixir, :source_control_effect_invoker, SourceControl)
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_map, _key), do: nil
end
