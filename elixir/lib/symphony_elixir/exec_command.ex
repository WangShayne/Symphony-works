defmodule SymphonyElixir.ExecCommand do
  @moduledoc false

  @status_marker_prefix "__SYMPHONY_EXEC_STATUS__:"
  @control_message {__MODULE__, :status}
  @control_reader_message {__MODULE__, :control_reader}
  @control_reader_script ~S|if IFS= read -r line < "$1"; then printf '%s\n' "$line"; else exit 1; fi|
  @default_stop_timeout_ms 2_500
  @control_reader_start_timeout_ms 5_000
  @signal_numbers %{sighup: 1, sigint: 2, sigquit: 3, sigkill: 9, sigterm: 15}

  defmodule StatusControl do
    @moduledoc false

    @enforce_keys [:ref, :reader, :reader_os_pid, :path, :secret_path, :proofs]
    defstruct [:ref, :reader, :reader_os_pid, :path, :secret_path, :proofs]

    @type t :: %__MODULE__{
            ref: reference(),
            reader: pid(),
            reader_os_pid: pos_integer(),
            path: Path.t(),
            secret_path: Path.t(),
            proofs: tuple()
          }
  end

  @type stream_event :: {:stdout | :stderr, binary()}

  @type result :: %{
          status: non_neg_integer(),
          stdout: binary(),
          stderr: binary(),
          output: [stream_event()]
        }

  @spec status_marker() :: String.t()
  def status_marker do
    @status_marker_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <> ":"
  end

  @spec start_guarded_command([String.t()]) :: {:ok, {[String.t()], StatusControl.t()}} | {:error, term()}
  def start_guarded_command(command) when is_list(command) do
    start_guarded_command(command, &start_control_reader/4)
  end

  defp start_guarded_command(command, start_reader) when is_list(command) and is_function(start_reader, 4) do
    case make_control_files() do
      {:ok, %{path: control_path, secret_path: secret_path, proofs: proofs}} ->
        ref = make_ref()
        parent = self()

        case start_reader.(parent, ref, control_path, proofs) do
          {:ok, reader, reader_os_pid} ->
            status_control = %StatusControl{
              ref: ref,
              reader: reader,
              reader_os_pid: reader_os_pid,
              path: control_path,
              secret_path: secret_path,
              proofs: proofs
            }

            {:ok, {guarded_command(command, control_path, secret_path), status_control}}

          {:error, reason} ->
            File.rm(control_path)
            File.rm(secret_path)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec cleanup_status_control(StatusControl.t() | nil) :: :ok
  def cleanup_status_control(nil), do: :ok

  def cleanup_status_control(%StatusControl{reader: reader, path: path, secret_path: secret_path}) do
    stop_control_reader(reader)

    File.rm(path)
    File.rm(secret_path)
    :ok
  end

  @spec status_message(StatusControl.t(), term()) :: {:ok, non_neg_integer()} | {:error, term()} | :nomatch
  def status_message(%StatusControl{ref: ref}, {@control_message, ref, result}), do: result
  def status_message(%StatusControl{}, _message), do: :nomatch
  def status_message(nil, _message), do: :nomatch

  @spec status_control_ref(StatusControl.t() | nil) :: reference() | nil
  def status_control_ref(%StatusControl{ref: ref}), do: ref
  def status_control_ref(nil), do: nil

  if Mix.env() == :test do
    @doc false
    @spec make_control_fifo_for_test() :: {:ok, Path.t()} | {:error, term()}
    def make_control_fifo_for_test, do: make_control_fifo()

    @doc false
    @spec make_control_fifo_for_test(Path.t()) :: {:ok, Path.t()} | {:error, term()}
    def make_control_fifo_for_test(control_dir), do: make_control_fifo(control_dir)

    @doc false
    @spec read_control_line_for_test(Path.t()) :: {:ok, binary()} | {:error, term()}
    def read_control_line_for_test(path), do: read_control_line(path)

    @doc false
    @spec start_guarded_command_for_test([String.t()], function()) ::
            {:ok, {[String.t()], StatusControl.t()}} | {:error, term()}
    def start_guarded_command_for_test(command, start_reader), do: start_guarded_command(command, start_reader)

    @doc false
    @spec start_control_reader_for_test(function(), non_neg_integer()) ::
            {:ok, pid(), non_neg_integer()} | {:error, term()}
    def start_control_reader_for_test(exec_runner, timeout_ms) do
      start_control_reader(self(), make_ref(), "unused-control", control_proofs(), exec_runner, timeout_ms)
    end

    @doc false
    @spec collect_control_status_for_test(list(), tuple()) :: {:ok, non_neg_integer()} | {:error, term()}
    def collect_control_status_for_test(events, proofs) do
      exec_pid = self()
      exec_ref = Process.monitor(exec_pid)
      os_pid = System.unique_integer([:positive])
      ref = make_ref()

      Enum.each(events, fn
        {:stdout, data} -> send(self(), {:stdout, os_pid, data})
        {:stderr, data} -> send(self(), {:stderr, os_pid, data})
        {:exit, reason} -> send(self(), {:EXIT, exec_pid, reason})
        {:down, reason} -> send(self(), {:DOWN, exec_ref, :process, exec_pid, reason})
      end)

      collect_control_status(self(), ref, exec_pid, exec_ref, os_pid, proofs, "", "")
      Process.demonitor(exec_ref, [:flush])

      receive do
        {@control_message, ^ref, result} -> result
      end
    end

    @doc false
    @spec stop_control_reader_for_test(pid(), non_neg_integer()) :: :ok
    def stop_control_reader_for_test(reader, timeout_ms), do: stop_control_reader(reader, timeout_ms)

    @doc false
    @spec write_control_secret_for_test(Path.t(), iodata()) :: {:ok, Path.t()} | {:error, term()}
    def write_control_secret_for_test(control_path, secret), do: write_control_secret(control_path, secret)

    @doc false
    @spec protect_write_and_close_control_secret_for_test(term(), Path.t(), iodata()) :: :ok | {:error, term()}
    def protect_write_and_close_control_secret_for_test(io, secret_path, secret) do
      protect_write_and_close_control_secret(io, secret_path, secret)
    end

    @doc false
    @spec parse_control_status_for_test(binary(), tuple()) ::
            {:ok, non_neg_integer()} | {:error, :invalid_control_status}
    def parse_control_status_for_test(line, proofs), do: parse_control_status(line, proofs)

    @doc false
    @spec decode_exec_status_for_test(integer()) :: non_neg_integer()
    def decode_exec_status_for_test(status), do: decode_exec_status(status)

    @doc false
    @spec drain_output_for_test(integer(), iodata(), iodata(), [stream_event()]) ::
            {iodata(), iodata(), [stream_event()]}
    def drain_output_for_test(os_pid, stdout, stderr, events), do: drain_output(os_pid, stdout, stderr, events)

    defp read_control_line(control_path) do
      case System.cmd("/bin/sh", ["-c", @control_reader_script, "--", control_path], stderr_to_stdout: true) do
        {line, 0} -> {:ok, line}
        {output, status} -> {:error, {:control_read_failed, status, output}}
      end
    end
  end

  @spec run([String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(command, opts \\ []) when is_list(command) and is_list(opts) do
    with :ok <- validate_working_directory(opts),
         {:ok, _apps} <- Application.ensure_all_started(:erlexec) do
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        guarded? = Keyword.get(opts, :guarded, true)

        with {:ok, command, status_control} <- maybe_guard_command(command, guarded?) do
          try do
            case :exec.run_link(command, exec_options(opts)) do
              {:ok, exec_pid, os_pid} ->
                exec_ref = Process.monitor(exec_pid)

                collect(%{
                  exec_pid: exec_pid,
                  exec_ref: exec_ref,
                  os_pid: os_pid,
                  stdout: [],
                  stderr: [],
                  events: [],
                  status_control: status_control,
                  deadline: deadline(opts),
                  stop_timeout_ms: stop_timeout_ms(opts),
                  caller_ref: Keyword.get(opts, :caller_ref)
                })

              {:error, reason} ->
                {:error, reason}
            end
          after
            cleanup_status_control(status_control)
          end
        end
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end
    end
  end

  @spec take_status(String.t(), iodata()) :: {non_neg_integer() | nil, String.t()}
  def take_status(buffer, data) when is_binary(buffer) do
    {status, _stderr, pending} = take_status_and_stderr(@status_marker_prefix, buffer, data)
    {status, pending}
  end

  @spec take_status_and_stderr(String.t(), iodata()) ::
          {non_neg_integer() | nil, binary(), String.t()}
  def take_status_and_stderr(buffer, data) when is_binary(buffer) do
    take_status_and_stderr(@status_marker_prefix, buffer, data)
  end

  @spec take_status_and_stderr(String.t(), String.t(), iodata()) ::
          {non_neg_integer() | nil, binary(), String.t()}
  def take_status_and_stderr(status_marker, buffer, data)
      when is_binary(status_marker) and is_binary(buffer) do
    combined = buffer <> IO.iodata_to_binary(data)
    parts = String.split(combined, "\n", trim: false)
    {complete, [pending]} = Enum.split(parts, -1)

    {status, stderr_lines} =
      Enum.reduce(complete, {nil, []}, fn line, {status, lines} ->
        case parse_status_line(status_marker, line) do
          parsed when is_integer(parsed) -> {status || parsed, lines}
          nil -> {status, [line | lines]}
        end
      end)

    stderr =
      case Enum.reverse(stderr_lines) do
        [] -> ""
        lines -> Enum.join(lines, "\n") <> "\n"
      end

    {status, stderr, pending}
  end

  defp exec_options(opts) do
    [
      {:stdout, self()},
      {:stderr, self()},
      {:group, 0},
      :kill_group,
      {:kill_timeout, 1}
    ]
    |> maybe_put_cd(Keyword.get(opts, :cd))
    |> maybe_put_env(Keyword.get(opts, :env))
  end

  defp validate_working_directory(opts) do
    case Keyword.get(opts, :cd) do
      cd when is_binary(cd) ->
        if File.dir?(cd), do: :ok, else: {:error, :invalid_working_directory}

      _cd ->
        :ok
    end
  end

  defp maybe_put_cd(options, cd) when is_binary(cd), do: [{:cd, cd} | options]
  defp maybe_put_cd(options, _cd), do: options

  defp maybe_put_env(options, env) when is_list(env), do: [{:env, normalize_env(env)} | options]
  defp maybe_put_env(options, _env), do: options

  defp normalize_env(env) do
    Enum.map(env, fn
      {key, nil} -> {key, false}
      {key, value} -> {key, value}
    end)
  end

  defp maybe_guard_command(command, false), do: {:ok, command, nil}

  defp maybe_guard_command(command, true) do
    case start_guarded_command(command) do
      {:ok, {guarded_command, status_control}} -> {:ok, guarded_command, status_control}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deadline(opts) do
    case Keyword.get(opts, :timeout_ms, :infinity) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms >= 0 ->
        System.monotonic_time(:millisecond) + timeout_ms

      _timeout ->
        :infinity
    end
  end

  defp collect(state) do
    %{
      exec_pid: exec_pid,
      exec_ref: exec_ref,
      os_pid: os_pid,
      stdout: stdout,
      stderr: stderr,
      events: events,
      status_control: status_control,
      deadline: deadline,
      stop_timeout_ms: stop_timeout_ms,
      caller_ref: caller_ref
    } = state

    control_ref = status_control_ref(status_control)

    receive do
      {@control_message, ^control_ref, {:ok, status}} when is_reference(control_ref) ->
        {stdout, stderr, events} = drain_output(os_pid, stdout, stderr, events)
        stop_exec_process(exec_pid, exec_ref, stop_timeout_ms)
        {:ok, output(status, stdout, stderr, events)}

      {@control_message, ^control_ref, {:error, reason}} when is_reference(control_ref) ->
        stop_exec_process(exec_pid, exec_ref, stop_timeout_ms)
        {:error, reason}

      {:stdout, ^os_pid, data} ->
        data = IO.iodata_to_binary(data)

        collect(%{state | stdout: [stdout, data], events: [{:stdout, data} | events]})

      {:stderr, ^os_pid, data} ->
        data = IO.iodata_to_binary(data)

        collect(%{
          state
          | stderr: append_stream(stderr, data),
            events: append_event(events, :stderr, data)
        })

      {:EXIT, ^exec_pid, {:exit_status, status}} ->
        Process.demonitor(exec_ref, [:flush])
        {:ok, output(decode_exec_status(status), stdout, stderr, events)}

      {:EXIT, ^exec_pid, :normal} ->
        Process.demonitor(exec_ref, [:flush])
        {:ok, output(0, stdout, stderr, events)}

      {:DOWN, ^exec_ref, :process, ^exec_pid, reason} ->
        {:error, reason}

      {:DOWN, ^caller_ref, :process, _pid, _reason} when is_reference(caller_ref) ->
        stop_exec_process(exec_pid, exec_ref, stop_timeout_ms)
        {:error, :caller_down}
    after
      remaining_ms(deadline) ->
        stop_exec_process(exec_pid, exec_ref, stop_timeout_ms)
        {:error, :timeout}
    end
  end

  defp append_stream(stream, ""), do: stream
  defp append_stream(stream, data), do: [stream, data]

  defp append_event(events, _stream, ""), do: events
  defp append_event(events, stream, data), do: [{stream, data} | events]

  defp drain_output(os_pid, stdout, stderr, events) do
    receive do
      {:stdout, ^os_pid, data} ->
        data = IO.iodata_to_binary(data)
        drain_output(os_pid, [stdout, data], stderr, [{:stdout, data} | events])

      {:stderr, ^os_pid, data} ->
        data = IO.iodata_to_binary(data)
        drain_output(os_pid, stdout, append_stream(stderr, data), append_event(events, :stderr, data))
    after
      50 -> {stdout, stderr, events}
    end
  end

  defp output(status, stdout, stderr, events) do
    %{
      status: status,
      stdout: IO.iodata_to_binary(stdout),
      stderr: IO.iodata_to_binary(stderr),
      output: Enum.reverse(events)
    }
  end

  defp stop_exec_process(exec_pid, exec_ref, timeout_ms) when is_pid(exec_pid) do
    :exec.stop_and_wait(exec_pid, timeout_ms)
    Process.demonitor(exec_ref, [:flush])
  end

  defp stop_timeout_ms(opts) do
    case Keyword.get(opts, :stop_timeout_ms, @default_stop_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms >= 0 -> timeout_ms
      _timeout_ms -> @default_stop_timeout_ms
    end
  end

  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp decode_exec_status(status) when is_integer(status) do
    case :exec.status(status) do
      {:status, exit_status} -> exit_status
      {:signal, signal, _core_dump?} -> 128 + Map.get(@signal_numbers, signal, 0)
    end
  end

  defp make_control_fifo do
    System.tmp_dir!()
    |> Path.join("symphony-exec-control")
    |> make_control_fifo()
  end

  defp make_control_fifo(control_dir) do
    control_name = "status-#{System.unique_integer([:positive, :monotonic])}-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
    control_path = Path.join(control_dir, control_name)

    with :ok <- File.mkdir_p(control_dir),
         {"", 0} <- System.cmd("mkfifo", [control_path], stderr_to_stdout: true) do
      {:ok, control_path}
    else
      {:error, reason} ->
        {:error, reason}

      {output, status} when is_binary(output) and is_integer(status) ->
        {:error, {:mkfifo_failed, status, output}}
    end
  end

  defp make_control_files do
    proofs = control_proofs()
    secret = proofs |> Tuple.to_list() |> Enum.intersperse("\n") |> then(&[&1, "\n"])

    with {:ok, control_path} <- make_control_fifo(),
         {:ok, secret_path} <- write_control_secret(control_path, secret) do
      {:ok, %{path: control_path, secret_path: secret_path, proofs: proofs}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_control_secret(control_path, secret) when is_binary(control_path) do
    secret_path = control_path <> ".secret"

    with {:ok, io} <- File.open(secret_path, [:write, :binary, :exclusive]),
         :ok <- protect_write_and_close_control_secret(io, secret_path, secret) do
      {:ok, secret_path}
    else
      {:error, reason} ->
        File.rm(secret_path)
        File.rm(control_path)
        {:error, reason}
    end
  end

  defp protect_write_and_close_control_secret(io, secret_path, secret) do
    case File.chmod(secret_path, 0o600) do
      :ok -> IO.binwrite(io, secret)
      {:error, _reason} = error -> error
    end
  after
    File.close(io)
  end

  defp control_proofs do
    0..255
    |> Enum.map(fn _status -> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false) end)
    |> List.to_tuple()
  end

  defp guarded_command(command, control_path, secret_path)
       when is_list(command) and is_binary(control_path) and is_binary(secret_path) do
    ["/bin/sh", "-c", guarded_script(), "--", control_path, secret_path | command]
  end

  defp guarded_script do
    """
    trap 'while :; do sleep 1; done' TERM

    control_path=$1
    secret_path=$2
    shift 2

    control_proofs=
    while IFS= read -r candidate; do
      control_proofs="${control_proofs}${candidate}
    "
    done < "$secret_path"

    if ! rm -f -- "$secret_path" || [ -e "$secret_path" ]; then
      control_proofs=
      exit 127
    fi

    if [ -z "$control_proofs" ]; then
      exit 127
    fi

    exec 3>"$control_path"

    "$@" <&0 3>&- &
    child=$!
    wait "$child"
    status=$?

    old_ifs=$IFS
    IFS='
    '
    set -- $control_proofs
    IFS=$old_ifs
    control_proofs=

    control_proof=
    proof_index=0
    for candidate do
      if [ "$proof_index" -eq "$status" ]; then
        control_proof=$candidate
        break
      fi
      proof_index=$((proof_index + 1))
    done

    if [ -z "$control_proof" ]; then
      exit 127
    fi

    printf '%s:%s\\n' "$status" "$control_proof" >&3
    control_proof=
    exec 3>&-

    while :; do
      sleep 1
    done
    """
  end

  defp start_control_reader(parent, ref, control_path, proofs) do
    start_control_reader(
      parent,
      ref,
      control_path,
      proofs,
      &:exec.run_link/2,
      @control_reader_start_timeout_ms
    )
  end

  defp start_control_reader(parent, ref, control_path, proofs, exec_runner, timeout_ms) do
    starter = self()

    reader =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        case exec_runner.(
               ["/bin/sh", "-c", @control_reader_script, "--", control_path],
               [{:stdout, self()}, {:stderr, self()}, {:group, 0}, :kill_group, {:kill_timeout, 1}]
             ) do
          {:ok, exec_pid, os_pid} ->
            exec_ref = Process.monitor(exec_pid)
            send(starter, {@control_reader_message, :started, self(), os_pid})
            collect_control_status(parent, ref, exec_pid, exec_ref, os_pid, proofs, "", "")

          {:error, reason} ->
            send(starter, {@control_reader_message, :start_failed, self(), reason})
        end
      end)

    receive do
      {@control_reader_message, :started, ^reader, os_pid} ->
        {:ok, reader, os_pid}

      {@control_reader_message, :start_failed, ^reader, reason} ->
        {:error, {:control_reader_start_failed, reason}}
    after
      timeout_ms ->
        Process.exit(reader, :kill)
        {:error, :control_reader_start_timeout}
    end
  end

  defp collect_control_status(parent, ref, exec_pid, exec_ref, os_pid, proofs, stdout, stderr) do
    receive do
      {:stdout, ^os_pid, data} ->
        stdout = stdout <> IO.iodata_to_binary(data)

        case String.split(stdout, "\n", parts: 2) do
          [line, _rest] ->
            send(parent, {@control_message, ref, parse_control_status(line <> "\n", proofs)})
            Process.demonitor(exec_ref, [:flush])

          [_pending] ->
            collect_control_status(parent, ref, exec_pid, exec_ref, os_pid, proofs, stdout, stderr)
        end

      {:stderr, ^os_pid, data} ->
        collect_control_status(
          parent,
          ref,
          exec_pid,
          exec_ref,
          os_pid,
          proofs,
          stdout,
          stderr <> IO.iodata_to_binary(data)
        )

      {:EXIT, ^exec_pid, {:exit_status, status}} ->
        Process.demonitor(exec_ref, [:flush])
        send(parent, {@control_message, ref, {:error, {:control_read_failed, status, stderr}}})

      {:EXIT, ^exec_pid, reason} ->
        Process.demonitor(exec_ref, [:flush])
        send(parent, {@control_message, ref, {:error, {:control_read_failed, reason, stderr}}})

      {:DOWN, ^exec_ref, :process, ^exec_pid, reason} ->
        send(parent, {@control_message, ref, {:error, {:control_read_failed, reason, stderr}}})

      {@control_reader_message, :stop, from, stop_ref} ->
        stop_control_reader_exec(exec_pid, exec_ref)
        send(from, {@control_reader_message, :stopped, stop_ref})
    end
  end

  defp stop_control_reader(reader) when is_pid(reader) do
    stop_control_reader(reader, @default_stop_timeout_ms + 500)
  end

  defp stop_control_reader(reader, timeout_ms) when is_pid(reader) and is_integer(timeout_ms) do
    if Process.alive?(reader) do
      stop_ref = make_ref()
      monitor_ref = Process.monitor(reader)
      send(reader, {@control_reader_message, :stop, self(), stop_ref})

      receive do
        {@control_reader_message, :stopped, ^stop_ref} -> :ok
        {:DOWN, ^monitor_ref, :process, ^reader, _reason} -> :ok
      after
        timeout_ms -> Process.exit(reader, :kill)
      end

      Process.demonitor(monitor_ref, [:flush])
    end

    :ok
  end

  defp stop_control_reader_exec(exec_pid, exec_ref) do
    if Process.alive?(exec_pid), do: :exec.stop_and_wait(exec_pid, @default_stop_timeout_ms)
    Process.demonitor(exec_ref, [:flush])
    :ok
  end

  defp parse_control_status(line, proofs) when is_binary(line) and is_tuple(proofs) do
    status_line = String.trim_trailing(line, "\n")

    case String.split(status_line, ":", parts: 2) do
      [status_text, proof] -> parse_control_status_proof(status_text, proof, proofs)
      _invalid -> {:error, :invalid_control_status}
    end
  end

  defp parse_control_status_proof(status_text, proof, proofs) do
    case Integer.parse(status_text) do
      {status, ""} when status in 0..255 ->
        if valid_control_proof?(elem(proofs, status), proof),
          do: {:ok, status},
          else: {:error, :invalid_control_status}

      _invalid ->
        {:error, :invalid_control_status}
    end
  end

  defp valid_control_proof?(expected, proof)
       when is_binary(expected) and is_binary(proof) and byte_size(expected) == byte_size(proof) do
    Plug.Crypto.secure_compare(expected, proof)
  end

  defp valid_control_proof?(_expected, _proof), do: false

  defp parse_status_line(status_marker, line) do
    case String.split_at(line, byte_size(status_marker)) do
      {^status_marker, status} -> parse_status_value(status)
      _other -> nil
    end
  end

  defp parse_status_value(status) do
    case Integer.parse(status) do
      {status, ""} when status in 0..255 -> status
      _invalid -> nil
    end
  end
end
