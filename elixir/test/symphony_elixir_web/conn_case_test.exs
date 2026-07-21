defmodule SymphonyElixirWeb.ConnCaseRuntimeProbe do
  @moduledoc false

  import ExUnit.Assertions

  alias SymphonyElixir.AgentRuntimeSupervisor

  def capture_runtime! do
    runtime_pid =
      Process.whereis(AgentRuntimeSupervisor) ||
        raise "the default agent runtime supervisor must be running before ConnCase setup"

    assert_unchanged!(runtime_pid)
    runtime_pid
  end

  def assert_unchanged!(runtime_pid) do
    assert Process.whereis(AgentRuntimeSupervisor) == runtime_pid
    assert Process.alive?(runtime_pid)
    assert is_list(Supervisor.which_children(runtime_pid))
  end
end

defmodule SymphonyElixirWeb.ConnCaseRuntimeProbeCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  setup do
    runtime_pid = SymphonyElixirWeb.ConnCaseRuntimeProbe.capture_runtime!()

    on_exit(fn ->
      SymphonyElixirWeb.ConnCaseRuntimeProbe.assert_unchanged!(runtime_pid)
    end)

    {:ok, runtime_before_conn_case: runtime_pid}
  end
end

defmodule SymphonyElixirWeb.ConnCaseRuntimeIsolationTest do
  use SymphonyElixirWeb.ConnCaseRuntimeProbeCase, async: false
  use SymphonyElixirWeb.ConnCase, async: false

  test "ConnCase setup and cleanup leave the default runtime supervisor unchanged", %{
    conn: conn,
    runtime_before_conn_case: runtime_pid
  } do
    assert %Plug.Conn{} = conn
    SymphonyElixirWeb.ConnCaseRuntimeProbe.assert_unchanged!(runtime_pid)
  end
end
