defmodule SymphonyElixir.ProcessTestSupportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProcessTestSupport

  test "read_pid returns nil for an invalid PID file" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-process-test-support-#{System.unique_integer([:positive])}"
      )

    pid_file = Path.join(test_root, "invalid.pid")
    File.mkdir_p!(test_root)
    File.write!(pid_file, "not-a-pid")
    on_exit(fn -> File.rm_rf(test_root) end)

    assert ProcessTestSupport.read_pid(pid_file) == nil
  end

  test "monitored_process returns nil for a stopped process" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(pid)
    send(pid, :stop)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert ProcessTestSupport.monitored_process(pid) == nil
  end

  test "monitored_process ignores non-process monitors" do
    executable = System.find_executable("cat")
    assert is_binary(executable)

    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status])
    parent = self()

    holder =
      spawn(fn ->
        monitor = :erlang.monitor(:port, port)
        send(parent, {:port_monitor_ready, self(), monitor})

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:port_monitor_ready, ^holder, monitor}
      assert is_reference(monitor)
      assert {:monitors, monitors} = Process.info(holder, :monitors)
      assert {:port, port} in monitors
      assert ProcessTestSupport.monitored_process(holder) == nil
    after
      if Process.alive?(holder), do: Process.exit(holder, :kill)
      if Port.info(port), do: Port.close(port)
    end
  end

  test "eventually_value handles exhausted and false attempts" do
    ref = make_ref()

    try do
      assert ProcessTestSupport.eventually_value(fn -> flunk("must not run") end, 0) == nil

      assert ProcessTestSupport.eventually_value(
               fn ->
                 case Process.get(ref) do
                   nil ->
                     Process.put(ref, :seen)
                     false

                   :seen ->
                     :ready
                 end
               end,
               2
             ) == :ready
    after
      Process.delete(ref)
    end
  end
end
