defmodule SymphonyElixir.Configuration.Probe do
  @moduledoc """
  Activation health probe contract for configuration references.
  """

  @callback validate(map()) :: {:ok, map()} | {:error, {atom(), map()}}
end
