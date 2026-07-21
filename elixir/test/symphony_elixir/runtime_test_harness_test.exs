defmodule SymphonyElixir.RuntimeTestHarnessTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRuntimeSupervisor, RuntimeTestHarness}

  defmodule StopFailureSupervisor do
    @moduledoc false

    def which_children(SymphonyElixir.Supervisor) do
      [{AgentRuntimeSupervisor, self(), :supervisor, [AgentRuntimeSupervisor]}]
    end

    def terminate_child(SymphonyElixir.Supervisor, AgentRuntimeSupervisor) do
      {:error, :injected_stop_failure}
    end
  end

  defmodule AlreadyStartedSupervisor do
    @moduledoc false

    def which_children(SymphonyElixir.Supervisor), do: []

    def restart_child(SymphonyElixir.Supervisor, AgentRuntimeSupervisor) do
      {:error, {:already_started, self()}}
    end
  end

  defmodule RestartFailureSupervisor do
    @moduledoc false

    def which_children(SymphonyElixir.Supervisor), do: []

    def restart_child(SymphonyElixir.Supervisor, AgentRuntimeSupervisor) do
      {:error, :injected_restart_failure}
    end
  end

  test "restoring a harness lease returns the default runtime to its initial running state" do
    assert is_pid(Process.whereis(AgentRuntimeSupervisor))
    lease = RuntimeTestHarness.acquire!()

    assert :ok = RuntimeTestHarness.stop_default_runtime!(lease)
    refute Process.whereis(AgentRuntimeSupervisor)
    assert :ok = RuntimeTestHarness.restore!(lease)
    assert is_pid(Process.whereis(AgentRuntimeSupervisor))

    assert :ok = RuntimeTestHarness.restore!(lease)
    assert is_pid(Process.whereis(AgentRuntimeSupervisor))
  end

  test "restoring a harness lease returns an initially stopped runtime to stopped" do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, AgentRuntimeSupervisor)

    on_exit(fn ->
      case Supervisor.restart_child(SymphonyElixir.Supervisor, AgentRuntimeSupervisor) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

    lease = RuntimeTestHarness.acquire!()

    assert :ok = RuntimeTestHarness.restart_default_runtime!(lease)
    assert is_pid(Process.whereis(AgentRuntimeSupervisor))
    assert :ok = RuntimeTestHarness.restore!(lease)
    refute Process.whereis(AgentRuntimeSupervisor)
  end

  test "stopping an already stopped default runtime keeps cleanup idempotent" do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, AgentRuntimeSupervisor)

    on_exit(fn ->
      case Supervisor.restart_child(SymphonyElixir.Supervisor, AgentRuntimeSupervisor) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

    lease = RuntimeTestHarness.acquire!()

    assert :ok = RuntimeTestHarness.stop_default_runtime!(lease)
    refute Process.whereis(AgentRuntimeSupervisor)
  end

  test "stop helper propagates supervisor stop errors" do
    message = ~r/failed to stop the default agent runtime: :injected_stop_failure/

    assert_raise RuntimeError, message, fn ->
      RuntimeTestHarness.with_supervisor_adapter(StopFailureSupervisor, fn ->
        RuntimeTestHarness.stop_default_runtime!(RuntimeTestHarness.acquire!())
      end)
    end
  end

  test "restart helper treats supervisor already-started races as success" do
    assert :ok =
             RuntimeTestHarness.with_supervisor_adapter(AlreadyStartedSupervisor, fn ->
               RuntimeTestHarness.restart_default_runtime!(RuntimeTestHarness.acquire!())
             end)
  end

  test "restart helper propagates supervisor restart errors" do
    message = ~r/failed to restart the default agent runtime: :injected_restart_failure/

    assert_raise RuntimeError, message, fn ->
      RuntimeTestHarness.with_supervisor_adapter(RestartFailureSupervisor, fn ->
        RuntimeTestHarness.restart_default_runtime!(RuntimeTestHarness.acquire!())
      end)
    end
  end

  test "supervisor adapter restores a previously configured adapter" do
    message = ~r/failed to stop the default agent runtime: :injected_stop_failure/

    RuntimeTestHarness.with_supervisor_adapter(StopFailureSupervisor, fn ->
      assert :ok =
               RuntimeTestHarness.with_supervisor_adapter(AlreadyStartedSupervisor, fn ->
                 RuntimeTestHarness.restart_default_runtime!(RuntimeTestHarness.acquire!())
               end)

      assert_raise RuntimeError, message, fn ->
        RuntimeTestHarness.stop_default_runtime!(RuntimeTestHarness.acquire!())
      end
    end)
  end

  test "runtime harness validates its option and the final ExUnit async configuration" do
    invalid_option_module = unique_module_name("InvalidRuntimeHarnessOptionCase")

    assert_raise ArgumentError, ~r/requires async: false/, fn ->
      Code.compile_string("""
      defmodule #{invalid_option_module} do
        use ExUnit.Case, async: false, register: false
        use SymphonyElixir.RuntimeTestHarness, async: true
      end
      """)
    end

    invalid_config_module = unique_module_name("InvalidRuntimeHarnessConfigCase")

    assert_raise ArgumentError, ~r/ExUnit case configured with async: false/, fn ->
      Code.compile_string("""
      defmodule #{invalid_config_module} do
        use ExUnit.Case, async: false, register: false
        use SymphonyElixir.RuntimeTestHarness, async: false
        use ExUnit.Case, async: true, register: false
      end
      """)
    end
  end

  test "runtime harness accepts a synchronous ExUnit case wrapped by TestSupport" do
    module = unique_module_name("WrappedRuntimeHarnessCase")

    assert [{compiled_module, _bytecode}] =
             Code.compile_string("""
             defmodule #{module} do
               use SymphonyElixir.TestSupport, async: false, register: false
               use SymphonyElixir.RuntimeTestHarness, async: false
             end
             """)

    assert compiled_module == module
    assert %{async?: false} = module.__ex_unit__(:config)
  end

  defp unique_module_name(prefix) do
    Module.concat(["#{prefix}#{System.unique_integer([:positive])}"])
  end
end
