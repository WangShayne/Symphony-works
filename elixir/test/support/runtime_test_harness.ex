defmodule SymphonyElixir.RuntimeTestHarness do
  @moduledoc false

  alias SymphonyElixir.AgentRuntimeSupervisor

  @parent SymphonyElixir.Supervisor

  defmodule Lease do
    @moduledoc false

    @enforce_keys [:initial_state]
    defstruct [:initial_state]

    @type t :: %__MODULE__{initial_state: :running | :stopped}
  end

  defmacro __using__(opts) do
    unless Keyword.get(opts, :async) == false do
      raise ArgumentError, "RuntimeTestHarness requires async: false"
    end

    quote do
      @before_compile SymphonyElixir.RuntimeTestHarness

      setup do
        lease = SymphonyElixir.RuntimeTestHarness.acquire!()
        on_exit(fn -> SymphonyElixir.RuntimeTestHarness.restore!(lease) end)
        {:ok, runtime_harness: lease}
      end
    end
  end

  defmacro __before_compile__(%{module: module}) do
    ex_unit_opts = Module.get_attribute(module, :ex_unit_module, [])

    unless Module.has_attribute?(module, :ex_unit_tests) and
             Keyword.get(ex_unit_opts, :async, false) == false do
      raise ArgumentError,
            "RuntimeTestHarness must be used with an ExUnit case configured with async: false"
    end

    quote do
    end
  end

  @spec acquire!() :: Lease.t()
  def acquire!, do: %Lease{initial_state: default_runtime_state()}

  @spec restore!(Lease.t()) :: :ok
  def restore!(%Lease{initial_state: :running}), do: restart_default_runtime()
  def restore!(%Lease{initial_state: :stopped}), do: stop_default_runtime()

  @spec stop_default_runtime!(Lease.t()) :: :ok
  def stop_default_runtime!(%Lease{}), do: stop_default_runtime()

  @spec restart_default_runtime!(Lease.t()) :: :ok
  def restart_default_runtime!(%Lease{}), do: restart_default_runtime()

  defp stop_default_runtime do
    case default_runtime_child_pid() do
      nil ->
        :ok

      _pid ->
        case Supervisor.terminate_child(@parent, AgentRuntimeSupervisor) do
          :ok -> :ok
          {:error, reason} -> raise "failed to stop the default agent runtime: #{inspect(reason)}"
        end
    end
  end

  defp restart_default_runtime do
    case default_runtime_child_pid() do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(@parent, AgentRuntimeSupervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to restart the default agent runtime: #{inspect(reason)}"
        end
    end
  end

  defp default_runtime_state do
    if default_runtime_child_pid(), do: :running, else: :stopped
  end

  defp default_runtime_child_pid do
    @parent
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {AgentRuntimeSupervisor, pid, _type, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  end
end
