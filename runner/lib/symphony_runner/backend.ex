defmodule SymphonyRunner.Backend do
  @moduledoc """
  Behaviour for Runner backends.
  """

  alias SymphonyRunner.{Policy, Protocol}

  @type state :: term()
  @type result :: {:ok, map()} | {:error, Protocol.error()}

  @callback init(keyword()) :: {:ok, state()}
  @callback ping(state()) :: {result(), state()}
  @callback inspect_image(state(), String.t()) :: {result(), state()}
  @callback create_sandbox(state(), String.t(), String.t(), Policy.t()) :: {result(), state()}
  @callback inspect_sandbox(state(), String.t()) :: {result(), state()}
  @callback exec_in_sandbox(state(), String.t(), String.t(), Protocol.Exec.t()) ::
              {result(), state()}
  @callback stop_sandbox(state(), String.t(), String.t()) :: {result(), state()}
  @callback prepare_repository(state(), String.t(), String.t()) :: {result(), state()}
  @callback create_worktree(state(), String.t(), String.t(), String.t()) :: {result(), state()}
  @callback merge_branch(state(), String.t(), String.t(), String.t()) :: {result(), state()}
  @callback cleanup_workspace(state(), String.t(), String.t()) :: {result(), state()}
end
