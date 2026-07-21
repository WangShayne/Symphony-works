defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.ProcessTestSupport,
    only: [
      eventually_value: 1,
      monitored_process: 1,
      read_pid: 1,
      refute_os_process_alive: 1
    ]

  alias SymphonyElixir.SSH

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 -- root@[::1] bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 rejects unsupported and option-shaped destinations before ssh starts" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    for destination <- [
          "::1:2200",
          "-oProxyCommand=touch/tmp/pwned",
          " localhost",
          "local host",
          "localhost\t-oProxyCommand=bad",
          "localhost\n-oProxyCommand=bad",
          "root@",
          "root@-oProxyCommand=bad",
          "[127.0.0.1]:22",
          "[::gg]:22",
          "localhost:0",
          "localhost:65536"
        ] do
      assert {:error, :invalid_ssh_destination} =
               SSH.run(destination, "printf ok", stderr_to_stdout: true)
    end

    refute File.exists?(trace_file)
  end

  test "validate_destination/1 accepts supported ssh destinations and rejects unsafe ones" do
    for destination <- ["localhost", "deploy@example.com:2222", "root@[::1]:2200", "[2001:db8::1]:22"] do
      assert :ok = SSH.validate_destination(destination)
    end

    for destination <- ["", "-oProxyCommand=bad", "root@-host", "host name", "[127.0.0.1]:22", "[::bad::]:22"] do
      assert {:error, :invalid_ssh_destination} = SSH.validate_destination(destination)
    end
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 -- localhost bash -lc"
    assert trace =~ "echo ready"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 -- root@127.0.0.1 bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 propagates current environment and normalizes nonzero exit statuses" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-env-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'TRACE_ENV:%s\\n' "${SYMP_TEST_SSH_TRACE:-missing}" >> "#{trace_file}"
    printf 'denied\\n'
    exit 75
    """)

    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)

    assert {:ok, {"denied\n", 75}} =
             SSH.run("localhost", "printf ok", stderr_to_stdout: true)

    assert File.read!(trace_file) =~ "TRACE_ENV:#{trace_file}"
  end

  test "run/3 maps signal exits to shell-style statuses" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-signal-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    kill -TERM $$
    """)

    assert {:ok, {"", 143}} = SSH.run("localhost", "printf ok", stderr_to_stdout: true)
  end

  test "run/3 timeout terminates ssh process group" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-timeout-group-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    parent_pid_file = Path.join(test_root, "ssh-parent.pid")
    child_pid_file = Path.join(test_root, "ssh-child.pid")
    previous_path = System.get_env("PATH")
    test_pid = self()

    try do
      install_fake_ssh!(test_root, trace_file, blocking_pid_ssh(parent_pid_file, child_pid_file))

      spawn(fn ->
        send(test_pid, {:ssh_run_result, SSH.run("localhost", "printf ok", stderr_to_stdout: true, timeout_ms: 2_000)})
      end)

      parent_pid = eventually_value(fn -> read_pid(parent_pid_file) end)
      child_pid = eventually_value(fn -> read_pid(child_pid_file) end)
      assert parent_pid != child_pid
      assert_receive {:ssh_run_result, {:error, :timeout}}, 8_000

      refute_os_process_alive(parent_pid)
      refute_os_process_alive(child_pid)
    after
      restore_env("PATH", previous_path)
      cleanup_pid_file(parent_pid_file)
      cleanup_pid_file(child_pid_file)
      File.rm_rf(test_root)
    end
  end

  test "run/3 caller death terminates ssh process group" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-caller-death-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    parent_pid_file = Path.join(test_root, "ssh-parent.pid")
    child_pid_file = Path.join(test_root, "ssh-child.pid")
    previous_path = System.get_env("PATH")

    try do
      install_fake_ssh!(test_root, trace_file, blocking_pid_ssh(parent_pid_file, child_pid_file))

      runner = spawn(fn -> SSH.run("localhost", "printf ok", stderr_to_stdout: true) end)
      parent_pid = eventually_value(fn -> read_pid(parent_pid_file) end)
      child_pid = eventually_value(fn -> read_pid(child_pid_file) end)
      owner = eventually_value(fn -> monitored_process(runner) end)
      assert parent_pid != child_pid
      assert is_pid(owner)

      ref = Process.monitor(runner)
      owner_ref = Process.monitor(owner)
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 1_000
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 8_000

      refute_os_process_alive(parent_pid)
      refute_os_process_alive(child_pid)
    after
      restore_env("PATH", previous_path)
      cleanup_pid_file(parent_pid_file)
      cleanup_pid_file(child_pid_file)
      File.rm_rf(test_root)
    end
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, stream} = SSH.start_port("localhost", "printf ok")
    assert %SSH.Stream{} = stream
    assert_receive {^stream, {:data, "ready\n"}}, 2_000
    assert_receive {^stream, {:exit_status, 0}}, 5_000

    trace = File.read!(trace_file)
    assert trace =~ "-T -- localhost bash -lc"
    refute trace =~ " -F "
  end

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    assert {:ok, stream} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert %SSH.Stream{} = stream
    assert_receive {^stream, {:data, {:eol, "ready"}}}, 2_000
    assert_receive {^stream, {:exit_status, 0}}, 5_000

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2222 -- localhost bash -lc"
  end

  test "start_port/3 sends stdin through the ssh stream" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-stdin-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    IFS= read -r line
    printf 'received:%s\\n' "$line"
    exit 0
    """)

    assert {:ok, stream} = SSH.start_port("localhost", "cat", line: 256)
    assert SSH.send_data(stream, "hello\n")
    assert_receive {^stream, {:data, {:eol, "received:hello"}}}, 2_000
    assert_receive {^stream, {:exit_status, 0}}, 5_000
  end

  test "start_port/3 close_stream terminates ssh process group" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-ssh-port-close-group-test-#{System.unique_integer([:positive])}")

    trace_file = Path.join(test_root, "ssh.trace")
    parent_pid_file = Path.join(test_root, "ssh-parent.pid")
    child_pid_file = Path.join(test_root, "ssh-child.pid")
    previous_path = System.get_env("PATH")

    try do
      install_fake_ssh!(test_root, trace_file, blocking_pid_ssh(parent_pid_file, child_pid_file))

      assert {:ok, stream} = SSH.start_port("localhost", "printf ok")
      parent_pid = eventually_value(fn -> read_pid(parent_pid_file) end)
      child_pid = eventually_value(fn -> read_pid(child_pid_file) end)
      assert parent_pid != child_pid

      assert :ok = SSH.close_stream(stream)

      refute_os_process_alive(parent_pid)
      refute_os_process_alive(child_pid)
    after
      restore_env("PATH", previous_path)
      cleanup_pid_file(parent_pid_file)
      cleanup_pid_file(child_pid_file)
      File.rm_rf(test_root)
    end
  end

  test "start_port/3 caller death terminates ssh process group" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-ssh-port-caller-death-test-#{System.unique_integer([:positive])}")

    trace_file = Path.join(test_root, "ssh.trace")
    parent_pid_file = Path.join(test_root, "ssh-parent.pid")
    child_pid_file = Path.join(test_root, "ssh-child.pid")
    previous_path = System.get_env("PATH")
    test_pid = self()

    try do
      install_fake_ssh!(test_root, trace_file, blocking_pid_ssh(parent_pid_file, child_pid_file))

      runner =
        spawn(fn ->
          assert {:ok, stream} = SSH.start_port("localhost", "printf ok")
          send(test_pid, {:stream_started, stream})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:stream_started, %SSH.Stream{} = stream}, 2_000
      parent_pid = eventually_value(fn -> read_pid(parent_pid_file) end)
      child_pid = eventually_value(fn -> read_pid(child_pid_file) end)
      assert parent_pid != child_pid

      ref = Process.monitor(runner)
      owner_ref = Process.monitor(stream.owner)
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 1_000
      assert_receive {:DOWN, ^owner_ref, :process, _owner, _reason}, 8_000

      refute_os_process_alive(parent_pid)
      refute_os_process_alive(child_pid)
    after
      restore_env("PATH", previous_path)
      cleanup_pid_file(parent_pid_file)
      cleanup_pid_file(child_pid_file)
      File.rm_rf(test_root)
    end
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp blocking_pid_ssh(parent_pid_file, child_pid_file) do
    """
    #!/bin/sh
    printf '%s\\n' "$$" > "#{parent_pid_file}"
    (
      trap '' TERM
      while :; do sleep 1; done
    ) &
    child_pid=$!
    printf '%s\\n' "$child_pid" > "#{child_pid_file}"
    wait "$child_pid"
    """
  end

  defp cleanup_pid_file(path) do
    case read_pid(path) do
      pid when is_integer(pid) -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
