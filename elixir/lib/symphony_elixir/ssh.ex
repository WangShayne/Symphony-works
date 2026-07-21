defmodule SymphonyElixir.SSH do
  @moduledoc false

  alias SymphonyElixir.ExecCommand

  defmodule Stream do
    @moduledoc false

    @enforce_keys [:owner, :os_pid]
    defstruct [:owner, :exec_pid, :os_pid]

    @type t :: %__MODULE__{owner: pid(), exec_pid: pid() | nil, os_pid: non_neg_integer()}
  end

  @signal_numbers %{
    sighup: 1,
    sigint: 2,
    sigquit: 3,
    sigill: 4,
    sigtrap: 5,
    sigabrt: 6,
    sigbus: 7,
    sigfpe: 8,
    sigkill: 9,
    sigsegv: 11,
    sigpipe: 13,
    sigalrm: 14,
    sigterm: 15,
    sigstkflt: 16,
    sigchld: 17,
    sigcont: 18,
    sigstop: 19,
    sigtstp: 20,
    sigttin: 21,
    sigttou: 22,
    sigurg: 23,
    sigxcpu: 24,
    sigxfsz: 25,
    sigvtalrm: 26,
    sigprof: 27,
    sigwinch: 28,
    sigio: 29,
    sigpwr: 30,
    sigsys: 31,
    sigrtmin: 34,
    sigrtmax: 64
  }

  @exec_stop_timeout_ms 2_500
  @owner_shutdown_grace_ms @exec_stop_timeout_ms * 2 + 1_000

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, _apps} <- Application.ensure_all_started(:erlexec),
         {:ok, executable} <- ssh_executable(),
         {:ok, args} <- ssh_args(host, command) do
      run_owned_ssh_command([executable | args], opts)
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, Stream.t()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, _apps} <- Application.ensure_all_started(:erlexec),
         {:ok, executable} <- ssh_executable(),
         {:ok, args} <- ssh_args(host, command) do
      start_owned_ssh_stream([executable | args], opts)
    end
  end

  @spec send_data(Stream.t(), iodata()) :: boolean()
  def send_data(%Stream{owner: owner}, data) do
    ref = make_ref()
    send(owner, {:send_data, self(), ref, IO.iodata_to_binary(data)})

    receive do
      {^ref, :ok} -> true
      {^ref, {:error, _reason}} -> false
    after
      5_000 -> false
    end
  end

  @spec close_stream(Stream.t()) :: :ok
  def close_stream(%Stream{owner: owner}) do
    ref = make_ref()
    send(owner, {:close_stream, self(), ref})

    receive do
      {^ref, :ok} -> :ok
    after
      5_000 -> :ok
    end
  end

  @spec os_pid(Stream.t()) :: non_neg_integer()
  def os_pid(%Stream{os_pid: os_pid}), do: os_pid

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  @spec validate_destination(String.t()) :: :ok | {:error, :invalid_ssh_destination}
  def validate_destination(destination) when is_binary(destination) do
    case parse_target(destination) do
      {:ok, _parsed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_destination(_destination), do: {:error, :invalid_ssh_destination}

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp ssh_args(host, command) do
    case parse_target(host) do
      {:ok, %{destination: destination, port: port}} ->
        args =
          []
          |> maybe_put_config()
          |> Kernel.++(["-T"])
          |> maybe_put_port(port)
          |> Kernel.++(["--", destination, remote_shell_command(command)])

        {:ok, args}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_owned_ssh_command(command, opts) do
    caller = self()
    ref = make_ref()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        caller_ref = Process.monitor(caller)

        result =
          with {:ok, {guarded_command, status_control}} <- ExecCommand.start_guarded_command(command) do
            try do
              run_exec_ssh_command(guarded_command, opts, caller_ref, status_control)
            after
              ExecCommand.cleanup_status_control(status_control)
            end
          end

        send(caller, {ref, result})
      end)

    owner_ref = Process.monitor(owner)
    await_ssh_owner(owner, owner_ref, ref, Keyword.get(opts, :timeout_ms, :infinity))
  end

  defp await_ssh_owner(owner, owner_ref, ref, :infinity) do
    receive do
      {^ref, result} ->
        Process.demonitor(owner_ref, [:flush])
        result

      {:DOWN, ^owner_ref, :process, ^owner, reason} ->
        {:error, reason}
    end
  end

  defp await_ssh_owner(owner, owner_ref, ref, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    receive do
      {^ref, result} ->
        Process.demonitor(owner_ref, [:flush])
        result

      {:DOWN, ^owner_ref, :process, ^owner, reason} ->
        {:error, reason}
    after
      timeout_ms + @owner_shutdown_grace_ms ->
        kill_owner_and_wait(owner, owner_ref)
        {:error, :timeout}
    end
  end

  defp start_owned_ssh_stream(command, opts) do
    caller = self()
    ref = make_ref()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        caller_ref = Process.monitor(caller)

        case ExecCommand.start_guarded_command(command) do
          {:ok, {guarded_command, status_control}} ->
            start_guarded_ssh_stream(guarded_command, status_control, opts, caller, caller_ref, ref)

          {:error, reason} ->
            send(caller, {ref, {:error, reason}})
        end
      end)

    owner_ref = Process.monitor(owner)

    receive do
      {^ref, {:ok, _stream} = result} ->
        Process.demonitor(owner_ref, [:flush])
        result

      {^ref, {:error, _reason} = error} ->
        Process.demonitor(owner_ref, [:flush])
        error

      {:DOWN, ^owner_ref, :process, ^owner, reason} ->
        {:error, reason}
    after
      5_000 ->
        kill_owner_and_wait(owner, owner_ref)
        {:error, :timeout}
    end
  end

  defp start_guarded_ssh_stream(guarded_command, status_control, opts, caller, caller_ref, ref) do
    case :exec.run_link(guarded_command, stream_exec_options(opts)) do
      {:ok, exec_pid, os_pid} ->
        exec_ref = Process.monitor(exec_pid)
        stream = %Stream{owner: self(), exec_pid: exec_pid, os_pid: os_pid}
        send(caller, {ref, {:ok, stream}})

        stream_loop(%{
          stream: stream,
          exec_pid: exec_pid,
          exec_ref: exec_ref,
          os_pid: os_pid,
          caller: caller,
          caller_ref: caller_ref,
          line_bytes: Keyword.get(opts, :line),
          line_buffer: "",
          status_control: status_control
        })

      {:error, reason} ->
        ExecCommand.cleanup_status_control(status_control)
        send(caller, {ref, {:error, reason}})
    end
  end

  defp run_exec_ssh_command(command, opts, caller_ref, status_control) do
    case :exec.run_link(command, exec_options(opts)) do
      {:ok, exec_pid, os_pid} ->
        exec_ref = Process.monitor(exec_pid)
        collect_exec_ssh(exec_pid, exec_ref, os_pid, [], ssh_deadline(opts), caller_ref, status_control)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exec_options(_opts) do
    [
      {:stdout, self()},
      {:stderr, self()},
      {:env, Map.to_list(System.get_env())},
      {:group, 0},
      :kill_group,
      {:kill_timeout, 1}
    ]
  end

  defp stream_exec_options(_opts) do
    [
      :stdin,
      {:stdout, self()},
      {:stderr, self()},
      {:env, Map.to_list(System.get_env())},
      {:group, 0},
      :kill_group,
      {:kill_timeout, 1}
    ]
  end

  defp ssh_deadline(opts) do
    case Keyword.get(opts, :timeout_ms, :infinity) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms >= 0 ->
        System.monotonic_time(:millisecond) + timeout_ms

      _timeout ->
        :infinity
    end
  end

  defp collect_exec_ssh(exec_pid, exec_ref, os_pid, output, deadline, caller_ref, status_control) do
    control_ref = ExecCommand.status_control_ref(status_control)

    receive do
      {{SymphonyElixir.ExecCommand, :status}, ^control_ref, {:ok, status}} when is_reference(control_ref) ->
        output = drain_exec_output(os_pid, output)
        stop_exec_process(exec_pid, exec_ref)
        {:ok, {IO.iodata_to_binary(output), status}}

      {{SymphonyElixir.ExecCommand, :status}, ^control_ref, {:error, reason}} when is_reference(control_ref) ->
        stop_exec_process(exec_pid, exec_ref)
        {:error, reason}

      {:stdout, ^os_pid, data} ->
        collect_exec_ssh(exec_pid, exec_ref, os_pid, [output, data], deadline, caller_ref, status_control)

      {:stderr, ^os_pid, data} ->
        collect_exec_ssh(exec_pid, exec_ref, os_pid, [output, data], deadline, caller_ref, status_control)

      {:EXIT, ^exec_pid, {:exit_status, status}} ->
        Process.demonitor(exec_ref, [:flush])
        {:ok, {IO.iodata_to_binary(output), decode_exec_status(status)}}

      {:EXIT, ^exec_pid, :normal} ->
        Process.demonitor(exec_ref, [:flush])
        {:ok, {IO.iodata_to_binary(output), 0}}

      {:DOWN, ^exec_ref, :process, ^exec_pid, reason} ->
        {:error, exec_down_reason(reason)}

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        stop_exec_process(exec_pid, exec_ref)
        {:error, :caller_down}
    after
      ssh_remaining_ms(deadline) ->
        stop_exec_process(exec_pid, exec_ref)
        {:error, :timeout}
    end
  end

  defp stream_loop(state) do
    %{
      stream: stream,
      exec_pid: exec_pid,
      exec_ref: exec_ref,
      os_pid: os_pid,
      caller: caller,
      caller_ref: caller_ref,
      line_bytes: line_bytes,
      line_buffer: line_buffer,
      status_control: status_control
    } = state

    control_ref = ExecCommand.status_control_ref(status_control)

    receive do
      {{SymphonyElixir.ExecCommand, :status}, ^control_ref, {:ok, status}} when is_reference(control_ref) ->
        line_buffer = drain_stream_output(stream, caller, os_pid, line_bytes, line_buffer)
        flush_stream_line(stream, caller, line_buffer)
        stop_exec_process(exec_pid, exec_ref)
        ExecCommand.cleanup_status_control(status_control)
        send(caller, {stream, {:exit_status, status}})

      {{SymphonyElixir.ExecCommand, :status}, ^control_ref, {:error, _reason}} when is_reference(control_ref) ->
        flush_stream_line(stream, caller, line_buffer)
        stop_exec_process(exec_pid, exec_ref)
        ExecCommand.cleanup_status_control(status_control)
        send(caller, {stream, {:exit_status, 1}})

      {:stdout, ^os_pid, data} ->
        line_buffer = forward_stream_data(stream, caller, line_bytes, line_buffer, data)
        stream_loop(%{state | line_buffer: line_buffer})

      {:stderr, ^os_pid, data} ->
        line_buffer = forward_stream_data(stream, caller, line_bytes, line_buffer, data)
        stream_loop(%{state | line_buffer: line_buffer})

      {:send_data, from, ref, data} ->
        send(from, {ref, :exec.send(exec_pid, data)})
        stream_loop(state)

      {:close_stream, from, ref} ->
        stop_exec_process(exec_pid, exec_ref)
        ExecCommand.cleanup_status_control(status_control)
        send(from, {ref, :ok})

      {:EXIT, ^exec_pid, reason} ->
        Process.demonitor(exec_ref, [:flush])
        flush_stream_line(stream, caller, line_buffer)
        ExecCommand.cleanup_status_control(status_control)
        send(caller, {stream, {:exit_status, exec_exit_status(reason)}})

      {:DOWN, ^exec_ref, :process, ^exec_pid, reason} ->
        flush_stream_line(stream, caller, line_buffer)
        ExecCommand.cleanup_status_control(status_control)
        send(caller, {stream, {:exit_status, exec_exit_status(reason)}})

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        stop_exec_process(exec_pid, exec_ref)
        ExecCommand.cleanup_status_control(status_control)
    end
  end

  defp ssh_remaining_ms(:infinity), do: :infinity
  defp ssh_remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp stop_exec_process(exec_pid, exec_ref) when is_pid(exec_pid) do
    :exec.stop_and_wait(exec_pid, @exec_stop_timeout_ms)
    Process.demonitor(exec_ref, [:flush])
  end

  defp drain_exec_output(os_pid, output) do
    receive do
      {:stdout, ^os_pid, data} ->
        drain_exec_output(os_pid, [output, data])

      {:stderr, ^os_pid, data} ->
        drain_exec_output(os_pid, [output, data])
    after
      50 -> output
    end
  end

  defp drain_stream_output(stream, caller, os_pid, line_bytes, line_buffer) do
    receive do
      {:stdout, ^os_pid, data} ->
        line_buffer = forward_stream_data(stream, caller, line_bytes, line_buffer, data)
        drain_stream_output(stream, caller, os_pid, line_bytes, line_buffer)

      {:stderr, ^os_pid, data} ->
        line_buffer = forward_stream_data(stream, caller, line_bytes, line_buffer, data)
        drain_stream_output(stream, caller, os_pid, line_bytes, line_buffer)
    after
      50 -> line_buffer
    end
  end

  defp kill_owner_and_wait(owner, owner_ref) do
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp forward_stream_data(stream, caller, nil, line_buffer, data) do
    send(caller, {stream, {:data, IO.iodata_to_binary(data)}})
    line_buffer
  end

  defp forward_stream_data(stream, caller, line_bytes, line_buffer, data)
       when is_integer(line_bytes) and line_bytes > 0 do
    combined = line_buffer <> IO.iodata_to_binary(data)
    parts = String.split(combined, "\n")
    {complete_lines, [pending]} = Enum.split(parts, -1)

    Enum.each(complete_lines, fn line ->
      send(caller, {stream, {:data, {:eol, line}}})
    end)

    if byte_size(pending) >= line_bytes do
      send(caller, {stream, {:data, {:noeol, pending}}})
      ""
    else
      pending
    end
  end

  defp forward_stream_data(stream, caller, _line_bytes, line_buffer, data),
    do: forward_stream_data(stream, caller, nil, line_buffer, data)

  defp flush_stream_line(_stream, _caller, ""), do: :ok
  defp flush_stream_line(stream, caller, line_buffer), do: send(caller, {stream, {:data, {:noeol, line_buffer}}})

  defp exec_exit_status(:normal), do: 0
  defp exec_exit_status({:exit_status, status}), do: decode_exec_status(status)
  defp exec_exit_status(_reason), do: 1

  defp exec_down_reason(:normal), do: :normal
  defp exec_down_reason({:exit_status, status}), do: {:exit_status, decode_exec_status(status)}
  defp exec_down_reason(reason), do: reason

  defp decode_exec_status(status) when is_integer(status) do
    case :exec.status(status) do
      {:status, exit_status} -> exit_status
      {:signal, signal, _core_dump?} -> 128 + signal_number(signal)
    end
  end

  defp signal_number(signal) when is_integer(signal), do: signal
  defp signal_number(signal), do: Map.get(@signal_numbers, signal, 0)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp parse_target(target) when is_binary(target) do
    with true <- target == String.trim(target),
         false <- Regex.match?(~r/[\s\x00-\x1F\x7F]/u, target),
         false <- String.starts_with?(target, "-"),
         {:ok, parsed} <- parse_supported_target(target) do
      {:ok, parsed}
    else
      _invalid -> {:error, :invalid_ssh_destination}
    end
  end

  defp parse_supported_target(target) do
    case Regex.run(~r/^(?:([A-Za-z0-9._%+-]+)@)?(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(?::([0-9]+))?$/, target) do
      [_match, user, host, port] -> build_target(user, host, port)
      [_match, user, host] -> build_target(user, host, nil)
      _invalid -> {:error, :invalid_ssh_destination}
    end
  end

  defp build_target(user, host, port) do
    with {:ok, normalized_port} <- normalize_port(port),
         :ok <- validate_host_token(host) do
      destination = if user == "", do: host, else: "#{user}@#{host}"
      {:ok, %{destination: destination, port: normalized_port}}
    else
      _invalid -> {:error, :invalid_ssh_destination}
    end
  end

  defp normalize_port(nil), do: {:ok, nil}

  defp normalize_port(port) do
    case Integer.parse(port) do
      {number, ""} when number in 1..65_535 -> {:ok, port}
      _invalid -> {:error, :invalid_ssh_destination}
    end
  end

  defp validate_host_token("[]"), do: {:error, :invalid_ssh_destination}
  defp validate_host_token("-" <> _host), do: {:error, :invalid_ssh_destination}

  defp validate_host_token("[" <> bracketed_host) do
    ipv6 = String.trim_trailing(bracketed_host, "]")

    if String.contains?(ipv6, ":") do
      case :inet.parse_ipv6_address(String.to_charlist(ipv6)) do
        {:ok, _address} -> :ok
        {:error, _reason} -> {:error, :invalid_ssh_destination}
      end
    else
      {:error, :invalid_ssh_destination}
    end
  end

  defp validate_host_token(_host), do: :ok

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
