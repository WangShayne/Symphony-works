defmodule SymphonyElixir.TrackerEndpointSecurityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.EndpointPolicy
  alias SymphonyElixir.Tracker.Transport.Req, as: ReqTransport

  @public_ip {93, 184, 216, 34}

  test "trusted HTTPS endpoints are pinned without changing their HTTP identity" do
    resolver = fn "tracker.example.com" -> {:ok, [@public_ip]} end

    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api/v4",
               trusted_origins: ["https://tracker.example.com"],
               resolver: resolver
             )

    assert {:ok, authorized} =
             EndpointPolicy.authorize(
               policy,
               "https://tracker.example.com/api/v4/projects/1/issues"
             )

    assert authorized.address == @public_ip
    assert authorized.hostname == "tracker.example.com"
    assert authorized.host_header == "tracker.example.com"
    assert URI.to_string(authorized.url) == "https://93.184.216.34/api/v4/projects/1/issues"
  end

  test "local and obfuscated IP hosts are rejected even when explicitly trusted" do
    endpoints = [
      "https://localhost",
      "https://tracker.local",
      "https://metadata.internal",
      "https://2130706433",
      "https://0x7f000001",
      "https://0177.0.0.1",
      "https://127%2e0%2e0%2e1",
      "https://[::1]",
      "https://[::ffff:127.0.0.1]"
    ]

    for endpoint <- endpoints do
      assert {:error, _reason} =
               EndpointPolicy.validate(endpoint,
                 trusted_origins: [endpoint],
                 resolver: fn _host -> {:ok, [@public_ip]} end
               ),
             "expected #{endpoint} to be rejected"
    end
  end

  test "reserved IPv4 and non-global IPv6 prefixes are rejected as unsafe addresses" do
    for endpoint <- ["https://192.88.99.1", "https://[4000::1]"] do
      assert {:error, :unsafe_address} =
               EndpointPolicy.validate(endpoint,
                 trusted_origins: [endpoint],
                 resolver: fn _host -> flunk("literal IP endpoints must not resolve DNS") end
               )
    end
  end

  test "Req transport fails closed before outbound work when endpoint policy is missing" do
    request_fun = fn _options -> flunk("request function must not run without endpoint policy") end

    assert {:error, :unsafe_endpoint} =
             ReqTransport.request(
               %{method: :get, url: "not a URL"},
               request_fun: request_fun
             )
  end

  test "Req transport connects to the pin and never follows redirects" do
    resolver = fn "tracker.example.com" -> {:ok, [@public_ip]} end

    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: resolver
             )

    test_pid = self()

    request_fun = fn options ->
      send(test_pid, {:request_options, options})

      {:ok,
       %Req.Response{
         status: 302,
         headers: %{"location" => ["https://169.254.169.254/latest/meta-data"]},
         body: ""
       }}
    end

    request = %{
      method: :post,
      url: "https://tracker.example.com/api/issues",
      headers: %{"authorization" => "Bearer opaque", "Host" => "attacker.example.com"},
      body: %{title: "Issue"}
    }

    assert {:ok, %{status: 302}} =
             ReqTransport.request(request,
               endpoint_policy: policy,
               request_fun: request_fun
             )

    assert_receive {:request_options, options}
    assert options[:redirect] == false
    assert options[:connect_options] == [hostname: "tracker.example.com"]
    assert URI.to_string(options[:url]) == "https://93.184.216.34/api/issues"
    assert {"host", "tracker.example.com"} in options[:headers]
    assert {"authorization", "Bearer opaque"} in options[:headers]
    refute {"Host", "attacker.example.com"} in options[:headers]
    assert options[:json] == %{title: "Issue"}
    refute_receive {:request_options, _redirected_options}
  end

  test "endpoint syntax cannot carry plaintext credentials or ambiguous authority data" do
    endpoints = [
      "http://tracker.example.com",
      "https://user:secret@tracker.example.com",
      "https://tracker.example.com?token=secret",
      "https://tracker.example.com#secret",
      "https://tracker.example.com.",
      " https://tracker.example.com",
      "https://tracker.example.com\\@127.0.0.1"
    ]

    for endpoint <- endpoints do
      assert {:error, _reason} =
               EndpointPolicy.validate(endpoint,
                 trusted_origins: ["https://tracker.example.com"],
                 resolver: fn _host -> flunk("invalid endpoints must not reach DNS") end
               ),
             "expected #{endpoint} to be rejected"
    end
  end

  test "origin trust is exact and checked before DNS" do
    for endpoint <- [
          "https://tracker.attacker.example.com/api",
          "https://tracker.example.com:8443/api"
        ] do
      assert {:error, :untrusted_origin} =
               EndpointPolicy.validate(endpoint,
                 trusted_origins: ["https://tracker.example.com"],
                 resolver: fn _host -> flunk("untrusted origins must not reach DNS") end
               )
    end
  end

  test "all private, local, unspecified, reserved, and multicast answers are rejected" do
    unsafe_addresses = [
      {0, 0, 0, 0},
      {10, 0, 0, 1},
      {100, 64, 0, 1},
      {127, 0, 0, 1},
      {169, 254, 169, 254},
      {172, 16, 0, 1},
      {192, 0, 2, 1},
      {192, 168, 0, 1},
      {198, 18, 0, 1},
      {198, 51, 100, 1},
      {203, 0, 113, 1},
      {224, 0, 0, 1},
      {240, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 65_535, 0x7F00, 1},
      {0xFC00, 0, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
      {0x2002, 0x7F00, 1, 0, 0, 0, 0, 1}
    ]

    for address <- unsafe_addresses do
      assert {:error, :unsafe_address} =
               EndpointPolicy.validate("https://tracker.example.com/api",
                 trusted_origins: ["https://tracker.example.com"],
                 resolver: fn "tracker.example.com" -> {:ok, [address]} end
               ),
             "expected #{inspect(address)} to be rejected"
    end

    assert {:error, :unsafe_address} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn "tracker.example.com" ->
                 {:ok, [@public_ip, {10, 0, 0, 1}]}
               end
             )
  end

  test "authorization cannot change origin or escape the configured base path" do
    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api/v4",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn "tracker.example.com" -> {:ok, [@public_ip]} end
             )

    for url <- [
          "https://evil.example.com/api/v4/issues",
          "https://tracker.example.com:8443/api/v4/issues",
          "https://tracker.example.com/api/v40/issues",
          "https://tracker.example.com/admin"
        ] do
      assert {:error, :untrusted_origin} = EndpointPolicy.authorize(policy, url)
    end
  end

  test "path confinement survives decoding, normalization, and mixed-case encodings" do
    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api/v4",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn _host -> {:ok, [@public_ip]} end
             )

    paths = [
      "/api/v4/../admin",
      "/api/v4/./issues",
      "/api/v4/%2e%2e/admin",
      "/api/v4/%2E%2e/admin",
      "/api/v4/projects%2f..%2f..%2fadmin",
      "/api/v4/projects%2F%2E%2e%2F%2e%2E%2Fadmin",
      "/api/v4/%252e%252e%252fadmin",
      "/api/v4/%252E%252e%252Fadmin",
      "/api/v4/%255c..%255cadmin",
      "/api/v4/projects\\..\\admin"
    ]

    for path <- paths do
      assert {:error, reason} =
               EndpointPolicy.authorize(policy, "https://tracker.example.com" <> path),
             "expected #{path} to be rejected"

      assert reason in [:invalid_endpoint, :untrusted_origin]
    end

    assert {:ok, _authorization} =
             EndpointPolicy.authorize(
               policy,
               "https://tracker.example.com/api/v4/projects/acme%2Fsymfony/issues"
             )
  end

  test "configured base paths must be canonical before DNS resolution" do
    for endpoint <- [
          "https://tracker.example.com/api/%2e%2e/admin",
          "https://tracker.example.com/api%2fv4",
          "https://tracker.example.com/api/../admin"
        ] do
      assert {:error, :invalid_endpoint} =
               EndpointPolicy.validate(endpoint,
                 trusted_origins: ["https://tracker.example.com"],
                 resolver: fn _host -> flunk("ambiguous base paths must not reach DNS") end
               )
    end
  end

  test "DNS is resolved once and the resulting address remains pinned" do
    test_pid = self()

    resolver = fn "tracker.example.com" ->
      send(test_pid, :resolved)
      {:ok, [@public_ip]}
    end

    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: resolver
             )

    assert_receive :resolved

    assert {:ok, %{address: @public_ip}} =
             EndpointPolicy.authorize(policy, "https://tracker.example.com/api/issues")

    refute_receive :resolved
  end

  test "public IPv6 literals keep bracketed HTTP identity" do
    endpoint = "https://[2606:4700:4700::1111]:8443/api"

    assert {:ok, policy} =
             EndpointPolicy.validate(endpoint,
               trusted_origins: ["https://[2606:4700:4700::1111]:8443"],
               resolver: fn _host -> flunk("IP literals must not reach DNS") end
             )

    assert {:ok, authorized} = EndpointPolicy.authorize(policy, endpoint <> "/issues")
    assert authorized.host_header == "[2606:4700:4700::1111]:8443"
    assert URI.to_string(authorized.url) == endpoint <> "/issues"
  end

  test "Req transport rejects URLs outside the validated policy before HTTP" do
    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn "tracker.example.com" -> {:ok, [@public_ip]} end
             )

    assert {:error, :unsafe_endpoint} =
             ReqTransport.request(
               %{method: :get, url: "https://evil.example.com/api/issues"},
               endpoint_policy: policy,
               request_fun: fn _options -> flunk("cross-origin request must not reach HTTP") end
             )
  end

  test "Req transport contains boundary failures without leaking their reason" do
    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn "tracker.example.com" -> {:ok, [@public_ip]} end
             )

    request = %{method: :get, url: "https://tracker.example.com/api/issues"}

    request_functions = [
      fn _options -> {:error, {:secret, "opaque"}} end,
      fn _options -> raise "opaque" end,
      fn _options -> throw({:secret, "opaque"}) end
    ]

    for request_fun <- request_functions do
      assert {:error, :transport_failed} =
               ReqTransport.request(request,
                 endpoint_policy: policy,
                 request_fun: request_fun
               )
    end
  end

  test "resolver failures and malformed answers fail closed" do
    base_options = [trusted_origins: ["https://tracker.example.com"]]

    assert {:error, :resolution_failed} =
             EndpointPolicy.validate(
               "https://tracker.example.com",
               Keyword.put(base_options, :resolver, fn _host -> {:error, :nxdomain} end)
             )

    assert {:error, :resolution_failed} =
             EndpointPolicy.validate(
               "https://tracker.example.com",
               Keyword.put(base_options, :resolver, fn _host -> {:ok, []} end)
             )

    assert {:error, :unsafe_address} =
             EndpointPolicy.validate(
               "https://tracker.example.com",
               Keyword.put(base_options, :resolver, fn _host -> {:ok, [:not_an_ip]} end)
             )
  end

  test "dual-family resolver contract is testable without network" do
    resolver = fn
      ~c"tracker.example.com", :inet -> {:ok, [@public_ip]}
      ~c"tracker.example.com", :inet6 -> {:error, :nxdomain}
    end

    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: resolver
             )

    assert {:ok, %{address: @public_ip}} =
             EndpointPolicy.authorize(policy, "https://tracker.example.com/api/issues")
  end

  test "invalid policy inputs and operator trust data fail closed" do
    endpoint = "https://tracker.example.com"
    public_resolver = fn _host -> {:ok, [@public_ip]} end

    assert {:error, :invalid_endpoint} = EndpointPolicy.validate(nil, [])
    assert {:error, :invalid_endpoint} = EndpointPolicy.validate(endpoint, :invalid)

    assert {:error, :untrusted_origin} =
             EndpointPolicy.validate(endpoint,
               trusted_origins: :all,
               resolver: public_resolver
             )

    assert {:error, :untrusted_origin} =
             EndpointPolicy.validate(endpoint,
               trusted_origins: [123, "%", "https://tracker.example.com/path"],
               resolver: public_resolver
             )

    assert {:error, :resolution_failed} =
             EndpointPolicy.validate(endpoint,
               trusted_origins: [endpoint],
               resolver: :invalid
             )
  end

  test "resolver exceptions and throws cannot cross the policy boundary" do
    options = [trusted_origins: ["https://tracker.example.com"]]

    assert {:error, :invalid_endpoint} =
             EndpointPolicy.validate(
               "https://tracker.example.com",
               Keyword.put(options, :resolver, fn _host -> raise "opaque" end)
             )

    assert {:error, :invalid_endpoint} =
             EndpointPolicy.validate(
               "https://tracker.example.com",
               Keyword.put(options, :resolver, fn _host -> throw({:secret, "opaque"}) end)
             )
  end

  test "invalid DNS names are rejected before resolution" do
    oversized_host = String.duplicate("a", 250) <> ".example.com"

    for endpoint <- [
          "https:///missing-host",
          "https://bad_label.example.com",
          "https://#{oversized_host}"
        ] do
      assert {:error, :invalid_endpoint} =
               EndpointPolicy.validate(endpoint,
                 trusted_origins: [endpoint],
                 resolver: fn _host -> flunk("invalid DNS names must not reach resolution") end
               )
    end
  end

  test "root policies authorize same-origin paths and reject invalid callers" do
    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn _host -> {:ok, [@public_ip]} end
             )

    assert {:ok, _authorization} =
             EndpointPolicy.authorize(policy, "https://tracker.example.com/any/path")

    assert {:error, :invalid_endpoint} = EndpointPolicy.authorize(policy, nil)
    assert {:error, :invalid_endpoint} = EndpointPolicy.authorize(:invalid, "https://tracker.example.com")
  end

  test "Req transport rejects an invalid HTTP boundary function" do
    assert {:ok, policy} =
             EndpointPolicy.validate("https://tracker.example.com/api",
               trusted_origins: ["https://tracker.example.com"],
               resolver: fn _host -> {:ok, [@public_ip]} end
             )

    assert {:error, :transport_failed} =
             ReqTransport.request(
               %{method: :get, url: "https://tracker.example.com/api/issues"},
               endpoint_policy: policy,
               request_fun: :invalid
             )
  end
end
