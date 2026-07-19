defmodule SymphonyElixir.Identity.StringList do
  @moduledoc false

  use Ecto.Type

  @impl true
  def type, do: :text

  @impl true
  def cast(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(values)}
    else
      :error
    end
  end

  def cast(_values), do: :error

  @impl true
  def load(value) when is_binary(value), do: Jason.decode(value)
  def load(_value), do: :error

  @impl true
  def dump(values) when is_list(values), do: {:ok, Jason.encode!(values)}
  def dump(_values), do: :error
end
