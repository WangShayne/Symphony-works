defmodule SymphonyRunner.Server do
  @moduledoc """
  GenServer facade that dispatches validated Runner protocol requests to a backend.
  """

  use GenServer

  require Logger

  alias SymphonyRunner.Protocol

  @type option :: {:name, GenServer.name()} | {:backend, module()} | {:backend_opts, keyword()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec call(GenServer.server(), Protocol.request()) :: {:ok, map()} | {:error, Protocol.error()}
  def call(server, %Protocol.Request{} = request), do: GenServer.call(server, request)

  @impl true
  def init(opts) do
    backend =
      Keyword.get(
        opts,
        :backend,
        Application.get_env(:symphony_runner, :backend, SymphonyRunner.Backend.Fake)
      )

    backend_opts = Keyword.get(opts, :backend_opts, [])
    {:ok, backend_state} = backend.init(backend_opts)
    {:ok, %{backend: backend, backend_state: backend_state}}
  end

  @impl true
  def handle_call(%Protocol.Request{} = request, _from, state) do
    case Protocol.validate_request(request) do
      :ok ->
        {reply, backend_state} = dispatch(request, state.backend, state.backend_state)
        log_dispatch(request, reply)
        {:reply, reply, %{state | backend_state: backend_state}}

      {:error, error} ->
        log_dispatch(request, {:error, error})
        {:reply, {:error, error}, state}
    end
  end

  defp dispatch(%Protocol.Request{operation: :ping}, backend, backend_state),
    do: backend.ping(backend_state)

  defp dispatch(
         %Protocol.Request{operation: :inspect_image, image_digest: digest},
         backend,
         state
       ),
       do: backend.inspect_image(state, digest)

  defp dispatch(
         %Protocol.Request{
           operation: :create_sandbox,
           operation_id: operation_id,
           unit_id: unit_id,
           policy: policy
         },
         backend,
         state
       ),
       do: backend.create_sandbox(state, operation_id, unit_id, policy)

  defp dispatch(
         %Protocol.Request{operation: :inspect_sandbox, sandbox_id: sandbox_id},
         backend,
         state
       ),
       do: backend.inspect_sandbox(state, sandbox_id)

  defp dispatch(
         %Protocol.Request{
           operation: :exec_in_sandbox,
           operation_id: operation_id,
           sandbox_id: sandbox_id,
           exec: exec
         },
         backend,
         state
       ),
       do: backend.exec_in_sandbox(state, operation_id, sandbox_id, exec)

  defp dispatch(
         %Protocol.Request{
           operation: :stop_sandbox,
           operation_id: operation_id,
           sandbox_id: sandbox_id
         },
         backend,
         state
       ),
       do: backend.stop_sandbox(state, operation_id, sandbox_id)

  defp dispatch(
         %Protocol.Request{
           operation: :prepare_repository,
           operation_id: operation_id,
           repository: repository
         },
         backend,
         state
       ),
       do: backend.prepare_repository(state, operation_id, repository)

  defp dispatch(
         %Protocol.Request{
           operation: :create_worktree,
           operation_id: operation_id,
           repository: repository,
           branch: branch
         },
         backend,
         state
       ),
       do: backend.create_worktree(state, operation_id, repository, branch)

  defp dispatch(
         %Protocol.Request{
           operation: :merge_branch,
           operation_id: operation_id,
           worktree: worktree,
           branch: branch
         },
         backend,
         state
       ),
       do: backend.merge_branch(state, operation_id, worktree, branch)

  defp dispatch(
         %Protocol.Request{
           operation: :cleanup_workspace,
           operation_id: operation_id,
           worktree: worktree
         },
         backend,
         state
       ),
       do: backend.cleanup_workspace(state, operation_id, worktree)

  defp log_dispatch(%Protocol.Request{} = request, {:ok, _result}) do
    Logger.info("runner operation completed",
      runner_operation: request.operation,
      runner_operation_id: request.operation_id,
      runner_outcome: :ok
    )
  end

  defp log_dispatch(%Protocol.Request{} = request, {:error, error}) do
    Logger.warning("runner operation failed",
      runner_operation: request.operation,
      runner_operation_id: request.operation_id,
      runner_outcome: :error,
      runner_error_code: error.code
    )
  end
end
