defmodule SymphonyElixir.ExecCommandTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecCommand

  test "run preserves argv, output streams, and normal exit status without descendant residue" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-exec-command-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    child_pid_path = Path.join(root, "child.pid")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, result} =
             ExecCommand.run([
               "/bin/sh",
               "-c",
               """
               printf '<%s>|<%s>|<%s>\\n' "$1" "$2" "$3"
               printf 'stderr-before-exit\\n' >&2
               (
                 trap '' TERM HUP
                 while :; do sleep 1; done
               ) &
               printf '%s\\n' "$!" > "$4"
               exit 37
               """,
               "--",
               "space arg",
               "single'quote",
               "$(echo nope)",
               child_pid_path
             ])

    assert result.status == 37
    assert result.stdout == "<space arg>|<single'quote>|<$(echo nope)>\n"
    assert result.stderr == "stderr-before-exit\n"

    assert result.output == [
             {:stdout, "<space arg>|<single'quote>|<$(echo nope)>\n"},
             {:stderr, "stderr-before-exit\n"}
           ]

    child_pid = child_pid_path |> File.read!() |> String.trim() |> String.to_integer()
    refute_os_process_alive(child_pid)
  end

  test "run preserves argv for guarded shell callers" do
    {:ok, result} =
      ExecCommand.run([
        "/bin/sh",
        "-c",
        "printf '<%s>|<%s>|<%s>\\n' \"$1\" \"$2\" \"$3\"; exit 37",
        "--",
        "space arg",
        "single'quote",
        "$(echo nope)"
      ])

    assert result.stdout == "<space arg>|<single'quote>|<$(echo nope)>\n"
    assert result.status == 37
  end

  test "run covers invalid spawn, env deletion, signal exit, timeout, and caller death" do
    assert {:error, _reason} =
             Task.async(fn -> ExecCommand.run([], guarded: false) end)
             |> Task.await()

    missing_directory =
      Path.join(
        System.tmp_dir!(),
        "symphony-missing-cwd-#{System.unique_integer([:positive, :monotonic])}"
      )

    assert {:error, :invalid_working_directory} =
             ExecCommand.run(["/bin/true"], cd: missing_directory)

    assert {:ok, env_result} =
             ExecCommand.run(
               ["/bin/sh", "-c", "printf '%s' \"${SYMPHONY_EXEC_TEST_VALUE-unset}\""],
               env: [{"SYMPHONY_EXEC_TEST_VALUE", nil}]
             )

    assert env_result.stdout == "unset"

    assert {:ok, normal_result} = ExecCommand.run(["/bin/sh", "-c", "exit 0"], guarded: false)
    assert normal_result.status == 0

    assert {:ok, signal_result} =
             ExecCommand.run(["/bin/sh", "-c", "kill -TERM $$"], guarded: false)

    assert signal_result.status == 143

    assert {:error, :timeout} =
             ExecCommand.run(["/bin/sh", "-c", "while :; do sleep 1; done"],
               timeout_ms: 10,
               stop_timeout_ms: :invalid
             )

    caller = spawn(fn -> Process.sleep(:infinity) end)

    runner =
      Task.async(fn ->
        caller_ref = Process.monitor(caller)

        ExecCommand.run(["/bin/sh", "-c", "while :; do sleep 1; done"],
          timeout_ms: 5_000,
          caller_ref: caller_ref
        )
      end)

    Process.exit(caller, :kill)
    assert {:error, :caller_down} = Task.await(runner)
  end

  test "run reports an exec supervisor crash as an error" do
    test_pid = self()

    runner =
      spawn(fn ->
        send(test_pid, {:exec_result, ExecCommand.run(["/bin/sh", "-c", "while :; do sleep 1; done"], guarded: false, timeout_ms: 60_000)})
      end)

    exec_pid =
      eventually_value(fn ->
        case Process.info(runner, :links) do
          {:links, links} -> Enum.find(links, &is_pid/1)
          nil -> nil
        end
      end)

    Process.exit(exec_pid, :kill)
    assert_receive {:exec_result, {:error, :killed}}, 5_000
  end

  test "status marker parser preserves non-control stderr and ignores malformed markers" do
    assert String.starts_with?(ExecCommand.status_marker(), "__SYMPHONY_EXEC_STATUS__:")
    assert {nil, "partial"} = ExecCommand.take_status("", "partial")

    assert {nil, "tail"} =
             ExecCommand.take_status("", "__SYMPHONY_EXEC_STATUS__:not-an-integer\ntail")

    assert {37, "tail"} = ExecCommand.take_status("", "stderr\n__SYMPHONY_EXEC_STATUS__:37\ntail")
    assert {nil, "stderr\n", ""} = ExecCommand.take_status_and_stderr("", "stderr\n")
  end

  test "status control helpers expose match, nomatch, drain, and decode branches" do
    ref = make_ref()
    proofs = 0..255 |> Enum.map(&"proof-#{&1}") |> List.to_tuple()

    control = %ExecCommand.StatusControl{
      ref: ref,
      reader: self(),
      reader_os_pid: 1,
      path: "",
      secret_path: "",
      proofs: proofs,
      control_dir: "",
      control_root: ""
    }

    assert {:ok, 42} = ExecCommand.status_message(control, {{ExecCommand, :status}, ref, {:ok, 42}})
    assert :nomatch = ExecCommand.status_message(control, :other)
    assert :nomatch = ExecCommand.status_message(nil, :other)

    send(self(), {:stdout, 1234, "out"})
    send(self(), {:stderr, 1234, "err"})

    {stdout, stderr, events} = ExecCommand.drain_output_for_test(1234, [], [], [])

    assert IO.iodata_to_binary(stdout) == "out"
    assert IO.iodata_to_binary(stderr) == "err"
    assert Enum.reverse(events) == [{:stdout, "out"}, {:stderr, "err"}]

    send(self(), {:stderr, 5678, ""})
    assert {[], [], []} = ExecCommand.drain_output_for_test(5678, [], [], [])

    assert ExecCommand.decode_exec_status_for_test(23 * 256) == 23
  end

  test "status control fifo helpers return precise error branches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-exec-command-control-errors-#{System.unique_integer([:positive, :monotonic])}"
      )

    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    fake_bin = Path.join(test_root, "bin")
    fake_mkfifo = Path.join(fake_bin, "mkfifo")
    File.mkdir_p!(fake_bin)

    File.write!(fake_mkfifo, """
    #!/bin/sh
    printf 'forced mkfifo failure\\n' >&2
    exit 17
    """)

    File.chmod!(fake_mkfifo, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))

    assert {:error, {:mkfifo_failed, 17, output}} = ExecCommand.make_control_fifo_for_test()
    assert output =~ "forced mkfifo failure"

    assert {:error, {:mkfifo_failed, 17, _output}} = ExecCommand.run(["/bin/true"])

    restore_env("PATH", previous_path)

    blocking_file = Path.join(test_root, "blocking-file")
    File.write!(blocking_file, "")
    assert {:error, _reason} = ExecCommand.make_control_fifo_for_test(blocking_file)

    missing_path = Path.join(test_root, "missing-control")
    empty_path = Path.join(test_root, "empty-control")
    directory_path = Path.join(test_root, "directory-control")

    File.write!(empty_path, "")
    File.mkdir_p!(directory_path)

    assert {:error, {:control_read_failed, _status, _output}} =
             ExecCommand.read_control_line_for_test(missing_path)

    assert {:error, {:control_read_failed, _status, _output}} =
             ExecCommand.read_control_line_for_test(empty_path)

    assert {:error, {:control_read_failed, _status, _output}} =
             ExecCommand.read_control_line_for_test(directory_path)

    control_path = Path.join(test_root, "control-with-secret-error")
    File.write!(control_path, "")
    File.mkdir_p!(control_path <> ".secret")

    assert {:error, _reason} =
             ExecCommand.write_control_secret_for_test(control_path, "test-token")

    assert File.exists?(control_path)

    chmod_path = Path.join(test_root, "removed-secret")
    {:ok, io} = File.open(chmod_path, [:write, :binary, :exclusive])
    File.rm!(chmod_path)

    assert {:error, :enoent} =
             ExecCommand.protect_write_and_close_control_secret_for_test(io, chmod_path, "test-token")

    proofs = 0..255 |> Enum.map(&"proof-#{&1}") |> List.to_tuple()

    assert {:ok, 23} = ExecCommand.parse_control_status_for_test("23:proof-23\n", proofs)
    assert {:error, :invalid_control_status} = ExecCommand.parse_control_status_for_test("not-a-status\n", proofs)
    assert {:error, :invalid_control_status} = ExecCommand.parse_control_status_for_test("23:proof-00\n", proofs)
    assert {:error, :invalid_control_status} = ExecCommand.parse_control_status_for_test("23:x\n", proofs)

    assert {:error, :invalid_control_status} =
             ExecCommand.parse_control_status_for_test("not-a-status:proof-0\n", proofs)
  end

  test "control reader failure, framing, and shutdown branches fail closed without residue" do
    control_dir = Path.join(System.tmp_dir!(), "symphony-exec-control")
    before_entries = control_entries(control_dir)

    failing_reader = fn _parent, _ref, _control_path, _proofs ->
      {:error, :forced_reader_failure}
    end

    assert {:error, :forced_reader_failure} =
             ExecCommand.start_guarded_command_for_test(["/bin/true"], failing_reader)

    assert control_entries(control_dir) == before_entries

    assert {:error, {:control_reader_start_failed, :forced_start_failure}} =
             ExecCommand.start_control_reader_for_test(
               fn _command, _opts -> {:error, :forced_start_failure} end,
               100
             )

    assert {:error, :control_reader_start_timeout} =
             ExecCommand.start_control_reader_for_test(
               fn _command, _opts -> Process.sleep(:infinity) end,
               10
             )

    proofs = 0..255 |> Enum.map(&"proof-#{&1}") |> List.to_tuple()

    assert {:ok, 23} =
             ExecCommand.collect_control_status_for_test(
               [{:stderr, "ignored"}, {:stdout, "23:"}, {:stdout, "proof-23\n"}],
               proofs
             )

    assert {:error, {:control_read_failed, :killed, "reader warning"}} =
             ExecCommand.collect_control_status_for_test(
               [{:stderr, "reader warning"}, {:exit, :killed}],
               proofs
             )

    assert {:error, {:control_read_failed, 17, "reader warning"}} =
             ExecCommand.collect_control_status_for_test(
               [{:stderr, "reader warning"}, {:exit, {:exit_status, 17}}],
               proofs
             )

    assert {:error, {:control_read_failed, :forced_down, ""}} =
             ExecCommand.collect_control_status_for_test([{:down, :forced_down}], proofs)

    exits_on_stop =
      spawn(fn ->
        receive do
          {message, :stop, _ref, from, stop_ref} -> send(from, {message, :stopped, stop_ref})
        end
      end)

    assert :ok = ExecCommand.stop_control_reader_for_test(exits_on_stop, 100)
    refute Process.alive?(exits_on_stop)

    ignores_stop = spawn(fn -> receive do: (:finish -> :ok) end)
    assert :ok = ExecCommand.stop_control_reader_for_test(ignores_stop, 10)
    assert Process.alive?(ignores_stop)
    Process.exit(ignores_stop, :kill)

    fifo_root = Path.join(System.tmp_dir!(), "symphony-exec-read-success-#{System.unique_integer([:positive])}")
    assert {:ok, fifo_path} = ExecCommand.make_control_fifo_for_test(fifo_root)

    writer = Task.async(fn -> File.write!(fifo_path, "ready\n") end)
    assert {:ok, "ready\n"} = ExecCommand.read_control_line_for_test(fifo_path)
    assert :ok = Task.await(writer)
    File.rm_rf!(fifo_root)
  end

  test "status control carriers are private from creation and cleanup removes private directory" do
    assert {:ok, _apps} = Application.ensure_all_started(:erlexec)

    assert {:ok, {_command, control}} =
             ExecCommand.start_guarded_command(["/bin/sh", "-c", "exit 0"])

    control_dir = Path.dirname(control.path)
    control_parent = Path.dirname(control_dir)

    assert Path.basename(control_parent) == "symphony-exec-control"
    assert stat_type(control_parent) == :directory
    assert stat_mode(control_parent) == 0o700
    assert String.starts_with?(Path.basename(control_dir), "run-")
    assert control.secret_path == control.path <> ".secret"
    assert Path.dirname(control.secret_path) == control_dir

    assert stat_type(control_dir) == :directory
    assert stat_mode(control_dir) == 0o700
    assert stat_type(control.path) == :other
    assert stat_mode(control.path) == 0o600
    assert stat_type(control.secret_path) == :regular
    assert stat_mode(control.secret_path) == 0o600

    ExecCommand.cleanup_status_control(control)

    refute File.exists?(control_dir)
    refute File.exists?(control.path)
    refute File.exists?(control.secret_path)
    refute_os_process_alive(control.reader_os_pid)
  end

  test "status control cleanup refuses forged run directory outside exec control parent" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-exec-command-forged-cleanup-#{System.unique_integer([:positive, :monotonic])}"
      )

    forged_dir = Path.join(test_root, "run-forged")
    forged_status = Path.join(forged_dir, "status")
    forged_secret = forged_status <> ".secret"
    sentinel = Path.join(forged_dir, "sentinel")

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(forged_dir)
    File.write!(forged_status, "")
    File.write!(forged_secret, "")
    File.write!(sentinel, "keep")

    reader =
      spawn(fn ->
        receive do
          {message, :stop, from, stop_ref} -> send(from, {message, :stopped, stop_ref})
          {message, :stop, _ref, from, stop_ref} -> send(from, {message, :stopped, stop_ref})
        end
      end)

    control = %ExecCommand.StatusControl{
      ref: make_ref(),
      reader: reader,
      reader_os_pid: 1,
      path: forged_status,
      secret_path: forged_secret,
      proofs: {},
      control_dir: forged_dir,
      control_root: default_control_parent()
    }

    ExecCommand.cleanup_status_control(control)

    assert File.exists?(forged_dir)
    assert File.read!(forged_status) == ""
    assert File.read!(forged_secret) == ""
    assert File.read!(sentinel) == "keep"
  end

  test "status control cleanup refuses forged self-consistent control root capability" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-exec-command-forged-root-#{System.unique_integer([:positive, :monotonic])}"
      )

    forged_root = Path.join(test_root, "symphony-exec-control")
    forged_dir = Path.join(forged_root, "run-forged")
    forged_status = Path.join(forged_dir, "status")
    forged_secret = forged_status <> ".secret"
    sentinel = Path.join(forged_dir, "sentinel")

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(forged_dir)
    File.chmod!(forged_root, 0o700)
    File.chmod!(forged_dir, 0o700)
    File.write!(forged_status, "status")
    File.write!(forged_secret, "secret")
    File.write!(sentinel, "keep")

    reader =
      spawn(fn ->
        receive do
          {message, :stop, from, stop_ref} -> send(from, {message, :stopped, stop_ref})
          {message, :stop, _ref, from, stop_ref} -> send(from, {message, :stopped, stop_ref})
        end
      end)

    control = %ExecCommand.StatusControl{
      ref: make_ref(),
      reader: reader,
      reader_os_pid: 1,
      path: forged_status,
      secret_path: forged_secret,
      proofs: {},
      control_dir: forged_dir,
      control_root: forged_root
    }

    ExecCommand.cleanup_status_control(control)

    assert File.read!(forged_status) == "status"
    assert File.read!(forged_secret) == "secret"
    assert File.read!(sentinel) == "keep"
  end

  test "run owner death cleans reader process, reader OS process, and private control directory" do
    for _attempt <- 1..5 do
      assert_run_owner_death_cleans_control_resources()
    end
  end

  test "status control cleanup uses creation-time control root when TMPDIR changes" do
    assert {:ok, _apps} = Application.ensure_all_started(:erlexec)

    previous_tmpdir = System.get_env("TMPDIR")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-exec-command-tmp-drift-#{System.unique_integer([:positive, :monotonic])}"
      )

    tmp_a = Path.join(test_root, "tmp-a")
    tmp_b = Path.join(test_root, "tmp-b")

    on_exit(fn ->
      restore_env("TMPDIR", previous_tmpdir)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(tmp_a)
    File.mkdir_p!(tmp_b)
    System.put_env("TMPDIR", tmp_a)

    assert {:ok, {_command, control}} =
             ExecCommand.start_guarded_command(["/bin/sh", "-c", "exit 0"])

    control_dir = control.control_dir
    assert control_dir =~ Path.join(Path.basename(tmp_a), "symphony-exec-control")

    System.put_env("TMPDIR", tmp_b)
    ExecCommand.cleanup_status_control(control)

    refute File.exists?(control_dir)
    refute_os_process_alive(control.reader_os_pid)
  end

  defp assert_run_owner_death_cleans_control_resources do
    before_dirs = control_private_dirs()
    test_pid = self()

    owner =
      spawn(fn ->
        send(test_pid, :owner_started)

        ExecCommand.run(["/bin/sh", "-c", "while :; do sleep 1; done"],
          timeout_ms: 60_000
        )
      end)

    assert_receive :owner_started, 1_000

    control_dir =
      eventually_value(fn ->
        control_private_dirs()
        |> Enum.reject(&MapSet.member?(before_dirs, &1))
        |> Enum.find(fn dir ->
          File.exists?(Path.join(dir, "status")) and File.exists?(Path.join(dir, "status.secret"))
        end)
      end)

    control_path = Path.join(control_dir, "status")

    reader_pid = eventually_value(fn -> control_reader_process_for_path(control_path, owner) end)
    reader_os_pid = eventually_value(fn -> control_reader_os_pid_for_path(control_path) end)

    assert is_pid(reader_pid)
    assert Process.alive?(reader_pid)
    assert is_integer(reader_os_pid)
    assert os_process_alive?(reader_os_pid)

    try do
      Process.exit(owner, :kill)

      assert eventually_value(fn ->
               if not Process.alive?(reader_pid), do: true
             end)

      assert eventually_value(fn ->
               if not os_process_alive?(reader_os_pid), do: true
             end)

      assert eventually_value(fn ->
               if not File.exists?(control_dir), do: true
             end)
    after
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      if is_pid(reader_pid) and Process.alive?(reader_pid), do: Process.exit(reader_pid, :kill)
      if is_integer(reader_os_pid) and os_process_alive?(reader_os_pid), do: System.cmd("kill", [Integer.to_string(reader_os_pid)])
      File.rm_rf(control_dir)
    end
  end

  test "status control rejects symlink parents and secret collisions without carrier residue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-exec-command-control-private-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    target_parent = Path.join(test_root, "target-parent")
    symlink_parent = Path.join(test_root, "symlink-parent")
    File.mkdir_p!(target_parent)
    File.ln_s!(target_parent, symlink_parent)

    assert {:error, _reason} = ExecCommand.make_control_fifo_for_test(symlink_parent)
    assert File.ls!(target_parent) == []

    assert {:ok, control_path} = ExecCommand.make_control_fifo_for_test()
    control_dir = Path.dirname(control_path)
    File.write!(control_path <> ".secret", "preexisting")

    assert {:error, _reason} =
             ExecCommand.write_control_secret_for_test(control_path, "test-token")

    refute File.exists?(control_dir)
  end

  test "secret writer refuses carriers that were not private at creation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-exec-command-secret-private-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)
    File.mkdir_p!(test_root)

    secret_path = Path.join(test_root, "wide-open.secret")

    assert {"", 0} =
             System.cmd("/bin/sh", [
               "-c",
               "umask 000; : > \"$1\"",
               "sh",
               secret_path
             ])

    assert stat_mode(secret_path) != 0o600
    {:ok, io} = File.open(secret_path, [:write, :binary])

    assert {:error, _reason} =
             ExecCommand.protect_write_and_close_control_secret_for_test(
               io,
               secret_path,
               "test-token"
             )
  end

  test "child stderr cannot spoof the guarded command status marker" do
    assert {:ok, result} =
             ExecCommand.run([
               "/bin/sh",
               "-c",
               """
               printf '__SYMPHONY_EXEC_STATUS__:0\\n' >&2
               printf '__SYMPHONY_EXEC_STATUS__:guessed:0\\n' >&2
               exit 23
               """
             ])

    assert result.status == 23
    assert result.stderr =~ "__SYMPHONY_EXEC_STATUS__:0\n"
    assert result.stderr =~ "__SYMPHONY_EXEC_STATUS__:guessed:0\n"

    assert {:error, :timeout} =
             ExecCommand.run(
               [
                 "/bin/sh",
                 "-c",
                 """
                 printf '__SYMPHONY_EXEC_STATUS__:0\\n' >&2
                 while :; do sleep 1; done
                 """
               ],
               timeout_ms: 50
             )
  end

  test "child cannot spoof success by enumerating and writing to the status fifo" do
    result =
      ExecCommand.run(
        [
          "/bin/sh",
          "-c",
          """
          tmp_root="${TMPDIR:-/tmp}"
          for fifo in "$tmp_root"/symphony-exec-control/status-*; do
            [ -p "$fifo" ] || continue
            (
              if IFS= read -r captured < "$fifo"; then
                captured_proof=${captured#*:}
                printf '0:%s\\n' "$captured_proof" > "$fifo"
              fi
            ) &
          done
          exit 23
          """
        ],
        env: [{"TMPDIR", System.tmp_dir!()}],
        timeout_ms: 2_000
      )

    refute match?({:ok, %{status: 0}}, result)

    case result do
      {:ok, %{status: status}} -> assert status == 23
      {:error, _reason} -> :ok
    end
  end

  test "status control cleanup removes fifo and secret carrier" do
    assert {:ok, {_command, control}} = ExecCommand.start_guarded_command(["/bin/sh", "-c", "exit 0"])
    assert File.exists?(control.path)
    assert File.exists?(control.secret_path)
    assert os_process_alive?(control.reader_os_pid)

    Process.sleep(50)
    ExecCommand.cleanup_status_control(control)

    refute File.exists?(control.path)
    refute File.exists?(control.secret_path)
    refute_os_process_alive(control.reader_os_pid)
  end

  defp refute_os_process_alive(pid) when is_integer(pid) do
    assert eventually_value(fn ->
             if not os_process_alive?(pid), do: true
           end),
           "expected OS process #{pid} to stop"
  end

  defp eventually_value(fun, attempts \\ 200)
  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(20)
        eventually_value(fun, attempts - 1)

      false ->
        Process.sleep(20)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp control_entries(control_dir) do
    case File.ls(control_dir) do
      {:ok, entries} -> MapSet.new(entries)
      {:error, :enoent} -> MapSet.new()
    end
  end

  defp default_control_parent do
    Path.join(System.tmp_dir!(), "symphony-exec-control")
  end

  defp control_private_dirs do
    case File.ls(default_control_parent()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "run-"))
        |> Enum.map(&Path.join(default_control_parent(), &1))
        |> MapSet.new()

      {:error, :enoent} ->
        MapSet.new()
    end
  end

  defp control_reader_process_for_path(_control_path, owner) do
    Process.list()
    |> Enum.find(fn pid ->
      pid != self() and pid != owner and
        match?({:current_function, {ExecCommand, :collect_control_status, _arity}}, Process.info(pid, :current_function))
    end)
  end

  defp control_reader_os_pid_for_path(control_path) do
    case System.cmd("ps", ["-axo", "pid=,command="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          if String.contains?(line, control_path) and String.contains?(line, "read -r line") do
            line
            |> String.trim()
            |> String.split(~r/\s+/, parts: 2)
            |> hd()
            |> Integer.parse()
            |> case do
              {pid, ""} -> pid
              _invalid -> nil
            end
          end
        end)

      {_output, _status} ->
        nil
    end
  end

  defp stat_mode(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  defp stat_type(path) do
    {:ok, %{type: type}} = File.stat(path)
    type
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
