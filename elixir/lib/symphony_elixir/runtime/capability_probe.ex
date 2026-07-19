defmodule SymphonyElixir.Runtime.CapabilityProbe do
  @moduledoc """
  Default activation probe for configured Runtime model references.
  """

  @behaviour SymphonyElixir.Configuration.Probe

  alias SymphonyElixir.Runtime
  alias SymphonyElixir.Runtime.ModelProvider
  alias SymphonyElixir.Security.CredentialBroker

  @impl true
  def validate(document) when is_map(document) do
    with :ok <- verify_credential_references(document),
         {:ok, models} <- probe_models(document) do
      {:ok,
       %{
         "probe" => "runtime_capability",
         "status" => "passed",
         "provider_count" => provider_count(document),
         "model_count" => length(models),
         "models" => models
       }}
    end
  end

  @spec configured?(map()) :: boolean()
  def configured?(%{"model_references" => references}) when is_list(references), do: references != []
  def configured?(_document), do: false

  defp verify_credential_references(document) do
    document
    |> credential_references()
    |> Enum.reduce_while(:ok, fn reference, :ok ->
      case resolve_credential_reference(reference) do
        {:ok, _evidence} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:credential_ref, credential_failure(reason)}}}
      end
    end)
  end

  defp resolve_credential_reference(reference) do
    CredentialBroker.with_secret(reference, :runtime_capability_probe, fn _plaintext ->
      {:ok, %{"credential_ref" => "[REDACTED]"}}
    end)
  end

  defp credential_failure(reason) do
    %{
      "probe" => "runtime_capability",
      "status" => "failed",
      "reason" => sanitize_reason(reason),
      "credential_ref" => "[REDACTED]"
    }
  end

  defp credential_references(document) do
    provider_refs =
      document
      |> Map.get("providers", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "credential_ref"))

    model_refs =
      document
      |> Map.get("model_references", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "credential_ref"))

    (provider_refs ++ model_refs)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp probe_models(document) do
    providers = provider_index(document)

    document
    |> Map.get("model_references", [])
    |> Enum.filter(&is_map/1)
    |> Enum.reduce_while({:ok, []}, fn model_reference, {:ok, models} ->
      case probe_model(model_reference, providers) do
        {:ok, evidence} -> {:cont, {:ok, [evidence | models]}}
        {:error, {kind, evidence}} -> {:halt, {:error, {kind, evidence}}}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, Enum.reverse(models)}
      {:error, _reason} = error -> error
    end
  end

  defp probe_model(model_reference, providers) do
    provider_id = Map.get(model_reference, "provider_id")

    with {:ok, provider} <- fetch_provider(providers, provider_id),
         {:ok, adapter} <- ModelProvider.adapter_for(provider),
         {:ok, capabilities} <- Runtime.capabilities(adapter, model_reference),
         :ok <- validate_price_snapshot(model_reference),
         {:ok, health} <- probe_model_health(adapter, model_reference, provider) do
      {:ok,
       health
       |> Map.take(["runtime", "status", "structured_plan_probe", "capabilities", "prices"])
       |> Map.put("capabilities", capabilities)}
    else
      {:error, reason} ->
        {:error, {:model_provider, model_failure(reason)}}
    end
  end

  defp model_failure(reason) do
    %{
      "probe" => "runtime_capability",
      "status" => "failed",
      "reason" => sanitize_reason(reason)
    }
  end

  defp fetch_provider(providers, provider_id) when is_binary(provider_id) do
    case Map.fetch(providers, provider_id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :provider_not_found}
    end
  end

  defp fetch_provider(_providers, _provider_id), do: {:error, :provider_not_found}

  defp probe_model_health(adapter, model_reference, provider) do
    reference = Map.get(model_reference, "credential_ref") || Map.get(provider, "credential_ref")

    CredentialBroker.with_secret(reference, :runtime_capability_probe, fn plaintext ->
      Runtime.health_check(adapter, model_reference,
        read_only: true,
        provider: provider,
        provider_credential: plaintext
      )
    end)
  end

  defp validate_price_snapshot(%{"prices" => prices}) when is_map(prices) do
    if Enum.all?(["input", "cached_input", "output"], &valid_price?(Map.get(prices, &1))) do
      :ok
    else
      {:error, :invalid_price_snapshot}
    end
  end

  defp validate_price_snapshot(_model_reference), do: {:error, {:invalid_price_snapshot, :missing}}

  defp valid_price?(value), do: is_number(value) and value >= 0

  defp provider_index(%{"providers" => providers}) when is_list(providers) do
    providers
    |> Enum.filter(&is_map/1)
    |> Map.new(fn provider -> {Map.get(provider, "id"), provider} end)
  end

  defp provider_index(_document), do: %{}

  defp provider_count(%{"providers" => providers}) when is_list(providers) do
    Enum.count(providers, &is_map/1)
  end

  defp provider_count(_document), do: 0

  defp sanitize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reason({:runtime_error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reason(_reason), do: "failed"
end
