defmodule SymphonyElixir.Runtime.ModelProvider do
  @moduledoc """
  Maps persisted model-provider protocol declarations to Runtime adapters.
  """

  alias SymphonyElixir.Runtime.Codex

  @spec adapter_for(map()) :: {:ok, module()} | {:error, atom()}
  def adapter_for(%{"runtime_protocol" => "codex_app_server"}), do: {:ok, Codex}
  def adapter_for(_provider), do: {:error, :unsupported_runtime_protocol}
end
