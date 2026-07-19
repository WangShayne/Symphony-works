defmodule SymphonyRunner do
  @moduledoc """
  Narrow Runner boundary for policy-bounded execution sandbox operations.
  """

  alias SymphonyRunner.{Policy, Protocol, Server}

  @type server :: GenServer.server()

  @spec ping(server()) :: {:ok, map()} | {:error, Protocol.error()}
  def ping(server \\ Server), do: Server.call(server, Protocol.ping())

  @spec inspect_image(server(), String.t()) :: {:ok, map()} | {:error, Protocol.error()}
  def inspect_image(server \\ Server, image_digest),
    do: Server.call(server, Protocol.inspect_image(image_digest))

  @spec create_sandbox(server(), String.t(), String.t(), Policy.t()) ::
          {:ok, map()} | {:error, Protocol.error()}
  def create_sandbox(server \\ Server, operation_id, unit_id, %Policy{} = policy),
    do: Server.call(server, Protocol.create_sandbox(operation_id, unit_id, policy))

  @spec inspect_sandbox(server(), String.t()) :: {:ok, map()} | {:error, Protocol.error()}
  def inspect_sandbox(server \\ Server, sandbox_id),
    do: Server.call(server, Protocol.inspect_sandbox(sandbox_id))

  @spec exec_in_sandbox(server(), String.t(), String.t(), Protocol.Exec.t()) ::
          {:ok, map()} | {:error, Protocol.error()}
  def exec_in_sandbox(server \\ Server, operation_id, sandbox_id, %Protocol.Exec{} = exec),
    do: Server.call(server, Protocol.exec_in_sandbox(operation_id, sandbox_id, exec))

  @spec stop_sandbox(server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Protocol.error()}
  def stop_sandbox(server \\ Server, operation_id, sandbox_id),
    do: Server.call(server, Protocol.stop_sandbox(operation_id, sandbox_id))
end
