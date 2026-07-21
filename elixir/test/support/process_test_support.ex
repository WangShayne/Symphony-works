defmodule SymphonyElixir.ProcessTestSupport do
  @moduledoc false

  import ExUnit.Assertions, only: [assert: 2]

  @spec read_pid(Path.t()) :: integer() | nil
  def read_pid(path) do
    case File.read(path) do
      {:ok, pid} ->
        pid
        |> String.trim()
        |> Integer.parse()
        |> case do
          {pid, ""} -> pid
          _invalid -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  @spec refute_os_process_alive(integer()) :: true
  def refute_os_process_alive(pid) when is_integer(pid) do
    assert eventually_value(fn ->
             if not os_process_alive?(pid), do: true
           end),
           "expected OS process #{pid} to stop"
  end

  @spec monitored_process(pid()) :: pid() | nil
  def monitored_process(pid) do
    case Process.info(pid, :monitors) do
      {:monitors, monitors} ->
        Enum.find_value(monitors, fn
          {:process, monitored_pid} -> monitored_pid
          _other -> nil
        end)

      nil ->
        nil
    end
  end

  @spec eventually_value((-> result)) :: result | nil when result: var
  @spec eventually_value((-> result), non_neg_integer()) :: result | nil when result: var
  def eventually_value(fun, attempts \\ 200)
  def eventually_value(_fun, 0), do: nil

  def eventually_value(fun, attempts) do
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

  @spec os_process_alive?(integer()) :: boolean()
  def os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
