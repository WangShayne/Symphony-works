defmodule SymphonyElixir.Configuration.Validator do
  @moduledoc """
  Runs local validation for a configuration revision and returns redacted evidence.
  """

  alias SymphonyElixir.Configuration.Document

  @spec validate(term()) :: {:ok, map()} | {:error, {:invalid_configuration, list()}}
  def validate(document) do
    case Document.validate(document) do
      {:ok, _document} ->
        {:ok,
         %{
           "schema" => "passed",
           "reference_integrity" => "passed",
           "probes" => []
         }}

      {:error, errors} ->
        {:error, {:invalid_configuration, errors}}
    end
  end
end
