defmodule SymphonyElixir.Security.MasterKey do
  @moduledoc """
  Loads and validates the external master key used by the encrypted secret store.
  """

  @key_bytes 32

  @type key :: <<_::256>>

  @spec current!() :: key()
  def current! do
    :symphony_elixir
    |> Application.fetch_env!(:master_key_base64)
    |> decode!()
  end

  @spec decode(String.t()) :: {:ok, key()} | {:error, :missing | :invalid}
  def decode(value) when is_binary(value) do
    with {:ok, key} <- Base.decode64(value),
         true <- byte_size(key) == @key_bytes do
      {:ok, key}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def decode(_value), do: {:error, :missing}

  @spec decode!(String.t()) :: key()
  def decode!(value) do
    case decode(value) do
      {:ok, key} -> key
      {:error, reason} -> raise ArgumentError, "invalid SYMPHONY_MASTER_KEY: #{reason}"
    end
  end

  @spec validate_configuration!() :: :ok
  def validate_configuration! do
    current!()
    :ok
  end
end
