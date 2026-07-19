defmodule SymphonyRunner.Backend.Fake do
  @moduledoc """
  Deterministic in-memory Runner backend for contract and control-plane tests.
  """

  @behaviour SymphonyRunner.Backend

  alias SymphonyRunner.{Policy, Protocol}

  @impl true
  def init(opts) do
    images = opts |> Keyword.get(:images, ["sha256:abc"]) |> MapSet.new()

    {:ok,
     %{
       images: images,
       sandboxes: %{},
       operations: %{},
       repositories: %{},
       worktrees: %{}
     }}
  end

  @impl true
  def ping(state) do
    {{:ok,
      %{
        ready: true,
        backend: "fake",
        protocol_version: Protocol.version()
      }}, state}
  end

  @impl true
  def inspect_image(state, image_digest) do
    if MapSet.member?(state.images, image_digest) do
      {{:ok, %{image_digest: image_digest, available: true}}, state}
    else
      {{:error, error(:image_not_found, "image digest is not available")}, state}
    end
  end

  @impl true
  def create_sandbox(state, operation_id, unit_id, %Policy{} = policy) do
    replay(state, operation_id, {:create_sandbox, unit_id, policy}, fn ->
      sandbox_id = external_id("sandbox", operation_id)

      result = %{
        sandbox_id: sandbox_id,
        unit_id: unit_id,
        status: "running",
        image_digest: policy.image_digest,
        network: Atom.to_string(policy.network)
      }

      sandboxes = Map.put(state.sandboxes, sandbox_id, result)
      {{:ok, result}, %{state | sandboxes: sandboxes}}
    end)
  end

  @impl true
  def inspect_sandbox(state, sandbox_id) do
    case Map.fetch(state.sandboxes, sandbox_id) do
      {:ok, sandbox} -> {{:ok, sandbox}, state}
      :error -> {{:error, error(:sandbox_not_found, "sandbox is not known")}, state}
    end
  end

  @impl true
  def exec_in_sandbox(state, operation_id, sandbox_id, %Protocol.Exec{} = exec) do
    replay(state, operation_id, {:exec_in_sandbox, sandbox_id, exec}, fn ->
      case Map.fetch(state.sandboxes, sandbox_id) do
        {:ok, %{status: "running"}} ->
          result = %{
            execution_id: external_id("exec", operation_id),
            sandbox_id: sandbox_id,
            exit_code: 0,
            stdout: simulated_stdout(exec.argv, exec.output_limit_bytes),
            stderr: "",
            cwd: exec.cwd
          }

          {{:ok, result}, state}

        {:ok, _sandbox} ->
          {{:error, error(:sandbox_stopped, "sandbox is stopped")}, state}

        :error ->
          {{:error, error(:sandbox_not_found, "sandbox is not known")}, state}
      end
    end)
  end

  @impl true
  def stop_sandbox(state, operation_id, sandbox_id) do
    replay(state, operation_id, {:stop_sandbox, sandbox_id}, fn ->
      case Map.fetch(state.sandboxes, sandbox_id) do
        {:ok, sandbox} ->
          stopped = %{sandbox | status: "stopped"}
          result = %{sandbox_id: sandbox_id, status: "stopped"}
          {{:ok, result}, %{state | sandboxes: Map.put(state.sandboxes, sandbox_id, stopped)}}

        :error ->
          {{:error, error(:sandbox_not_found, "sandbox is not known")}, state}
      end
    end)
  end

  @impl true
  def prepare_repository(state, operation_id, repository) do
    replay(state, operation_id, {:prepare_repository, repository}, fn ->
      repository_id = external_id("repo", operation_id)
      result = %{repository_id: repository_id, repository: repository, status: "prepared"}
      {{:ok, result}, %{state | repositories: Map.put(state.repositories, repository_id, result)}}
    end)
  end

  @impl true
  def create_worktree(state, operation_id, repository, branch) do
    replay(state, operation_id, {:create_worktree, repository, branch}, fn ->
      worktree_id = external_id("worktree", operation_id)

      result = %{
        worktree_id: worktree_id,
        repository: repository,
        branch: branch,
        status: "ready"
      }

      {{:ok, result}, %{state | worktrees: Map.put(state.worktrees, worktree_id, result)}}
    end)
  end

  @impl true
  def merge_branch(state, operation_id, worktree, branch) do
    replay(state, operation_id, {:merge_branch, worktree, branch}, fn ->
      {{:ok, %{worktree: worktree, branch: branch, merged: true}}, state}
    end)
  end

  @impl true
  def cleanup_workspace(state, operation_id, worktree) do
    replay(state, operation_id, {:cleanup_workspace, worktree}, fn ->
      result = %{worktree: worktree, status: "removed"}
      {{:ok, result}, %{state | worktrees: Map.delete(state.worktrees, worktree)}}
    end)
  end

  defp replay(state, operation_id, fingerprint, fun) do
    case Map.fetch(state.operations, operation_id) do
      {:ok, %{fingerprint: ^fingerprint, result: result}} ->
        {result, state}

      {:ok, _operation} ->
        {{:error,
          error(:operation_conflict, "operation ID was already used with different input")},
         state}

      :error ->
        {result, next_state} = fun.()

        operations =
          Map.put(next_state.operations, operation_id, %{
            fingerprint: fingerprint,
            result: result
          })

        {result, %{next_state | operations: operations}}
    end
  end

  defp external_id(prefix, operation_id) do
    hash =
      :crypto.hash(:sha256, operation_id)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    prefix <> "-" <> hash
  end

  defp simulated_stdout(argv, limit) do
    output = "simulated:" <> Enum.join(argv, " ")

    if byte_size(output) > limit do
      binary_part(output, 0, limit)
    else
      output
    end
  end

  defp error(code, message), do: %{code: code, message: message}
end
