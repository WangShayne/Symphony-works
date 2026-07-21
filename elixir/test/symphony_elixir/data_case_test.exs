defmodule SymphonyElixir.DataCaseRuntimeProbe do
  @moduledoc false

  import ExUnit.Assertions

  alias SymphonyElixir.AgentRuntimeSupervisor

  def start! do
    Agent.start(
      fn ->
        %{
          remaining_tests: 2,
          first_test_active?: false,
          second_setup_complete?: false
        }
      end,
      name: __MODULE__
    )
  end

  def capture_runtime! do
    runtime_pid =
      Process.whereis(AgentRuntimeSupervisor) ||
        raise "the default agent runtime supervisor must be running before DataCase setup"

    assert_unchanged!(runtime_pid)
    runtime_pid
  end

  def assert_unchanged!(runtime_pid) do
    assert Process.whereis(AgentRuntimeSupervisor) == runtime_pid
    assert Process.alive?(runtime_pid)
    assert is_list(Supervisor.which_children(runtime_pid))
  end

  def mark_first_test_active! do
    Agent.update(__MODULE__, &%{&1 | first_test_active?: true})
  end

  def await_first_test_active! do
    assert eventually?(fn -> Agent.get(__MODULE__, & &1.first_test_active?) end),
           "first async DataCase never became active"
  end

  def mark_second_setup_complete! do
    Agent.update(__MODULE__, &%{&1 | second_setup_complete?: true})
  end

  def await_second_setup_complete! do
    assert eventually?(fn -> Agent.get(__MODULE__, & &1.second_setup_complete?) end),
           "second async DataCase setup did not complete while the first test was active"
  end

  def complete! do
    finished? =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.remaining_tests == 1, %{state | remaining_tests: state.remaining_tests - 1}}
      end)

    if finished?, do: Agent.stop(__MODULE__)
    :ok
  end

  defp eventually?(predicate, attempts \\ 100)

  defp eventually?(_predicate, 0), do: false

  defp eventually?(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually?(predicate, attempts - 1)
    end
  end
end

defmodule SymphonyElixir.DataCaseRuntimeProbeCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  setup do
    runtime_pid = SymphonyElixir.DataCaseRuntimeProbe.capture_runtime!()

    on_exit(fn ->
      try do
        SymphonyElixir.DataCaseRuntimeProbe.assert_unchanged!(runtime_pid)
      after
        SymphonyElixir.DataCaseRuntimeProbe.complete!()
      end
    end)

    {:ok, runtime_before_data_case: runtime_pid}
  end
end

{:ok, _probe} = SymphonyElixir.DataCaseRuntimeProbe.start!()

defmodule SymphonyElixir.FirstAsyncDataCaseTest do
  use SymphonyElixir.DataCaseRuntimeProbeCase, async: true
  use SymphonyElixir.DataCase, async: true

  alias SymphonyElixir.DataCaseRuntimeProbe

  test "async DataCase setup leaves the default runtime supervisor unchanged", %{
    runtime_before_data_case: runtime_pid
  } do
    DataCaseRuntimeProbe.mark_first_test_active!()
    DataCaseRuntimeProbe.await_second_setup_complete!()
    DataCaseRuntimeProbe.assert_unchanged!(runtime_pid)
  end
end

defmodule SymphonyElixir.SecondAsyncDataCaseTest do
  use SymphonyElixir.DataCaseRuntimeProbeCase, async: true
  use SymphonyElixir.DataCase, async: true

  alias SymphonyElixir.DataCaseRuntimeProbe

  setup do
    DataCaseRuntimeProbe.await_first_test_active!()
    DataCaseRuntimeProbe.mark_second_setup_complete!()
    :ok
  end

  test "concurrent DataCase setup does not replace the default runtime supervisor", %{
    runtime_before_data_case: runtime_pid
  } do
    DataCaseRuntimeProbe.assert_unchanged!(runtime_pid)
  end
end
