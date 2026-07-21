defmodule SymphonyElixir.SourceControl do
  @moduledoc """
  Provider-neutral boundary for repository and Change Request operations.

  Persisted configuration contains only `provider`, `credential_ref`, and
  provider `settings`. A caller may add an ephemeral `credential` or
  `transport` while executing an operation; adapters must never return either.
  """

  alias SymphonyElixir.SourceControl.{Fake, GitHub, GitLab, Transport}

  @type config :: term()
  @type mutation_opts :: term()
  @type result(value) :: {:ok, value} | {:error, term()}

  @callback health_check(config()) :: result(map())
  @callback resolve_baseline(config(), term()) ::
              result(SymphonyElixir.SourceControl.Baseline.t())
  @callback ensure_remote_branch(config(), term(), mutation_opts()) ::
              result(SymphonyElixir.SourceControl.Branch.t())
  @callback push_branch(config(), term(), term(), mutation_opts()) ::
              result(SymphonyElixir.SourceControl.Branch.t())
  @callback ensure_change_request(term(), mutation_opts()) ::
              result(SymphonyElixir.SourceControl.ChangeRequest.t())
  @callback state(config(), term()) ::
              result(SymphonyElixir.SourceControl.ChangeRequest.State.t())
  @callback set_draft(
              config(),
              term(),
              mutation_opts()
            ) :: result(SymphonyElixir.SourceControl.ChangeRequest.t())
  @callback close_or_comment(
              config(),
              term(),
              mutation_opts()
            ) :: result(map())

  @spec health_check(config()) :: result(map())
  def health_check(config) when is_map(config) do
    dispatch(config, :health_check, [config], :health_check_failed)
  end

  @spec resolve_baseline(config(), String.t()) ::
          result(SymphonyElixir.SourceControl.Baseline.t())
  def resolve_baseline(config, branch) when is_map(config) and is_binary(branch) do
    dispatch(config, :resolve_baseline, [config, branch], :resolve_baseline_failed)
  end

  @spec ensure_remote_branch(config(), map(), mutation_opts()) ::
          result(SymphonyElixir.SourceControl.Branch.t())
  def ensure_remote_branch(config, branch, opts)
      when is_map(config) and is_map(branch) and is_list(opts) do
    with :ok <- validate_operation(opts) do
      dispatch(config, :ensure_remote_branch, [config, branch, opts], :ensure_remote_branch_failed)
    end
  end

  @spec push_branch(config(), String.t(), String.t(), mutation_opts()) ::
          result(SymphonyElixir.SourceControl.Branch.t())
  def push_branch(config, branch, commit_sha, opts)
      when is_map(config) and is_binary(branch) and is_binary(commit_sha) and is_list(opts) do
    with :ok <- validate_operation(opts),
         expected_sha when is_binary(expected_sha) <- Keyword.get(opts, :expected_remote_sha),
         true <- String.trim(expected_sha) != "" do
      dispatch(config, :push_branch, [config, branch, commit_sha, opts], :push_branch_failed)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @spec ensure_change_request(map(), mutation_opts()) ::
          result(SymphonyElixir.SourceControl.ChangeRequest.t())
  def ensure_change_request(attrs, opts) when is_map(attrs) and is_list(opts) do
    with :ok <- validate_operation(opts),
         repo when is_map(repo) <- value(attrs, :repo) do
      dispatch(repo, :ensure_change_request, [attrs, opts], :ensure_change_request_failed)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @spec state(config(), SymphonyElixir.SourceControl.ChangeRequest.t()) ::
          result(SymphonyElixir.SourceControl.ChangeRequest.State.t())
  def state(config, %SymphonyElixir.SourceControl.ChangeRequest{} = change_request)
      when is_map(config) do
    dispatch(config, :state, [config, change_request], :state_failed)
  end

  @spec set_draft(
          config(),
          SymphonyElixir.SourceControl.ChangeRequest.t(),
          mutation_opts()
        ) :: result(SymphonyElixir.SourceControl.ChangeRequest.t())
  def set_draft(config, %SymphonyElixir.SourceControl.ChangeRequest{} = change_request, opts)
      when is_map(config) and is_list(opts) do
    with :ok <- validate_operation(opts),
         draft when is_boolean(draft) <- Keyword.get(opts, :draft) do
      dispatch(config, :set_draft, [config, change_request, opts], :set_draft_failed)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @spec close_or_comment(
          config(),
          SymphonyElixir.SourceControl.ChangeRequest.t(),
          mutation_opts()
        ) :: result(map())
  def close_or_comment(
        config,
        %SymphonyElixir.SourceControl.ChangeRequest{} = change_request,
        opts
      )
      when is_map(config) and is_list(opts) do
    with :ok <- validate_operation(opts),
         :ok <- validate_close_or_comment(opts) do
      dispatch(
        config,
        :close_or_comment,
        [config, change_request, opts],
        :close_or_comment_failed
      )
    end
  end

  defp dispatch(config, function, args, failure) do
    credential = value(config, :credential)
    sanitized_args = Enum.map(args, &strip_runtime_credential/1)

    with {:ok, adapter} <- adapter_for(config) do
      invoke_adapter(adapter, function, sanitized_args, failure, credential)
    end
  end

  defp invoke_adapter(adapter, function, args, failure, credential) do
    Transport.with_credential(credential, fn -> safe_apply(adapter, function, args, failure) end)
  end

  defp safe_apply(adapter, function, args, failure) do
    safe_boundary(fn -> apply(adapter, function, args) end, failure)
  end

  defp adapter_for(config) do
    case value(config, :provider) do
      :fixture -> {:ok, Fake}
      "fixture" -> {:ok, Fake}
      :github -> {:ok, GitHub}
      "github" -> {:ok, GitHub}
      :gitlab -> {:ok, GitLab}
      "gitlab" -> {:ok, GitLab}
      _other -> {:error, :unsupported_provider}
    end
  end

  defp safe_boundary(fun, failure) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, sanitize_reason(reason, failure)}
    end
  rescue
    _exception -> {:error, failure}
  catch
    _kind, _reason -> {:error, failure}
  end

  defp sanitize_reason(reason, _failure)
       when reason in [
              :invalid_configuration,
              :missing_operation_identity,
              :not_found,
              :unauthorized,
              :forbidden,
              :conflict,
              :idempotency_conflict,
              :ambiguous_external_state,
              :unknown_outcome,
              :rate_limited,
              :transport_failure,
              :provider_failure,
              :unsupported_operation,
              :unsupported_provider
            ],
       do: reason

  defp sanitize_reason({:rate_limited, seconds}, _failure)
       when is_integer(seconds) and seconds >= 0,
       do: {:rate_limited, seconds}

  defp validate_operation(opts) do
    operation_id = Keyword.get(opts, :operation_id)
    dedupe_key = Keyword.get(opts, :dedupe_key)

    if nonempty_string?(operation_id) and nonempty_string?(dedupe_key) do
      :ok
    else
      {:error, :missing_operation_identity}
    end
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_close_or_comment(opts) do
    case Keyword.get(opts, :action) do
      :close -> :ok
      :comment -> if(nonempty_string?(Keyword.get(opts, :body)), do: :ok, else: {:error, :invalid_configuration})
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp strip_runtime_credential(%_{} = struct), do: struct

  defp strip_runtime_credential(map) when is_map(map) do
    map
    |> Map.delete(:credential)
    |> Map.delete("credential")
    |> Map.new(fn {key, value} -> {key, strip_runtime_credential(value)} end)
  end

  defp strip_runtime_credential(list) when is_list(list),
    do: Enum.map(list, &strip_runtime_credential/1)

  defp strip_runtime_credential(value), do: value
end
