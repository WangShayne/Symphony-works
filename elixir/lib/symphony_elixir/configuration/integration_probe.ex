defmodule SymphonyElixir.Configuration.IntegrationProbe do
  @moduledoc """
  Validates configured Tracker and Source Control boundaries without persisting credentials.

  Credential references are resolved immediately before the adapter call. Plaintext secrets exist
  only in the runtime map passed across that outbound boundary and are rejected if an adapter tries
  to return them in evidence or an error.
  """

  @behaviour SymphonyElixir.Configuration.Probe

  alias SymphonyElixir.Configuration.Exporter
  alias SymphonyElixir.Security.CredentialBroker

  @integration_kinds ["tracker", "source_control"]

  @spec configured?(map()) :: boolean()
  def configured?(%{"integrations" => integrations}) when is_list(integrations) do
    Enum.any?(integrations, &(is_map(&1) and Map.get(&1, "kind") in @integration_kinds))
  end

  def configured?(_document), do: false

  @impl true
  def validate(%{"integrations" => integrations} = document) when is_list(integrations) do
    selected_integrations(document, integrations)
    |> Enum.reduce_while({:ok, []}, fn integration, {:ok, evidence} ->
      case validate_integration(integration) do
        {:ok, item} -> {:cont, {:ok, [item | evidence]}}
        {:error, item} -> {:halt, {:error, {:integration, failure_evidence(item)}}}
      end
    end)
    |> case do
      {:ok, evidence} ->
        {:ok,
         %{
           "probe" => "integrations",
           "status" => "passed",
           "integration_count" => length(evidence),
           "integrations" => Enum.reverse(evidence)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  def validate(_document) do
    {:ok,
     %{
       "probe" => "integrations",
       "status" => "passed",
       "integration_count" => 0,
       "integrations" => []
     }}
  end

  defp selected_integrations(document, integrations) do
    selected =
      document
      |> project_integration_refs()
      |> Enum.map(&find_integration(integrations, &1))
      |> Enum.reject(&is_nil/1)

    case selected do
      [] ->
        Enum.filter(integrations, &(is_map(&1) and Map.get(&1, "kind") in @integration_kinds))

      integrations ->
        integrations
    end
  end

  defp project_integration_refs(%{"automation_projects" => [project]}) when is_map(project) do
    [
      Map.get(project, "tracker_integration_ref"),
      Map.get(project, "source_control_integration_ref")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp project_integration_refs(_document), do: []

  defp find_integration(integrations, ref) do
    Enum.find(integrations, &(is_map(&1) and Map.get(&1, "id") == ref))
  end

  defp validate_integration(integration) do
    integration = attach_project_ref(integration)
    kind = Map.get(integration, "kind")
    provider = Map.get(integration, "provider")
    reference = Map.get(integration, "credential_ref")
    adapter = health_adapter(kind)

    result =
      if provider == "fixture" and is_nil(reference) do
        call_health(adapter, integration)
      else
        call_health_with_credentials(integration, adapter, kind, provider, reference)
      end

    references = [reference, get_in(integration, ["settings", "webhook_secret_ref"])]
    normalize_result(result, integration, references)
  end

  defp call_health_with_credentials(integration, adapter, kind, provider, reference) do
    CredentialBroker.with_secret(reference, "#{kind}_health", fn credential ->
      integration
      |> call_health_with_webhook_secret(adapter, kind, provider, reference, credential)
    end)
  end

  defp call_health_with_webhook_secret(integration, adapter, kind, provider, reference, credential) do
    with_webhook_secret(integration, kind, provider, fn webhook_secret ->
      safe_terms = [
        reference,
        get_in(integration, ["settings", "webhook_secret_ref"]),
        credential,
        webhook_secret
      ]

      integration
      |> Map.put("credential", credential)
      |> maybe_put_webhook_secret(webhook_secret)
      |> call_health(adapter)
      |> safe_adapter_result(safe_terms)
    end)
  end

  defp with_webhook_secret(integration, "tracker", provider, fun) when provider != "fixture" do
    webhook_reference = get_in(integration, ["settings", "webhook_secret_ref"])

    CredentialBroker.with_secret(webhook_reference, "tracker_webhook_health", fun)
  end

  defp with_webhook_secret(_integration, _kind, _provider, fun), do: fun.(nil)

  defp maybe_put_webhook_secret(integration, secret) when is_binary(secret),
    do: Map.put(integration, "webhook_secret", secret)

  defp maybe_put_webhook_secret(integration, _secret), do: integration

  defp attach_project_ref(integration), do: Map.put(integration, "project_integration_ref", Map.get(integration, "id"))

  defp call_health(integration, adapter) when is_map(integration) and is_atom(adapter) do
    call_health(adapter, integration)
  end

  defp call_health(adapter, integration) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :health_check, 1) do
      adapter.health_check(integration)
    else
      {:error, :adapter_unavailable}
    end
  end

  defp safe_adapter_result({:ok, value}, safe_terms) when is_map(value),
    do: {:ok, safe_evidence(value, safe_terms)}

  defp safe_adapter_result({:ok, value}, safe_terms),
    do: {:error, {:invalid_health_result, safe_evidence(value, safe_terms)}}

  defp safe_adapter_result({:error, value}, safe_terms),
    do: {:error, safe_evidence(value, safe_terms)}

  defp safe_adapter_result(value, safe_terms),
    do: {:error, {:invalid_health_result, safe_evidence(value, safe_terms)}}

  defp normalize_result({:ok, health}, integration, references) do
    {:ok,
     integration_identity(integration)
     |> Map.put("status", "passed")
     |> Map.put("health", safe_evidence(health, references))
     |> maybe_mark_webhook_signing(integration)}
  end

  defp normalize_result({:error, reason}, integration, references) do
    {:error,
     integration_identity(integration)
     |> Map.put("status", "failed")
     |> Map.put("reason", safe_reason(reason, references))}
  end

  defp normalize_result(other, integration, references) do
    normalize_result({:error, {:invalid_health_result, other}}, integration, references)
  end

  defp integration_identity(integration) do
    %{
      "id" => Map.get(integration, "id"),
      "kind" => Map.get(integration, "kind"),
      "provider" => Map.get(integration, "provider"),
      "project_integration_ref" => Map.get(integration, "project_integration_ref")
    }
  end

  defp maybe_mark_webhook_signing(item, %{
         "kind" => "tracker",
         "provider" => provider,
         "settings" => %{"webhook_secret_ref" => reference}
       })
       when provider != "fixture" and is_binary(reference) do
    Map.put(item, "webhook_signing", "resolved")
  end

  defp maybe_mark_webhook_signing(item, _integration), do: item

  defp health_adapter(kind) do
    configured = Application.get_env(:symphony_elixir, :integration_health_adapters, %{})

    case configured do
      adapters when is_map(adapters) ->
        Map.get(adapters, kind) || Map.get(adapters, known_kind_atom(kind)) || default_adapter(kind)

      _other ->
        default_adapter(kind)
    end
  end

  defp known_kind_atom("tracker"), do: :tracker
  defp known_kind_atom("source_control"), do: :source_control

  defp default_adapter("tracker"), do: SymphonyElixir.Tracker
  defp default_adapter("source_control"), do: SymphonyElixir.SourceControl

  defp failure_evidence(item) do
    %{
      "probe" => "integrations",
      "status" => "failed",
      "integration" => item
    }
  end

  defp safe_reason(reason, _references) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_reason(%{"code" => code}, references), do: safe_reason(code, references)
  defp safe_reason(%{code: code}, references), do: safe_reason(code, references)
  defp safe_reason({code, _details}, references) when is_atom(code), do: safe_reason(code, references)

  defp safe_reason(reason, references) when is_binary(reason) do
    reason
    |> safe_evidence(references)
    |> String.slice(0, 120)
  end

  defp safe_reason(_reason, _references), do: "health_check_failed"

  defp safe_evidence(value, references) do
    references
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(Exporter.redact(value), fn reference, evidence ->
      scrub_reference(evidence, reference)
    end)
  end

  defp scrub_reference(value, reference) when is_binary(value) and is_binary(reference),
    do: String.replace(value, reference, "[REDACTED]")

  defp scrub_reference(value, reference) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {scrub_reference(key, reference), scrub_reference(nested, reference)}
    end)
  end

  defp scrub_reference(value, reference) when is_list(value),
    do: Enum.map(value, &scrub_reference(&1, reference))

  defp scrub_reference(value, reference) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&scrub_reference(&1, reference))
    |> List.to_tuple()
  end

  defp scrub_reference(value, _reference), do: value
end
