defmodule SymphonyElixir.RuntimeTestHarnessTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRuntimeSupervisor, RuntimeTestHarness}

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
