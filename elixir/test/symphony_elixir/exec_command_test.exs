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
      proofs: proofs
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

    refute File.exists?(control_path)

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

    exits_on_stop = spawn(fn -> receive do: (_message -> :ok) end)
    assert :ok = ExecCommand.stop_control_reader_for_test(exits_on_stop, 100)
    refute Process.alive?(exits_on_stop)

    ignores_stop = spawn(fn -> receive do: (:finish -> :ok) end)
    assert :ok = ExecCommand.stop_control_reader_for_test(ignores_stop, 10)
    refute eventually_value(fn -> Process.alive?(ignores_stop) end, 5)

    fifo_root = Path.join(System.tmp_dir!(), "symphony-exec-read-success-#{System.unique_integer([:positive])}")
    assert {:ok, fifo_path} = ExecCommand.make_control_fifo_for_test(fifo_root)

    writer = Task.async(fn -> File.write!(fifo_path, "ready\n") end)
    assert {:ok, "ready\n"} = ExecCommand.read_control_line_for_test(fifo_path)
    assert :ok = Task.await(writer)
    File.rm_rf!(fifo_root)
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
