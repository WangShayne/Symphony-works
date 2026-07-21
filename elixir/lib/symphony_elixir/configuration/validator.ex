defmodule SymphonyElixir.Configuration.Validator do
  @moduledoc """
  Runs local validation for a configuration revision and returns redacted evidence.
  """

  alias SymphonyElixir.Configuration.{Document, Exporter, IntegrationProbe}
  alias SymphonyElixir.Runtime.CapabilityProbe

  @spec validate(term(), keyword()) :: {:ok, map()} | {:error, {:invalid_configuration, list()} | tuple()}
  def validate(document, opts \\ []) do
    case Document.validate(document) do
      {:ok, _document} ->
        with {:ok, probes} <- run_probes(document, configured_probes(document, opts)) do
          {:ok,
           %{
             "schema" => "passed",
             "reference_integrity" => "passed",
             "probes" => probes
           }}
        end

      {:error, errors} ->
        {:error, {:invalid_configuration, errors}}
    end
  end

  defp run_probes(document, probes) do
    Enum.reduce_while(probes, {:ok, []}, fn probe, {:ok, evidence} ->
      case probe.validate(document) do
        {:ok, probe_evidence} ->
          {:cont, {:ok, [Exporter.redact(probe_evidence) | evidence]}}

        {:error, {kind, probe_evidence}} ->
          {:halt, {:error, {:probe_failed, kind, Exporter.redact(probe_evidence)}}}
      end
    end)
    |> case do
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      {:error, _reason} = error -> error
    end
  end

  defp configured_probes(document, opts) do
    document
    |> default_probes()
    |> Kernel.++(extra_probes(opts))
  end

  defp default_probes(document) do
    []
    |> maybe_add_probe(CapabilityProbe.configured?(document), CapabilityProbe)
    |> maybe_add_probe(IntegrationProbe.configured?(document), IntegrationProbe)
  end

  defp maybe_add_probe(probes, true, probe), do: probes ++ [probe]
  defp maybe_add_probe(probes, false, _probe), do: probes

  defp extra_probes(opts) do
    case Keyword.get(opts, :probes, Application.get_env(:symphony_elixir, :configuration_probes, [])) do
      probes when is_list(probes) -> probes
      _other -> []
    end
  end
end
