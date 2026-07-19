defmodule SymphonyRunner.Policy do
  @moduledoc """
  Bounded sandbox policy values accepted by the Runner protocol.
  """

  alias SymphonyRunner.PathPolicy

  @enforce_keys [:image_digest, :cpu_millis, :memory_bytes, :network, :mounts]
  defstruct [:image_digest, :cpu_millis, :memory_bytes, :network, :mounts]

  @type mount :: %{
          required(:source) => String.t(),
          required(:target) => String.t(),
          required(:mode) => :ro | :rw
        }

  @type t :: %__MODULE__{
          image_digest: String.t(),
          cpu_millis: pos_integer(),
          memory_bytes: pos_integer(),
          network: :disabled | :egress,
          mounts: [mount()]
        }

  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = policy) do
    with :ok <- validate_digest(policy.image_digest),
         :ok <- validate_cpu(policy.cpu_millis),
         :ok <- validate_memory(policy.memory_bytes),
         :ok <- validate_network(policy.network),
         :ok <- validate_mounts(policy.mounts) do
      :ok
    end
  end

  def validate(_policy), do: {:error, :invalid_policy}

  @spec from_wire(map()) :: {:ok, t()} | {:error, atom()}
  def from_wire(%{
        "image_digest" => image_digest,
        "cpu_millis" => cpu_millis,
        "memory_bytes" => memory_bytes,
        "network" => network,
        "mounts" => mounts
      }) do
    with {:ok, parsed_network} <- parse_network(network),
         {:ok, parsed_mounts} <- parse_mounts(mounts) do
      policy = %__MODULE__{
        image_digest: image_digest,
        cpu_millis: cpu_millis,
        memory_bytes: memory_bytes,
        network: parsed_network,
        mounts: parsed_mounts
      }

      case validate(policy) do
        :ok -> {:ok, policy}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def from_wire(_wire), do: {:error, :invalid_policy}

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = policy) do
    %{
      "image_digest" => policy.image_digest,
      "cpu_millis" => policy.cpu_millis,
      "memory_bytes" => policy.memory_bytes,
      "network" => Atom.to_string(policy.network),
      "mounts" =>
        Enum.map(policy.mounts, fn mount ->
          %{
            "source" => mount.source,
            "target" => mount.target,
            "mode" => Atom.to_string(mount.mode)
          }
        end)
    }
  end

  defp validate_digest("sha256:" <> digest) when byte_size(digest) >= 3, do: :ok
  defp validate_digest(_digest), do: {:error, :invalid_image_digest}

  defp validate_cpu(cpu_millis) when is_integer(cpu_millis) and cpu_millis in 100..4_000,
    do: :ok

  defp validate_cpu(_cpu_millis), do: {:error, :invalid_cpu_millis}

  defp validate_memory(memory_bytes)
       when is_integer(memory_bytes) and memory_bytes in 67_108_864..8_589_934_592,
       do: :ok

  defp validate_memory(_memory_bytes), do: {:error, :invalid_memory_bytes}

  defp validate_network(network) when network in [:disabled, :egress], do: :ok
  defp validate_network(_network), do: {:error, :invalid_network}

  defp validate_mounts([_ | _] = mounts) do
    Enum.reduce_while(mounts, :ok, fn mount, :ok ->
      case validate_mount(mount) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_mounts(_mounts), do: {:error, :invalid_mounts}

  defp validate_mount(%{source: source, target: target, mode: mode})
       when is_binary(source) and is_binary(target) and mode in [:ro, :rw] do
    cond do
      not PathPolicy.safe_mount_source?(source) ->
        {:error, :invalid_mount_source}

      String.contains?(source, "docker.sock") ->
        {:error, :invalid_mount_source}

      not PathPolicy.workspace_path?(target) ->
        {:error, :invalid_mount_target}

      mode == :rw and not PathPolicy.writable_workspace_path?(target) ->
        {:error, :invalid_mount_mode}

      true ->
        :ok
    end
  end

  defp validate_mount(_mount), do: {:error, :invalid_mount}

  defp parse_network("disabled"), do: {:ok, :disabled}
  defp parse_network("egress"), do: {:ok, :egress}
  defp parse_network(_network), do: {:error, :invalid_network}

  defp parse_mounts([_ | _] = mounts) do
    mounts
    |> Enum.reduce_while({:ok, []}, fn
      %{"source" => source, "target" => target, "mode" => mode}, {:ok, parsed} ->
        with {:ok, parsed_mode} <- parse_mount_mode(mode) do
          {:cont, {:ok, [%{source: source, target: target, mode: parsed_mode} | parsed]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _mount, _parsed ->
        {:halt, {:error, :invalid_mount}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_mounts(_mounts), do: {:error, :invalid_mounts}

  defp parse_mount_mode("ro"), do: {:ok, :ro}
  defp parse_mount_mode("rw"), do: {:ok, :rw}
  defp parse_mount_mode(_mode), do: {:error, :invalid_mount_mode}
end
