defmodule SymphonyElixir.Tracker.Transport.Fixture do
  @moduledoc """
  Deterministic transport boundary for adapter contracts and activation fixtures.

  It never performs network I/O. Callers provide either a request handler or a
  fixed response through transport options.
  """

  @behaviour SymphonyElixir.Tracker.Transport

  @impl true
  def request(request, opts) when is_map(request) and is_list(opts) do
    if observer = Keyword.get(opts, :observer) do
      send(observer, {:tracker_fixture_request, request})
    end

    case Keyword.fetch(opts, :handler) do
      {:ok, handler} when is_function(handler, 1) -> handler.(request)
      {:ok, _invalid_handler} -> {:error, :invalid_fixture_handler}
      :error -> Keyword.get(opts, :response, {:error, :missing_fixture_response})
    end
  end
end
