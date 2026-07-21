defmodule SymphonyElixir.Tracker.Transport.Req do
  @moduledoc false

  @behaviour SymphonyElixir.Tracker.Transport

  alias SymphonyElixir.Tracker.EndpointPolicy

  @impl true
  def request(request, opts) do
    with {:ok, policy} <- endpoint_policy(opts),
         {:ok, authorization} <- authorize_request(policy, request) do
      request
      |> req_options(opts, authorization)
      |> execute_request(opts)
      |> normalize_response()
    else
      {:error, reason}
      when reason in [:invalid_endpoint, :untrusted_origin, :resolution_failed, :unsafe_address] ->
        {:error, :unsafe_endpoint}
    end
  rescue
    _exception -> {:error, :transport_failed}
  catch
    _kind, _reason -> {:error, :transport_failed}
  end

  defp endpoint_policy(opts) do
    case Keyword.fetch(opts, :endpoint_policy) do
      {:ok, policy} -> {:ok, policy}
      _other -> {:error, :invalid_endpoint}
    end
  end

  defp authorize_request(policy, request) do
    EndpointPolicy.authorize(policy, Map.fetch!(request, :url))
  end

  defp req_options(request, opts, authorization) do
    [
      method: Map.fetch!(request, :method),
      url: authorization.url,
      headers: pinned_headers(Map.get(request, :headers, %{}), authorization.host_header),
      params: Map.get(request, :params, []),
      receive_timeout: Keyword.get(opts, :receive_timeout, 10_000),
      connect_options: [hostname: authorization.hostname],
      redirect: false
    ]
    |> maybe_put_json(request)
  end

  defp pinned_headers(headers, host_header) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(to_string(name)) == "host" end)
    |> Enum.to_list()
    |> List.insert_at(0, {"host", host_header})
  end

  defp execute_request(options, opts) do
    case Keyword.get(opts, :request_fun, &Req.request/1) do
      request_fun when is_function(request_fun, 1) -> request_fun.(options)
      _other -> {:error, :invalid_request_fun}
    end
  end

  defp maybe_put_json(options, %{body: body}) when not is_nil(body), do: Keyword.put(options, :json, body)
  defp maybe_put_json(options, _request), do: options

  defp normalize_response({:ok, %Req.Response{} = response}) do
    {:ok, %{status: response.status, headers: response.headers, body: response.body}}
  end

  defp normalize_response({:error, _reason}), do: {:error, :transport_failed}
end
