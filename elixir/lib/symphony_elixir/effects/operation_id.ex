defmodule SymphonyElixir.Effects.OperationId do
  @moduledoc """
  Generates UUIDv7 operation identities and deterministic effect dedupe hashes.
  """

  import Bitwise

  @dedupe_fields [:task_id, :plan_revision, :unit_id, :action, :provider, :target]
  @uuid_v7 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @spec generate() :: Ecto.UUID.t()
  def generate do
    unix_ms = System.system_time(:millisecond) &&& 0xFFFFFFFFFFFF
    <<random::unsigned-integer-size(80)>> = :crypto.strong_rand_bytes(10)
    random_a = random >>> 68
    random_b = random &&& 0x3FFFFFFFFFFFFFFF

    [
      <<unix_ms::unsigned-integer-size(48)>>,
      <<7::unsigned-integer-size(4), random_a::unsigned-integer-size(12)>>,
      <<2::unsigned-integer-size(2), random_b::unsigned-integer-size(62)>>
    ]
    |> IO.iodata_to_binary()
    |> encode_uuid()
  end

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(@uuid_v7, String.downcase(value))
  def valid?(_value), do: false

  @spec dedupe_hash(map()) :: String.t()
  def dedupe_hash(attrs) when is_map(attrs) do
    attrs
    |> then(fn map -> Enum.map(@dedupe_fields, &fetch(map, &1)) end)
    |> Enum.map(&canonical/1)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_uuid(binary) do
    hex = Base.encode16(binary, case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp canonical(nil), do: <<0>>
  defp canonical(true), do: <<1, 1>>
  defp canonical(false), do: <<1, 0>>
  defp canonical(value) when is_integer(value), do: framed(2, Integer.to_string(value))
  defp canonical(value) when is_float(value), do: framed(3, :erlang.float_to_binary(value, [:compact]))
  defp canonical(value) when is_atom(value), do: framed(4, Atom.to_string(value))
  defp canonical(value) when is_binary(value), do: framed(5, value)

  defp canonical(value) when is_list(value) do
    value
    |> Enum.map(&canonical/1)
    |> IO.iodata_to_binary()
    |> framed(6)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {canonical(key), canonical(map_value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, map_value} -> [key, map_value] end)
    |> IO.iodata_to_binary()
    |> framed(7)
  end

  defp canonical(_value), do: <<8>>

  defp framed(payload, tag) when is_binary(payload) and is_integer(tag), do: framed(tag, payload)
  defp framed(tag, payload), do: <<tag, byte_size(payload)::unsigned-integer-size(32), payload::binary>>
end
