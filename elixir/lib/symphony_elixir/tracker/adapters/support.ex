defmodule SymphonyElixir.Tracker.Adapters.Support do
  @moduledoc false

  alias SymphonyElixir.Tracker.Issue

  @spec settings(map()) :: map()
  def settings(config), do: value(config, :settings, %{})

  @spec value(map(), atom(), term()) :: term()
  def value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @spec eligible?(Issue.t(), map()) :: boolean()
  def eligible?(%Issue{} = issue, criteria) do
    states = criteria |> value(:states, []) |> normalized_list()
    required_labels = criteria |> value(:required_labels, []) |> normalized_list()
    issue_labels = normalized_list(issue.labels)
    assignee_id = value(criteria, :assignee_id)

    issue.dispatchable and
      normalize(issue.state) in states and
      Enum.all?(required_labels, &(&1 in issue_labels)) and
      (is_nil(assignee_id) or issue.assignee_id == to_string(assignee_id))
  end

  @spec http_error(String.t(), map()) :: {:error, map()}
  def http_error(provider, %{status: status} = response) do
    cond do
      rate_limited?(status, response) ->
        {:error, error(provider, :rate_limited, true, "tracker provider rate limited the request", retry_after_ms: retry_after_ms(response))}

      status == 401 ->
        {:error, error(provider, :authentication_failed, false, "tracker provider rejected authentication")}

      status == 403 ->
        {:error, error(provider, :forbidden, false, "tracker provider denied the request")}

      status == 404 ->
        {:error, error(provider, :not_found, false, "tracker issue or scope was not found")}

      status in 200..299 ->
        {:error, error(provider, :invalid_response, false, "tracker provider returned an invalid response")}

      status >= 500 ->
        {:error, error(provider, :provider_unavailable, true, "tracker provider is unavailable")}

      true ->
        {:error, error(provider, :provider_error, false, "tracker provider rejected the request")}
    end
  end

  def http_error(provider, _response) do
    {:error, error(provider, :invalid_response, false, "tracker provider returned an invalid response")}
  end

  @spec transport_error(String.t()) :: {:error, map()}
  def transport_error(provider) do
    {:error, error(provider, :transport_failed, true, "tracker provider could not be reached")}
  end

  @spec error(String.t(), atom(), boolean(), String.t(), keyword()) :: map()
  def error(provider, code, retryable, message, extra \\ []) do
    %{provider: provider, code: code, retryable: retryable, message: message}
    |> Map.merge(Map.new(extra))
  end

  defp rate_limited?(429, _response), do: true

  defp rate_limited?(403, response) do
    header(response, "x-ratelimit-remaining") == "0"
  end

  defp rate_limited?(_status, _response), do: false

  defp retry_after_ms(response) do
    case Integer.parse(header(response, "retry-after") || "") do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _other -> nil
    end
  end

  @spec header(map(), String.t()) :: String.t() | nil
  def header(response, name) do
    response
    |> Map.get(:headers, %{})
    |> normalize_headers()
    |> Map.get(String.downcase(name))
  end

  @spec secure_compare(String.t(), String.t()) :: boolean()
  def secure_compare(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  def secure_compare(_left, _right), do: false

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {key |> to_string() |> String.downcase(), first(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} -> {key |> to_string() |> String.downcase(), first(value)} end)
  end

  defp normalize_headers(_headers), do: %{}

  defp first([value | _rest]), do: to_string(value)
  defp first(value) when is_binary(value), do: value
  defp first(value), do: to_string(value)

  defp normalized_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize/1)
    |> Enum.uniq()
  end

  defp normalized_list(_values), do: []

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: to_string(value)
end
