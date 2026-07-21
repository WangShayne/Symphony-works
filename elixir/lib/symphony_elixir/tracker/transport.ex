defmodule SymphonyElixir.Tracker.Transport do
  @moduledoc false

  @callback request(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @spec request(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(request, opts) when is_map(request) and is_list(opts) do
    {transport, transport_opts} = normalize_transport(Keyword.get(opts, :transport))

    runtime_opts =
      opts
      |> Keyword.take([:endpoint_policy, :receive_timeout, :request_fun])
      |> Keyword.merge(transport_opts)

    transport.request(request, runtime_opts)
  rescue
    _exception -> {:error, :transport_failed}
  catch
    _kind, _reason -> {:error, :transport_failed}
  end

  defp normalize_transport(nil), do: {SymphonyElixir.Tracker.Transport.Req, []}
  defp normalize_transport({transport, opts}) when is_atom(transport) and is_list(opts), do: {transport, opts}
  defp normalize_transport(transport) when is_atom(transport), do: {transport, []}
end
