defmodule SymphonyRunner.Protocol do
  @moduledoc """
  Versioned request and response codec for the Runner interface.
  """

  alias SymphonyRunner.{PathPolicy, Policy}

  @version 1
  @operations [
    :ping,
    :inspect_image,
    :create_sandbox,
    :inspect_sandbox,
    :exec_in_sandbox,
    :stop_sandbox,
    :prepare_repository,
    :create_worktree,
    :merge_branch,
    :cleanup_workspace
  ]
  @mutations [
    :create_sandbox,
    :exec_in_sandbox,
    :stop_sandbox,
    :prepare_repository,
    :create_worktree,
    :merge_branch,
    :cleanup_workspace
  ]

  defmodule Request do
    @moduledoc false
    defstruct [
      :version,
      :operation,
      :operation_id,
      :unit_id,
      :image_digest,
      :policy,
      :sandbox_id,
      :exec,
      :repository,
      :worktree,
      :branch
    ]
  end

  defmodule Response do
    @moduledoc false
    defstruct [:version, :operation_id, :ok, :result, :error]
  end

  defmodule Exec do
    @moduledoc """
    Structured sandbox execution request.
    """

    @enforce_keys [:argv, :cwd, :env_secret_refs, :timeout_ms, :output_limit_bytes]
    defstruct [:argv, :cwd, :env_secret_refs, :timeout_ms, :output_limit_bytes]

    @type t :: %__MODULE__{
            argv: [String.t()],
            cwd: String.t(),
            env_secret_refs: %{String.t() => String.t()},
            timeout_ms: pos_integer(),
            output_limit_bytes: pos_integer()
          }
  end

  @type request :: %Request{}
  @type response :: %Response{}
  @type error :: %{code: atom(), message: String.t()}

  @spec version() :: 1
  def version, do: @version

  @spec ping() :: request()
  def ping, do: %Request{version: @version, operation: :ping}

  @spec inspect_image(String.t()) :: request()
  def inspect_image(image_digest),
    do: %Request{version: @version, operation: :inspect_image, image_digest: image_digest}

  @spec create_sandbox(String.t(), String.t(), Policy.t()) :: request()
  def create_sandbox(operation_id, unit_id, %Policy{} = policy) do
    %Request{
      version: @version,
      operation: :create_sandbox,
      operation_id: operation_id,
      unit_id: unit_id,
      policy: policy
    }
  end

  @spec inspect_sandbox(String.t()) :: request()
  def inspect_sandbox(sandbox_id),
    do: %Request{version: @version, operation: :inspect_sandbox, sandbox_id: sandbox_id}

  @spec exec_in_sandbox(String.t(), String.t(), Exec.t()) :: request()
  def exec_in_sandbox(operation_id, sandbox_id, %Exec{} = exec) do
    %Request{
      version: @version,
      operation: :exec_in_sandbox,
      operation_id: operation_id,
      sandbox_id: sandbox_id,
      exec: exec
    }
  end

  @spec stop_sandbox(String.t(), String.t()) :: request()
  def stop_sandbox(operation_id, sandbox_id) do
    %Request{
      version: @version,
      operation: :stop_sandbox,
      operation_id: operation_id,
      sandbox_id: sandbox_id
    }
  end

  @spec prepare_repository(String.t(), String.t()) :: request()
  def prepare_repository(operation_id, repository) do
    %Request{
      version: @version,
      operation: :prepare_repository,
      operation_id: operation_id,
      repository: repository
    }
  end

  @spec create_worktree(String.t(), String.t(), String.t()) :: request()
  def create_worktree(operation_id, repository, branch) do
    %Request{
      version: @version,
      operation: :create_worktree,
      operation_id: operation_id,
      repository: repository,
      branch: branch
    }
  end

  @spec merge_branch(String.t(), String.t(), String.t()) :: request()
  def merge_branch(operation_id, worktree, branch) do
    %Request{
      version: @version,
      operation: :merge_branch,
      operation_id: operation_id,
      worktree: worktree,
      branch: branch
    }
  end

  @spec cleanup_workspace(String.t(), String.t()) :: request()
  def cleanup_workspace(operation_id, worktree) do
    %Request{
      version: @version,
      operation: :cleanup_workspace,
      operation_id: operation_id,
      worktree: worktree
    }
  end

  @spec ok(String.t() | nil, map()) :: response()
  def ok(operation_id, result) when is_map(result) do
    %Response{version: @version, operation_id: operation_id, ok: true, result: result}
  end

  @spec error(String.t() | nil, atom(), String.t()) :: response()
  def error(operation_id, code, message) when is_atom(code) and is_binary(message) do
    %Response{
      version: @version,
      operation_id: operation_id,
      ok: false,
      error: %{code: code, message: message}
    }
  end

  @spec encode(request() | response()) :: binary()
  def encode(%Request{} = request), do: request |> request_to_wire() |> encode_wire()
  def encode(%Response{} = response), do: response |> response_to_wire() |> encode_wire()

  @spec decode_request(binary()) :: {:ok, request()} | {:error, error()}
  def decode_request(payload) when is_binary(payload) do
    with {:ok, wire} <- decode_wire(payload),
         {:ok, request} <- request_from_wire(wire),
         :ok <- validate_request(request) do
      {:ok, request}
    end
  end

  def decode_request(_payload), do: protocol_error(:invalid_payload)

  @spec decode_response(binary()) :: {:ok, response()} | {:error, error()}
  def decode_response(payload) when is_binary(payload) do
    with {:ok, wire} <- decode_wire(payload),
         {:ok, response} <- response_from_wire(wire) do
      {:ok, response}
    end
  end

  def decode_response(_payload), do: protocol_error(:invalid_payload)

  @spec validate_request(request()) :: :ok | {:error, error()}
  def validate_request(%Request{version: @version, operation: operation} = request)
      when operation in @operations do
    with :ok <- validate_operation_id(request),
         :ok <- validate_operation_fields(request),
         :ok <- validate_policy(request),
         :ok <- validate_exec(request) do
      :ok
    end
  end

  def validate_request(%Request{}), do: protocol_error(:unsupported_version_or_operation)
  def validate_request(_request), do: protocol_error(:invalid_request)

  @spec mutation?(atom()) :: boolean()
  def mutation?(operation), do: operation in @mutations

  defp encode_wire(wire), do: :erlang.term_to_binary(wire, [:deterministic])

  defp decode_wire(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    ArgumentError -> protocol_error(:invalid_payload)
  end

  defp request_to_wire(%Request{} = request) do
    %{
      "type" => "request",
      "version" => request.version,
      "operation" => Atom.to_string(request.operation),
      "operation_id" => request.operation_id,
      "unit_id" => request.unit_id,
      "image_digest" => request.image_digest,
      "policy" => encode_policy(request.policy),
      "sandbox_id" => request.sandbox_id,
      "exec" => encode_exec(request.exec),
      "repository" => request.repository,
      "worktree" => request.worktree,
      "branch" => request.branch
    }
  end

  defp response_to_wire(%Response{} = response) do
    %{
      "type" => "response",
      "version" => response.version,
      "operation_id" => response.operation_id,
      "ok" => response.ok,
      "result" => response.result,
      "error" => encode_error(response.error)
    }
  end

  defp request_from_wire(
         %{"type" => "request", "version" => @version, "operation" => operation} = wire
       ) do
    with {:ok, parsed_operation} <- parse_operation(operation),
         {:ok, policy} <- decode_policy(Map.get(wire, "policy")),
         {:ok, exec} <- decode_exec(Map.get(wire, "exec")) do
      {:ok,
       %Request{
         version: @version,
         operation: parsed_operation,
         operation_id: Map.get(wire, "operation_id"),
         unit_id: Map.get(wire, "unit_id"),
         image_digest: Map.get(wire, "image_digest"),
         policy: policy,
         sandbox_id: Map.get(wire, "sandbox_id"),
         exec: exec,
         repository: Map.get(wire, "repository"),
         worktree: Map.get(wire, "worktree"),
         branch: Map.get(wire, "branch")
       }}
    end
  end

  defp request_from_wire(_wire), do: protocol_error(:invalid_request)

  defp response_from_wire(%{
         "type" => "response",
         "version" => @version,
         "operation_id" => operation_id,
         "ok" => true,
         "result" => result
       })
       when is_map(result) do
    {:ok, %Response{version: @version, operation_id: operation_id, ok: true, result: result}}
  end

  defp response_from_wire(%{
         "type" => "response",
         "version" => @version,
         "operation_id" => operation_id,
         "ok" => false,
         "error" => %{"code" => code, "message" => message}
       })
       when is_binary(code) and is_binary(message) do
    {:ok,
     %Response{
       version: @version,
       operation_id: operation_id,
       ok: false,
       error: %{code: String.to_atom(code), message: message}
     }}
  end

  defp response_from_wire(_wire), do: protocol_error(:invalid_response)

  defp validate_operation_id(%Request{operation: operation, operation_id: operation_id})
       when operation in @mutations do
    if valid_id?(operation_id), do: :ok, else: protocol_error(:invalid_operation_id)
  end

  defp validate_operation_id(%Request{}), do: :ok

  defp validate_operation_fields(%Request{operation: :ping}), do: :ok

  defp validate_operation_fields(%Request{operation: :inspect_image, image_digest: digest}) do
    if is_binary(digest), do: :ok, else: protocol_error(:invalid_image_digest)
  end

  defp validate_operation_fields(%Request{operation: :create_sandbox, unit_id: unit_id}) do
    if valid_id?(unit_id), do: :ok, else: protocol_error(:invalid_unit_id)
  end

  defp validate_operation_fields(%Request{operation: :inspect_sandbox, sandbox_id: sandbox_id}) do
    if valid_id?(sandbox_id), do: :ok, else: protocol_error(:invalid_sandbox_id)
  end

  defp validate_operation_fields(%Request{operation: operation, sandbox_id: sandbox_id})
       when operation in [:exec_in_sandbox, :stop_sandbox] do
    if valid_id?(sandbox_id), do: :ok, else: protocol_error(:invalid_sandbox_id)
  end

  defp validate_operation_fields(%Request{operation: operation, repository: repository})
       when operation in [:prepare_repository, :create_worktree] do
    if is_binary(repository) and repository != "",
      do: :ok,
      else: protocol_error(:invalid_repository)
  end

  defp validate_operation_fields(%Request{operation: :merge_branch, worktree: worktree}) do
    if is_binary(worktree) and worktree != "", do: :ok, else: protocol_error(:invalid_worktree)
  end

  defp validate_operation_fields(%Request{operation: :cleanup_workspace, worktree: worktree}) do
    if is_binary(worktree) and worktree != "", do: :ok, else: protocol_error(:invalid_worktree)
  end

  defp validate_policy(%Request{operation: :create_sandbox, policy: %Policy{} = policy}) do
    case Policy.validate(policy) do
      :ok -> :ok
      {:error, reason} -> protocol_error(reason)
    end
  end

  defp validate_policy(%Request{operation: :create_sandbox}), do: protocol_error(:invalid_policy)
  defp validate_policy(%Request{}), do: :ok

  defp validate_exec(%Request{operation: :exec_in_sandbox, exec: %Exec{} = exec}) do
    cond do
      not valid_argv?(exec.argv) ->
        protocol_error(:invalid_argv)

      not PathPolicy.workspace_path?(exec.cwd) ->
        protocol_error(:invalid_cwd)

      not valid_secret_refs?(exec.env_secret_refs) ->
        protocol_error(:invalid_env_secret_refs)

      not (is_integer(exec.timeout_ms) and exec.timeout_ms in 1..300_000) ->
        protocol_error(:invalid_timeout_ms)

      not (is_integer(exec.output_limit_bytes) and exec.output_limit_bytes in 1..1_048_576) ->
        protocol_error(:invalid_output_limit_bytes)

      true ->
        :ok
    end
  end

  defp validate_exec(%Request{operation: :exec_in_sandbox}), do: protocol_error(:invalid_exec)
  defp validate_exec(%Request{}), do: :ok

  defp valid_argv?([_ | _] = argv), do: Enum.all?(argv, &(is_binary(&1) and &1 != ""))
  defp valid_argv?(_argv), do: false

  defp valid_secret_refs?(refs) when is_map(refs) do
    Enum.all?(refs, fn
      {name, "secret:" <> ref} -> env_name?(name) and ref != ""
      _entry -> false
    end)
  end

  defp valid_secret_refs?(_refs), do: false

  defp env_name?(name) when is_binary(name), do: String.match?(name, ~r/^[A-Z][A-Z0-9_]*$/)
  defp env_name?(_name), do: false

  defp encode_policy(nil), do: nil
  defp encode_policy(%Policy{} = policy), do: Policy.to_wire(policy)

  defp decode_policy(nil), do: {:ok, nil}

  defp decode_policy(wire) do
    case Policy.from_wire(wire) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> protocol_error(reason)
    end
  end

  defp encode_exec(nil), do: nil

  defp encode_exec(%Exec{} = exec) do
    %{
      "argv" => exec.argv,
      "cwd" => exec.cwd,
      "env_secret_refs" => exec.env_secret_refs,
      "timeout_ms" => exec.timeout_ms,
      "output_limit_bytes" => exec.output_limit_bytes
    }
  end

  defp decode_exec(nil), do: {:ok, nil}

  defp decode_exec(%{
         "argv" => argv,
         "cwd" => cwd,
         "env_secret_refs" => env_secret_refs,
         "timeout_ms" => timeout_ms,
         "output_limit_bytes" => output_limit_bytes
       }) do
    {:ok,
     %Exec{
       argv: argv,
       cwd: cwd,
       env_secret_refs: env_secret_refs,
       timeout_ms: timeout_ms,
       output_limit_bytes: output_limit_bytes
     }}
  end

  defp decode_exec(_exec), do: protocol_error(:invalid_exec)

  defp encode_error(nil), do: nil

  defp encode_error(%{code: code, message: message}) do
    %{"code" => Atom.to_string(code), "message" => message}
  end

  defp parse_operation(operation) when is_binary(operation) do
    parsed = String.to_existing_atom(operation)

    if parsed in @operations, do: {:ok, parsed}, else: protocol_error(:unsupported_operation)
  rescue
    ArgumentError -> protocol_error(:unsupported_operation)
  end

  defp parse_operation(_operation), do: protocol_error(:unsupported_operation)

  defp valid_id?(id) when is_binary(id), do: String.match?(id, ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/)
  defp valid_id?(_id), do: false

  defp protocol_error(code), do: {:error, %{code: code, message: message(code)}}

  defp message(:invalid_payload), do: "payload is not a valid Runner protocol frame"
  defp message(:invalid_request), do: "request frame is invalid"
  defp message(:invalid_response), do: "response frame is invalid"

  defp message(:unsupported_version_or_operation),
    do: "protocol version or operation is unsupported"

  defp message(:unsupported_operation), do: "operation is unsupported"
  defp message(:invalid_operation_id), do: "mutation requests require a valid operation ID"
  defp message(:invalid_unit_id), do: "unit ID is invalid"
  defp message(:invalid_sandbox_id), do: "sandbox ID is invalid"
  defp message(:invalid_image_digest), do: "image digest is invalid"
  defp message(:invalid_policy), do: "sandbox policy is invalid"
  defp message(:invalid_cpu_millis), do: "CPU limit is outside allowed bounds"
  defp message(:invalid_memory_bytes), do: "memory limit is outside allowed bounds"
  defp message(:invalid_network), do: "network policy is invalid"
  defp message(:invalid_mounts), do: "mount policy is invalid"
  defp message(:invalid_mount), do: "mount policy entry is invalid"
  defp message(:invalid_mount_source), do: "mount source is invalid"
  defp message(:invalid_mount_target), do: "mount target must stay under /workspace"
  defp message(:invalid_mount_mode), do: "mount mode is invalid"
  defp message(:invalid_exec), do: "sandbox exec request is invalid"
  defp message(:invalid_argv), do: "sandbox exec requires argv"
  defp message(:invalid_cwd), do: "sandbox exec cwd must stay under /workspace"

  defp message(:invalid_env_secret_refs),
    do: "sandbox exec env must contain only secret references"

  defp message(:invalid_timeout_ms), do: "sandbox exec timeout is outside allowed bounds"

  defp message(:invalid_output_limit_bytes),
    do: "sandbox exec output limit is outside allowed bounds"

  defp message(:invalid_repository), do: "repository value is invalid"
  defp message(:invalid_worktree), do: "worktree value is invalid"
end
