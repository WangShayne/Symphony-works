defmodule SymphonyElixir.Runner do
  @moduledoc """
  Control-plane adapter for the host-local Runner service.
  """

  alias SymphonyRunner.{Policy, Protocol}

  @server_name __MODULE__.Server

  @type result :: {:ok, map()} | {:error, Protocol.error()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = Keyword.put_new(opts, :name, @server_name)
    SymphonyRunner.Server.child_spec(opts)
  end

  @spec server_name() :: atom()
  def server_name, do: @server_name

  @spec ping() :: result()
  def ping, do: SymphonyRunner.ping(@server_name)

  @spec inspect_image(String.t()) :: result()
  def inspect_image(image_digest), do: SymphonyRunner.inspect_image(@server_name, image_digest)

  @spec create_sandbox(String.t(), String.t(), Policy.t()) :: result()
  def create_sandbox(operation_id, unit_id, %Policy{} = policy) do
    SymphonyRunner.create_sandbox(@server_name, operation_id, unit_id, policy)
  end

  @spec inspect_sandbox(String.t()) :: result()
  def inspect_sandbox(sandbox_id), do: SymphonyRunner.inspect_sandbox(@server_name, sandbox_id)

  @spec exec_in_sandbox(String.t(), String.t(), Protocol.Exec.t()) :: result()
  def exec_in_sandbox(operation_id, sandbox_id, %Protocol.Exec{} = exec) do
    SymphonyRunner.exec_in_sandbox(@server_name, operation_id, sandbox_id, exec)
  end

  @spec stop_sandbox(String.t(), String.t()) :: result()
  def stop_sandbox(operation_id, sandbox_id) do
    SymphonyRunner.stop_sandbox(@server_name, operation_id, sandbox_id)
  end
end
