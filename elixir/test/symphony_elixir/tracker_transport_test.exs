defmodule SymphonyElixir.TrackerTransportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.EndpointPolicy
  alias SymphonyElixir.Tracker.Transport
  alias SymphonyElixir.Tracker.Transport.Fixture

  defmodule RaisingTransport do
    @behaviour Transport

    @impl true
    def request(_request, action: :raise), do: raise("transport secret")
    def request(_request, action: :throw), do: throw(:transport_secret)
  end

  test "dispatches module and tuple transports" do
    request = %{method: :get, url: "https://provider.test"}
    response = {:ok, %{status: 204, headers: %{}, body: nil}}

    assert ^response = Transport.request(request, transport: {Fixture, response: response})

    assert {:error, :missing_fixture_response} =
             Transport.request(request, transport: Fixture)
  end

  test "default Req transport receives the facade endpoint pin and request function" do
    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
             )

    test_pid = self()

    request_fun = fn options ->
      send(test_pid, {:default_transport_options, options})
      {:ok, %Req.Response{status: 200, headers: %{}, body: %{"ok" => true}}}
    end

    assert {:ok, %{status: 200, body: %{"ok" => true}}} =
             Transport.request(
               %{method: :get, url: "https://tracker.example.com/api/issues"},
               endpoint_policy: policy,
               request_fun: request_fun
             )

    assert_receive {:default_transport_options, options}
    assert URI.to_string(options[:url]) == "https://93.184.216.34/api/issues"
    assert options[:redirect] == false
  end

  test "normalizes invalid transports, raises, and throws" do
    request = %{method: :get, url: "https://provider.test"}

    assert {:error, :transport_failed} =
             Transport.request(request, transport: {RaisingTransport, action: :raise})

    assert {:error, :transport_failed} =
             Transport.request(request, transport: {RaisingTransport, action: :throw})

    assert {:error, :transport_failed} = Transport.request(request, transport: {:invalid, %{}})
  end

  test "fixture transport reports requests and rejects invalid handlers" do
    request = %{method: :post, url: "https://provider.test", body: %{ok: true}}

    assert {:ok, %{status: 201}} =
             Fixture.request(request,
               observer: self(),
               handler: fn ^request -> {:ok, %{status: 201}} end
             )

    assert_receive {:tracker_fixture_request, ^request}

    assert {:error, :invalid_fixture_handler} = Fixture.request(request, handler: :invalid)
  end
end
