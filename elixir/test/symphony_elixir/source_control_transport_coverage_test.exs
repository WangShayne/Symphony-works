defmodule SymphonyElixir.SourceControlTransportCoverageTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SourceControl.Transport
  alias SymphonyElixir.SourceControl.Transport.{Git, HTTP}

  @credential_key {Transport, :credential}
  @credential_ref "00000000-0000-4000-8000-000000000008"
  @desired_sha String.duplicate("d", 40)
  @expected_sha String.duplicate("e", 40)

  defmodule SequenceTransport do
    @moduledoc false

    def request(request, {owner, agent}) do
      send(owner, {:transport_request, request})

      Agent.get_and_update(agent, fn
        [response | rest] -> {response, rest}
        [] -> {:unexpected_transport_call, []}
      end)
    end
  end

  setup do
    previous_req_options = Application.get_env(:req, :default_options, :not_set)
    previous_trusted_origins = Application.get_env(:symphony_elixir, :source_control_trusted_origins)
    previous_resolver = Application.get_env(:symphony_elixir, :source_control_endpoint_resolver)
    previous_git_trusted_origins = Application.get_env(:symphony_elixir, :source_control_git_trusted_origins)
    previous_git_resolver = Application.get_env(:symphony_elixir, :source_control_git_endpoint_resolver)

    resolver = fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end

    Application.put_env(:symphony_elixir, :source_control_trusted_origins, %{
      github: [
        "https://api.github.com",
        "https://api.github.test",
        "https://github.example.test",
        "https://graphql.example.test",
        "https://graphql-fallback.example.test",
        "https://rest.example.test",
        "https://trusted.example.test"
      ],
      gitlab: [
        "https://gitlab.com",
        "https://git.example.test",
        "https://gitlab.example.test",
        "https://gitlab.test",
        "https://trusted.example.test"
      ]
    })

    Application.put_env(:symphony_elixir, :source_control_endpoint_resolver, resolver)

    Application.put_env(:symphony_elixir, :source_control_git_trusted_origins, %{
      github: ["https://code.example.test"],
      gitlab: ["https://gitlab.example.test:8443"]
    })

    Application.put_env(:symphony_elixir, :source_control_git_endpoint_resolver, resolver)

    on_exit(fn ->
      case previous_req_options do
        :not_set -> Application.delete_env(:req, :default_options)
        options -> Application.put_env(:req, :default_options, options)
      end

      restore_env(:source_control_trusted_origins, previous_trusted_origins)
      restore_env(:source_control_endpoint_resolver, previous_resolver)
      restore_env(:source_control_git_trusted_origins, previous_git_trusted_origins)
      restore_env(:source_control_git_endpoint_resolver, previous_git_resolver)
    end)

    :ok
  end

  test "credentials stay process-local and nested scopes restore prior state" do
    Process.delete(@credential_key)

    assert :inner_result =
             Transport.with_credential("outer", fn ->
               assert Process.get(@credential_key) == "outer"

               assert :inner_result =
                        Transport.with_credential("inner", fn ->
                          assert Process.get(@credential_key) == "inner"
                          :inner_result
                        end)

               assert Process.get(@credential_key) == "outer"
               :inner_result
             end)

    assert Process.get(@credential_key) == nil

    Process.put(@credential_key, "preexisting")

    assert_raise RuntimeError, "scope failed", fn ->
      Transport.with_credential("temporary", fn -> raise "scope failed" end)
    end

    assert Process.get(@credential_key) == "preexisting"
    Process.delete(@credential_key)
  end

  test "GitHub and GitLab authorization use only the scoped credential" do
    {github_config, github_agent} =
      transport_config([
        {:ok, %{status: 200, headers: %{"X-Reply" => ["github"]}, body: %{ok: true}}}
      ])

    assert {:ok, github_response} =
             Transport.with_credential("github-token", fn ->
               Transport.request(github_config, :github, %{
                 method: :get,
                 path: "/repos/acme/app",
                 headers: %{
                   "x-client" => "symphony",
                   "Authorization" => "Bearer stale-token",
                   "AUTHORIZATION" => "Bearer other-stale-token",
                   "Private-Token" => "cross-provider-token",
                   "Proxy-Authorization" => "Basic stale-proxy-token"
                 }
               })
             end)

    assert github_response.headers == %{"x-reply" => "github"}
    assert_received {:transport_request, github_request}
    assert github_request.headers["authorization"] == "Bearer github-token"
    assert github_request.headers["accept"] == "application/vnd.github+json"
    assert github_request.headers["x-github-api-version"] == "2026-03-10"
    assert github_request.headers["x-client"] == "symphony"

    assert Enum.count(github_request.headers, fn {name, _value} ->
             String.downcase(to_string(name)) == "authorization"
           end) == 1

    refute Map.has_key?(github_request.headers, "Private-Token")
    refute Map.has_key?(github_request.headers, "Proxy-Authorization")
    Agent.stop(github_agent)

    {gitlab_config, gitlab_agent} =
      transport_config([
        {:ok, %{status: 200, headers: [{"X-Reply", "gitlab"}], body: %{ok: true}}}
      ])

    assert {:ok, gitlab_response} =
             Transport.with_credential("gitlab-token", fn ->
               Transport.request(gitlab_config, :gitlab, %{
                 method: :get,
                 path: "/projects/8",
                 headers: %{
                   "private-token" => "caller-value",
                   "Private-Token" => "other-caller-value",
                   "Authorization" => "Bearer cross-provider-token",
                   "PROXY-AUTHORIZATION" => "Basic stale-proxy-token"
                 }
               })
             end)

    assert gitlab_response.headers == %{"x-reply" => "gitlab"}
    assert_received {:transport_request, gitlab_request}
    assert gitlab_request.headers["private-token"] == "gitlab-token"

    assert Enum.count(gitlab_request.headers, fn {name, _value} ->
             String.downcase(to_string(name)) == "private-token"
           end) == 1

    refute Map.has_key?(gitlab_request.headers, "Authorization")
    refute Map.has_key?(gitlab_request.headers, "PROXY-AUTHORIZATION")
    Agent.stop(gitlab_agent)
  end

  test "invalid credential references and blank scoped credentials fail closed" do
    request = %{method: :get, path: "/health"}

    assert {:error, :invalid_configuration} =
             Transport.with_credential("token", fn ->
               Transport.request(%{credential_ref: :not_opaque}, :github, request)
             end)

    assert {:error, :invalid_configuration} =
             Transport.with_credential("   ", fn ->
               Transport.request(%{"credential_ref" => @credential_ref}, :github, request)
             end)

    assert {:error, :invalid_configuration} =
             Transport.request(%{credential_ref: @credential_ref}, :github, request)
  end

  test "marker signatures require binary payloads and scoped credentials" do
    Process.delete(@credential_key)

    assert {:error, :invalid_configuration} = Transport.sign_marker_payload(:not_a_payload)
    assert {:error, :invalid_configuration} = Transport.sign_marker_payload("payload")
    refute Transport.valid_marker_signature?(:not_a_payload, String.duplicate("0", 64))
    refute Transport.valid_marker_signature?("payload", :not_a_signature)

    signature =
      Transport.with_credential("marker-token", fn ->
        {:ok, signature} = Transport.sign_marker_payload("payload")
        signature
      end)

    assert Transport.with_credential("marker-token", fn ->
             Transport.valid_marker_signature?("payload", signature)
           end)

    refute Transport.with_credential("marker-token", fn ->
             Transport.valid_marker_signature?("payload", String.slice(signature, 1..-1//1))
           end)
  end

  test "dispatch failures and unexpected responses collapse to transport_failure" do
    request = %{method: :get, path: "/health"}

    assert {:error, :transport_failure} =
             authenticated_request(%{credential_ref: @credential_ref, transport: :invalid}, request)

    assert {:error, :invalid_configuration} =
             authenticated_request(%{credential_ref: @credential_ref}, %{path: "/missing-method"})

    {error_config, error_agent} = transport_config([{:error, :secret_reason}])
    assert {:error, :transport_failure} = authenticated_request(error_config, request)
    Agent.stop(error_agent)

    {other_config, other_agent} = transport_config([:unexpected])
    assert {:error, :transport_failure} = authenticated_request(other_config, request)
    Agent.stop(other_agent)

    {invalid_config, invalid_agent} = transport_config([{:error, :invalid_configuration}])
    assert {:error, :invalid_configuration} = authenticated_request(invalid_config, request)
    assert_receive {:transport_request, %{path: "/health"}}
    Agent.stop(invalid_agent)

    flush_transport_requests()

    {invalid_dispatch_config, invalid_dispatch_agent} = transport_config([{:ok, %{status: 200, headers: %{}, body: :ok}}])

    assert {:error, :transport_failure} =
             authenticated_request(%{invalid_dispatch_config | transport: :invalid}, request)

    refute_receive {:transport_request, _request}
    Agent.stop(invalid_dispatch_agent)
  end

  test "unsafe requests never retry retryable provider responses" do
    for request <- [
          %{method: :get, path: "/never", retry: :never},
          %{method: :post, path: "/post"},
          %{method: :put, path: "/put"},
          %{method: :patch, path: "/patch"}
        ] do
      {config, agent} = transport_config([{:ok, %{status: 503, headers: %{}, body: :busy}}])

      assert {:ok, %{status: 503, body: :busy}} = authenticated_request(config, request)
      assert_receive {:transport_request, dispatched_request}
      assert Map.take(dispatched_request, [:method, :path, :retry]) == request
      refute_receive {:transport_request, _request}
      Agent.stop(agent)
    end
  end

  test "safe reads retry 403 rate limits and normalize list-valued headers" do
    test_pid = self()

    {config, agent} =
      transport_config(
        [
          {:ok,
           %{
             status: 403,
             headers: [{"X-RateLimit-Remaining", ["0", "stale"]}],
             body: :limited
           }},
          {:ok, %{status: 200, headers: :invalid, body: :ready}}
        ],
        retry_sleep: fn delay -> send(test_pid, {:retry_delay, delay}) end
      )

    assert {:ok, %{status: 200, headers: %{}, body: :ready}} =
             authenticated_request(config, %{method: :get, path: "/baseline"})

    assert_receive {:retry_delay, 100}
    assert_receive {:transport_request, %{path: "/baseline"}}
    assert_receive {:transport_request, %{path: "/baseline"}}
    Agent.stop(agent)
  end

  test "retry-after is capped and exhausted rate limits return a normalized error" do
    {config, agent} =
      transport_config(
        [{:ok, %{status: 429, headers: %{"Retry-After" => "99"}, body: "secret"}}],
        settings: %{max_read_attempts: 1}
      )

    assert {:error, {:rate_limited, 5}} =
             authenticated_request(config, %{method: :get, path: "/baseline"})

    Agent.stop(agent)
  end

  test "rate reset and zero-delay fallback paths retry without sleeping externally" do
    test_pid = self()
    reset = Integer.to_string(System.system_time(:second))

    {reset_config, reset_agent} =
      transport_config(
        [
          {:ok, %{status: 504, headers: %{"X-RateLimit-Reset" => reset}, body: :retry}},
          {:ok, %{status: 200, headers: %{}, body: :ok}}
        ],
        retry_sleep: fn delay -> send(test_pid, {:reset_delay, delay}) end
      )

    assert {:ok, %{status: 200}} =
             authenticated_request(reset_config, %{method: :get, path: "/reset"})

    assert_receive {:reset_delay, 0}
    Agent.stop(reset_agent)

    {sleep_config, sleep_agent} =
      transport_config([
        {:ok, %{status: 502, headers: %{"retry-after" => "0"}, body: :retry}},
        {:ok, %{status: 200, headers: %{}, body: :ok}}
      ])

    assert {:ok, %{status: 200}} =
             authenticated_request(sleep_config, %{method: :get, path: "/sleep"})

    Agent.stop(sleep_agent)
  end

  test "exhausted transient failures and malformed attempt settings fail closed" do
    responses =
      for _index <- 1..3 do
        {:ok, %{status: 503, headers: %{}, body: :unavailable}}
      end

    {config, agent} =
      transport_config(responses,
        settings: %{max_read_attempts: 99},
        retry_sleep: fn _delay -> :ok end
      )

    assert {:error, :transport_failure} =
             authenticated_request(config, %{method: :get, path: "/unavailable"})

    Agent.stop(agent)
  end

  test "non-rate-limited 403 responses are returned without retry" do
    {config, agent} =
      transport_config([
        {:ok,
         %{
           status: 403,
           headers: %{"X-RateLimit-Remaining" => "1"},
           body: :forbidden
         }}
      ])

    assert {:ok, %{status: 403, body: :forbidden}} =
             authenticated_request(config, %{method: :get, path: "/forbidden"})

    Agent.stop(agent)
  end

  test "push overrides normalize success and all failure shapes" do
    for {response, expected} <- [
          {{:ok, %{status: 0}}, :ok},
          {:ok, :ok},
          {{:ok, %{status: 1}}, {:error, :transport_failure}},
          {{:error, :secret}, {:error, :transport_failure}},
          {:unexpected, {:error, :transport_failure}}
        ] do
      {config, agent} = transport_config([response])

      assert ^expected =
               Transport.with_credential("push-token", fn ->
                 Transport.push(config, :github, "symphony/ABC-8", @desired_sha, @expected_sha)
               end)

      assert_receive {:transport_request, push_request}
      assert push_request.method == :git_push
      assert push_request.expected_remote_sha == @expected_sha
      assert push_request.headers["authorization"] == "Bearer push-token"
      Agent.stop(agent)
    end

    assert {:error, :transport_failure} =
             Transport.with_credential("push-token", fn ->
               Transport.push(
                 %{credential_ref: @credential_ref, transport: :invalid},
                 :github,
                 "symphony/ABC-8",
                 @desired_sha,
                 @expected_sha
               )
             end)

    assert {:error, :invalid_configuration} =
             Transport.with_credential("push-token", fn ->
               Transport.push(
                 %{credential_ref: @credential_ref, settings: %{workspace: "/missing"}},
                 :github,
                 "symphony/ABC-8",
                 @desired_sha,
                 @expected_sha
               )
             end)
  end

  test "public push without an override dispatches through hardened git transport" do
    context = fake_git_context("remote.origin.url")

    assert :ok =
             Transport.with_credential("push-token", fn ->
               Transport.push(
                 %{credential_ref: @credential_ref, settings: context.config.settings},
                 :github,
                 "valid",
                 @desired_sha,
                 @expected_sha
               )
             end)

    push_env = read_env(context.push_env_path)
    assert push_env["SYMPHONY_GIT_CREDENTIAL"] == "push-token"
    assert "--force-with-lease=refs/heads/valid:#{@expected_sha}" in read_lines(context.args_path)
  end

  test "HTTP transport sends JSON, query parameters, and headers through Req" do
    owner = self()

    Req.default_options(
      plug: fn conn ->
        send(owner, {
          :req_call,
          conn.method,
          conn.host,
          Plug.Conn.get_req_header(conn, "host"),
          conn.request_path,
          conn.query_string,
          Plug.Conn.get_req_header(conn, "x-client"),
          Req.Test.raw_body(conn)
        })

        conn
        |> Plug.Conn.put_resp_header("x-reply", "ok")
        |> Req.Test.json(%{"accepted" => true})
      end
    )

    assert {:ok, response} =
             Transport.with_credential("http-token", fn ->
               Transport.request(
                 %{
                   credential_ref: @credential_ref,
                   settings: %{api_base_url: "https://github.example.test/"}
                 },
                 :github,
                 %{
                   method: :post,
                   path: "/repos/acme/app/issues",
                   headers: %{"x-client" => "symphony"},
                   query: %{"page" => 2},
                   json: %{"title" => "Issue 8"}
                 }
               )
             end)

    assert response.status == 200
    assert response.body == %{"accepted" => true}

    assert_receive {:req_call, "POST", "93.184.216.34", ["github.example.test"], "/repos/acme/app/issues", "page=2", ["symphony"], body}

    assert Jason.decode!(body) == %{"title" => "Issue 8"}
  end

  test "public HTTP requests send only the current provider credential family" do
    owner = self()

    Req.default_options(
      plug: fn conn ->
        send(owner, {:wire_headers, conn.req_headers})
        Req.Test.json(conn, %{"ok" => true})
      end
    )

    config = %{
      credential_ref: @credential_ref,
      settings: %{api_base_url: "https://trusted.example.test"}
    }

    caller_headers = %{
      "Api-Key" => "stale-api-key",
      "Authorization" => "Bearer stale-authorization",
      "Cookie" => "session=stale-cookie",
      "Private-Token" => "stale-private-token",
      "Proxy-Authorization" => "Basic stale-proxy-authorization",
      "Token" => "stale-token",
      "X-Api-Key" => "stale-api-key",
      "X-Client" => "symphony"
    }

    for {provider, expected_header} <- [
          {:github, {"authorization", "Bearer scoped-token"}},
          {:gitlab, {"private-token", "scoped-token"}}
        ] do
      assert {:ok, %{status: 200}} =
               Transport.with_credential("scoped-token", fn ->
                 Transport.request(config, provider, %{
                   method: :get,
                   path: "/health",
                   headers: caller_headers
                 })
               end)

      assert_receive {:wire_headers, headers}

      credential_headers =
        Enum.filter(headers, fn {name, _value} ->
          name in [
            "api-key",
            "authorization",
            "cookie",
            "private-token",
            "proxy-authorization",
            "token",
            "x-api-key"
          ]
        end)

      assert credential_headers == [expected_header]
      assert {"x-client", "symphony"} in headers
      refute Enum.any?(headers, fn {_name, value} -> String.contains?(value, "stale-") end)
    end
  end

  test "HTTP endpoint routing covers GraphQL, REST, GitLab, and string-key settings" do
    owner = self()

    Req.default_options(
      plug: fn conn ->
        send(owner, {:req_route, conn.host, Plug.Conn.get_req_header(conn, "host"), conn.request_path})
        Req.Test.json(conn, %{"ok" => true})
      end
    )

    assert {:ok, %{status: 200}} =
             HTTP.request(
               %{settings: %{graphql_base_url: "https://graphql.example.test"}},
               :github,
               %{method: :get, path: "/graphql"}
             )

    assert_receive {:req_route, "93.184.216.34", ["graphql.example.test"], "/graphql"}

    assert {:ok, %{status: 200}} =
             HTTP.request(
               %{settings: %{api_base_url: "https://rest.example.test"}},
               :github,
               %{method: :get, path: "/repos/acme/app"}
             )

    assert_receive {:req_route, "93.184.216.34", ["rest.example.test"], "/repos/acme/app"}

    assert {:ok, %{status: 200}} =
             HTTP.request(
               %{"settings" => %{"api_base_url" => "https://gitlab.example.test/api/v4"}},
               :gitlab,
               %{method: :get, path: "/projects/8"}
             )

    assert_receive {:req_route, "93.184.216.34", ["gitlab.example.test"], "/api/v4/projects/8"}

    assert {:ok, %{status: 200}} =
             HTTP.request(%{settings: %{}}, :github, %{method: :get, path: "/rate_limit"})

    assert_receive {:req_route, _address, ["api.github.com"], "/rate_limit"}

    assert {:ok, %{status: 200}} =
             HTTP.request(%{}, :gitlab, %{method: :get, path: "/version"})

    assert_receive {:req_route, _address, ["gitlab.com"], "/api/v4/version"}

    assert {:ok, %{status: 200}} =
             HTTP.request(
               %{settings: %{api_base_url: "https://graphql-fallback.example.test"}},
               :github,
               %{method: :get, path: "/graphql"}
             )

    assert_receive {:req_route, "93.184.216.34", ["graphql-fallback.example.test"], "/graphql"}

    Application.put_env(:symphony_elixir, :source_control_trusted_origins, :invalid)

    assert {:ok, %{status: 200}} =
             HTTP.request(%{settings: %{}}, :github, %{method: :get, path: "/rate_limit"})

    assert_receive {:req_route, _address, ["api.github.com"], "/rate_limit"}

    assert {:ok, %{status: 200}} =
             HTTP.request(%{}, :gitlab, %{method: :get, path: "/version"})

    assert_receive {:req_route, _address, ["gitlab.com"], "/api/v4/version"}
  end

  test "HTTP transport rejects unsafe endpoints and normalizes Req failures" do
    for endpoint <- [
          "http://git.example.test",
          "https://user@git.example.test",
          "https://git.example.test?token=secret",
          "https://git.example.test#fragment",
          "https:///missing-host",
          :not_a_url
        ] do
      assert {:error, :invalid_configuration} =
               HTTP.request(
                 %{settings: %{api_base_url: endpoint}},
                 :gitlab,
                 %{method: :get, path: "/version"}
               )
    end

    Req.default_options(plug: &Req.Test.transport_error(&1, :timeout))

    assert {:error, :transport_failure} =
             HTTP.request(
               %{settings: %{api_base_url: "https://git.example.test"}},
               :gitlab,
               %{method: :get, path: "/version"}
             )
  end

  test "public HTTP seam rejects host-changing and non-canonical request paths before Req" do
    owner = self()

    Req.default_options(
      plug: fn conn ->
        send(owner, {:unexpected_request, conn.host, conn.request_path})
        Req.Test.json(conn, %{"leaked" => true})
      end
    )

    config = %{
      credential_ref: @credential_ref,
      settings: %{api_base_url: "https://trusted.example.test"}
    }

    unsafe_paths = [
      "@evil.example.test/leak",
      "//evil.example.test/leak",
      "/%2F%2Fevil.example.test/leak",
      "/%40evil.example.test/leak",
      "/\\evil.example.test/leak",
      "/%00leak",
      "/%FFleak",
      "/repos/../leak",
      "/repos/%ZZ/leak",
      :not_a_path
    ]

    for path <- unsafe_paths do
      assert {:error, :invalid_configuration} =
               Transport.with_credential("never-leaked", fn ->
                 Transport.request(config, :github, %{method: :get, path: path})
               end)

      refute_receive {:unexpected_request, _host, _path}
    end

    assert {:error, :invalid_configuration} =
             HTTP.request(
               %{settings: %{api_base_url: "https://trusted.example.test"}},
               :github,
               %{
                 method: :get,
                 path: "/%FFleak",
                 headers: %{"authorization" => "Bearer direct-boundary-secret"}
               }
             )

    refute_receive {:unexpected_request, _host, _path}

    assert {:error, :invalid_configuration} =
             HTTP.request(
               %{settings: %{api_base_url: "https://trusted.example.test"}},
               :github,
               %{method: :get, path: :not_a_path}
             )

    assert {:error, :invalid_configuration} =
             HTTP.request(
               %{settings: %{api_base_url: "https://trusted.example.test"}},
               :github,
               %{method: :get, path: "/@evil.example.test/leak"}
             )

    {override_config, override_agent} =
      transport_config([{:ok, %{status: 200, headers: %{}, body: %{leaked: true}}}])

    assert {:error, :invalid_configuration} =
             Transport.with_credential("never-injected", fn ->
               Transport.request(override_config, :github, %{method: :get, path: "/%FFleak"})
             end)

    refute_receive {:transport_request, _request}
    Agent.stop(override_agent)
  end

  test "public HTTP seam pins trusted origins and never follows credential-bearing redirects" do
    owner = self()

    Req.default_options(
      plug: fn conn ->
        send(
          owner,
          {:req_call, conn.host, Plug.Conn.get_req_header(conn, "host"), conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
        )

        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.example.test/leak")
        |> Plug.Conn.send_resp(302, "")
      end
    )

    config = %{
      credential_ref: @credential_ref,
      settings: %{
        api_base_url: "https://trusted.example.test",
        endpoint_trusted_origins: ["https://trusted.example.test"],
        endpoint_resolver: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end
      }
    }

    assert {:ok, %{status: 302}} =
             Transport.with_credential("redirect-token", fn ->
               Transport.request(config, :github, %{method: :get, path: "/repos/acme/app"})
             end)

    assert_receive {:req_call, "93.184.216.34", ["trusted.example.test"], "/repos/acme/app", ["Bearer redirect-token"]}
    refute_receive {:req_call, "attacker.example.test", _host_header, _path, _authorization}

    untrusted_config =
      put_in(config, [:settings, :api_base_url], "https://attacker.example.test")

    assert {:error, :invalid_configuration} =
             Transport.with_credential("never-leaked", fn ->
               Transport.request(untrusted_config, :github, %{method: :get, path: "/repos/acme/app"})
             end)

    private_address_config =
      put_in(config, [:settings, :endpoint_resolver], fn _host, _family -> {:ok, [{127, 0, 0, 1}]} end)

    assert {:error, :invalid_configuration} =
             Transport.with_credential("never-leaked", fn ->
               Transport.request(private_address_config, :github, %{method: :get, path: "/repos/acme/app"})
             end)

    refute_receive {:req_call, _host, _host_header, _path, ["never-leaked"]}
  end

  test "fake git subprocess keeps credentials out of hooks, argv, and local config" do
    context = fake_git_context("remote.origin.url\ncore.repositoryformatversion")
    token = "credential-available-only-to-helper"

    assert :ok =
             Git.push(
               context.config,
               :github,
               "symphony/ABC-8",
               @desired_sha,
               @expected_sha,
               token
             )

    args = read_lines(context.args_path)
    push_env = read_env(context.push_env_path)
    config_env = read_env(context.config_env_path)

    config_pairs = Enum.chunk_every(args, 2, 1, :discard)

    for setting <- [
          "core.hooksPath=/dev/null",
          "credential.helper=",
          "credential.useHttpPath=true",
          "credential.interactive=false",
          "http.followRedirects=false",
          "http.sslVerify=true",
          "http.curloptResolve=+code.example.test:443:93.184.216.34"
        ] do
      assert ["-c", setting] in config_pairs
    end

    helper = Enum.find(args, &String.starts_with?(&1, "credential.helper=!f()"))
    assert helper =~ "SYMPHONY_GIT_CREDENTIAL"
    assert helper =~ "SYMPHONY_GIT_HOST"
    refute helper =~ token

    assert "--force-with-lease=refs/heads/symphony/ABC-8:#{@expected_sha}" in args
    assert "#{@desired_sha}:refs/heads/symphony/ABC-8" in args
    assert "https://code.example.test/acme/app.git" in args
    refute Enum.any?(args, &String.contains?(&1, token))

    assert push_env["SYMPHONY_GIT_CREDENTIAL"] == token
    assert push_env["SYMPHONY_GIT_USERNAME"] == "x-access-token"
    assert push_env["SYMPHONY_GIT_HOST"] == "code.example.test"
    assert push_env["GIT_TERMINAL_PROMPT"] == "0"
    assert push_env["GIT_CONFIG_NOSYSTEM"] == "1"
    assert push_env["GIT_CONFIG_GLOBAL"] == "/dev/null"

    assert Enum.filter(push_env, fn {_key, value} -> value == token end) == [
             {"SYMPHONY_GIT_CREDENTIAL", token}
           ]

    for key <- ~w(
          GIT_ASKPASS SSH_ASKPASS GIT_PROXY_COMMAND
          HTTP_PROXY HTTPS_PROXY ALL_PROXY
          http_proxy https_proxy all_proxy
        ) do
      refute Map.has_key?(push_env, key)
    end

    refute Map.has_key?(config_env, "SYMPHONY_GIT_CREDENTIAL")
    refute File.exists?(context.hook_leak_path)
    refute File.exists?(context.config_leak_path)
  end

  test "normal remote config is allowed and GitLab credentials bind to the HTTPS host and port" do
    context = fake_git_context("remote.origin.url")

    config = %{
      "settings" => %{
        "workspace" => context.workspace,
        "remote_url" => "https://gitlab.example.test:8443/group/project.git",
        "repository" => "group/project"
      }
    }

    assert :ok = Git.push(config, :gitlab, "feature/ABC-8", @desired_sha, @expected_sha, "token")

    push_env = read_env(context.push_env_path)
    assert push_env["SYMPHONY_GIT_USERNAME"] == "oauth2"
    assert push_env["SYMPHONY_GIT_HOST"] == "gitlab.example.test:8443"

    Application.put_env(:symphony_elixir, :source_control_git_trusted_origins, :invalid)

    default_config = %{
      settings: %{
        workspace: context.workspace,
        remote_url: "https://github.com/acme/app.git",
        repository: "acme/app",
        git_endpoint_resolver: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end
      }
    }

    assert :ok = Git.push(default_config, :github, "feature/ABC-8", @desired_sha, @expected_sha, "token")

    gitlab_default_config = %{
      settings: %{
        workspace: context.workspace,
        remote_url: "https://gitlab.com/group/project.git",
        repository: "group/project",
        git_endpoint_resolver: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end
      }
    }

    assert :ok =
             Git.push(
               gitlab_default_config,
               :gitlab,
               "feature/ABC-8",
               @desired_sha,
               @expected_sha,
               "token"
             )
  end

  test "git push binds normalized HTTPS remote path to provider repository settings" do
    context = fake_git_context("remote.origin.url")

    github_config =
      put_in(
        context.config,
        [:settings, :remote_url],
        "https://code.example.test/acme%2Fapp.git"
      )

    assert :ok = Git.push(github_config, :github, "valid", @desired_sha, @expected_sha, "token")
    assert "https://code.example.test/acme/app.git" in read_lines(context.args_path)

    gitlab_config = %{
      settings: %{
        workspace: context.workspace,
        remote_url: "https://gitlab.example.test:8443/group/subgroup/project.git",
        repository: "group/subgroup/project",
        git_trusted_origins: ["https://gitlab.example.test:8443"],
        git_endpoint_resolver: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end
      }
    }

    assert :ok = Git.push(gitlab_config, :gitlab, "valid", @desired_sha, @expected_sha, "token")

    assert {:error, :invalid_configuration} =
             Git.push(
               put_in(context.config, [:settings, :repository], "acme/nested/app"),
               :github,
               "valid",
               @desired_sha,
               @expected_sha,
               "token"
             )

    for {provider, config} <- [
          {:github, put_in(context.config, [:settings, :repository], nil)},
          {:github, put_in(context.config, [:settings, :repository], "other/app")},
          {:github, put_in(context.config, [:settings, :remote_url], "https://code.example.test/acme//app.git")},
          {:github, put_in(context.config, [:settings, :remote_url], "https://code.example.test/acme%5Capp.git")},
          {:github, put_in(context.config, [:settings, :remote_url], "https://code.example.test/acme/app/extra.git")},
          {:github, put_in(context.config, [:settings, :remote_url], "https://code.example.test/acme/app.git#secret")},
          {:github, put_in(context.config, [:settings, :remote_url], "git@code.example.test:acme/app.git")},
          {:gitlab, %{gitlab_config | settings: %{gitlab_config.settings | repository: "group/other"}}},
          {:gitlab, %{gitlab_config | settings: %{gitlab_config.settings | remote_url: "https://gitlab.example.test:8443/group/subgroup/project/extra.git"}}}
        ] do
      assert {:error, :invalid_configuration} =
               Git.push(config, provider, "valid", @desired_sha, @expected_sha, "token")
    end
  end

  test "executable and redirection-capable local git config is rejected before token exposure" do
    context = fake_git_context("remote.origin.url")

    dangerous_keys = [
      "include.path",
      "url.https://attacker.invalid/.insteadOf",
      "http.proxy",
      "credential.helper",
      "protocol.ext.allow",
      "uploadpack.command",
      "receive.denyCurrentBranch",
      "core.hooksPath",
      "core.fsMonitor",
      "core.sshCommand",
      "remote.origin.proxy",
      "remote.origin.proxyAuthMethod",
      "remote.origin.vcs",
      "remote.origin.uploadPack",
      "remote.origin.receivePack"
    ]

    for key <- dangerous_keys do
      System.put_env("SYMPHONY_TEST_CONFIG_KEYS", key)

      assert {:error, :invalid_configuration} =
               Git.push(
                 context.config,
                 :github,
                 "symphony/ABC-8",
                 @desired_sha,
                 @expected_sha,
                 "never-exposed-token"
               )

      refute read_env(context.config_env_path)["SYMPHONY_GIT_CREDENTIAL"]
      refute File.exists?(context.config_leak_path)
    end

    refute File.exists?(context.args_path)
  end

  test "git validation and subprocess failures fail closed" do
    context = fake_git_context("remote.origin.url")

    invalid_configs = [
      %{settings: %{workspace: "/missing", remote_url: "https://code.example.test/repo.git"}},
      %{settings: %{workspace: context.workspace, remote_url: :not_a_url}},
      %{settings: %{workspace: context.workspace, remote_url: "http://code.example.test/repo.git"}},
      %{
        settings: %{
          workspace: context.workspace,
          remote_url: "https://user@code.example.test/repo.git"
        }
      },
      %{
        settings: %{
          workspace: context.workspace,
          remote_url: "https://code.example.test/repo.git?credential=bad"
        }
      },
      %{
        settings: %{
          workspace: context.workspace,
          remote_url: "https://attacker.example.test/repo.git",
          git_trusted_origins: ["https://code.example.test"],
          git_endpoint_resolver: fn _host, _family -> flunk("untrusted git remotes must not reach DNS") end
        }
      },
      %{
        settings: %{
          workspace: context.workspace,
          remote_url: "https://code.example.test/repo.git",
          git_trusted_origins: ["https://code.example.test"],
          git_endpoint_resolver: fn _host, _family -> {:ok, [{10, 0, 0, 1}]} end
        }
      }
    ]

    for config <- invalid_configs do
      assert {:error, :invalid_configuration} =
               Git.push(
                 config,
                 :github,
                 "symphony/ABC-8",
                 @desired_sha,
                 @expected_sha,
                 "token"
               )
    end

    for branch <- [:not_a_branch, "bad..branch", "bad//branch", "bad@{branch", "bad/", "bad.lock"] do
      assert {:error, :invalid_configuration} =
               Git.push(context.config, :github, branch, @desired_sha, @expected_sha, "token")
    end

    assert {:error, :invalid_configuration} =
             Git.push(context.config, :github, "valid", "short", @expected_sha, "token")

    assert {:error, :invalid_configuration} =
             Git.push(context.config, :github, "valid", @desired_sha, @expected_sha, :not_a_token)

    System.put_env("SYMPHONY_TEST_CONFIG_STATUS", "2")

    assert {:error, :invalid_configuration} =
             Git.push(context.config, :github, "valid", @desired_sha, @expected_sha, "token")

    System.put_env("SYMPHONY_TEST_CONFIG_STATUS", "0")
    System.put_env("SYMPHONY_TEST_PUSH_STATUS", "9")

    assert {:error, :transport_failure} =
             Git.push(context.config, :github, "valid", @desired_sha, @expected_sha, "token")

    put_env_on_exit("SYMPHONY_TEST_CONFIG_SLEEP", "1")
    config_command_error = put_in(context.config, [:settings, :git_timeout_ms], 10)

    assert {:error, :invalid_configuration} =
             Git.push(config_command_error, :github, "valid", @desired_sha, @expected_sha, "token")
  end

  test "git command exceptions are redacted as transport failures" do
    context = fake_git_context("remote.origin.url")

    assert {:error, :transport_failure} =
             Git.push(%{settings: :not_a_map}, :github, "valid", @desired_sha, @expected_sha, "token")

    assert {:error, :invalid_configuration} =
             Git.push(
               context.config,
               :github,
               "valid",
               @desired_sha,
               @expected_sha,
               "malformed\0credential"
             )

    put_env_on_exit("SYMPHONY_TEST_REMOVE_WORKSPACE", "1")

    assert {:error, :transport_failure} =
             Git.push(
               context.config,
               :github,
               "valid",
               @desired_sha,
               @expected_sha,
               "well-formed-token"
             )

    refute File.dir?(context.workspace)
  end

  test "git push timeout terminates TERM-ignoring descendants" do
    context = fake_git_context("remote.origin.url")
    parent_pid_file = Path.join(context.root, "git-parent.pid")
    child_pid_file = Path.join(context.root, "git-child.pid")
    test_pid = self()

    put_env_on_exit("SYMPHONY_TEST_PUSH_PARENT_PID", parent_pid_file)
    put_env_on_exit("SYMPHONY_TEST_PUSH_CHILD_PID", child_pid_file)

    config = put_in(context.config, [:settings, :git_timeout_ms], 2_000)

    spawn(fn ->
      send(
        test_pid,
        {:git_push_result, Git.push(config, :github, "valid", @desired_sha, @expected_sha, "token")}
      )
    end)

    parent_pid = eventually_value(fn -> read_pid(parent_pid_file) end)
    child_pid = eventually_value(fn -> read_pid(child_pid_file) end)
    assert parent_pid != child_pid

    assert_receive {:git_push_result, {:error, :transport_failure}}, 8_000
    refute_os_process_alive(parent_pid)
    refute_os_process_alive(child_pid)
  end

  test "git push caller death terminates TERM-ignoring descendants" do
    context = fake_git_context("remote.origin.url")
    parent_pid_file = Path.join(context.root, "git-parent.pid")
    child_pid_file = Path.join(context.root, "git-child.pid")

    put_env_on_exit("SYMPHONY_TEST_PUSH_PARENT_PID", parent_pid_file)
    put_env_on_exit("SYMPHONY_TEST_PUSH_CHILD_PID", child_pid_file)

    config = put_in(context.config, [:settings, :git_timeout_ms], 60_000)

    runner =
      spawn(fn ->
        Git.push(config, :github, "valid", @desired_sha, @expected_sha, "token")
      end)

    parent_pid = eventually_value(fn -> read_pid(parent_pid_file) end)
    child_pid = eventually_value(fn -> read_pid(child_pid_file) end)
    owner = eventually_value(fn -> monitored_process(runner) end)
    assert parent_pid != child_pid
    assert is_pid(owner)

    ref = Process.monitor(runner)
    owner_ref = Process.monitor(owner)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 8_000

    refute_os_process_alive(parent_pid)
    refute_os_process_alive(child_pid)
  end

  test "git command owner reports crashes and enforces its outer timeout" do
    assert {:error, :forced_crash} =
             Git.run_owned_for_test(fn _caller_ref -> exit(:forced_crash) end, 100)

    assert {:error, :timeout} =
             Git.run_owned_for_test(fn _caller_ref -> Process.sleep(:infinity) end, 10)
  end

  test "git command owner preserves fast crash reasons under repeated races" do
    for _attempt <- 1..100 do
      assert {:error, :forced_crash} =
               Git.run_owned_for_test(fn _caller_ref -> exit(:forced_crash) end, 100)
    end
  end

  defp authenticated_request(config, request) do
    Transport.with_credential("scoped-token", fn ->
      Transport.request(config, :github, request)
    end)
  end

  defp flush_transport_requests do
    receive do
      {:transport_request, _request} -> flush_transport_requests()
    after
      0 -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp monitored_process(pid) do
    case Process.info(pid, :monitors) do
      {:monitors, monitors} ->
        Enum.find_value(monitors, fn
          {:process, monitored_pid} -> monitored_pid
          _other -> nil
        end)

      nil ->
        nil
    end
  end

  defp transport_config(responses, options \\ []) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    settings = Keyword.get(options, :settings, %{})

    config = %{
      credential_ref: @credential_ref,
      settings: settings,
      transport: {SequenceTransport, {self(), agent}}
    }

    config =
      case Keyword.fetch(options, :retry_sleep) do
        {:ok, retry_sleep} -> Map.put(config, :retry_sleep, retry_sleep)
        :error -> config
      end

    {config, agent}
  end

  defp fake_git_context(config_keys) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-source-control-git-#{System.unique_integer([:positive, :monotonic])}"
      )

    bin = Path.join(root, "bin")
    workspace = Path.join(root, "workspace")
    hooks = Path.join(workspace, ".git/hooks")
    File.mkdir_p!(bin)
    File.mkdir_p!(hooks)

    git_path = Path.join(bin, "git")
    args_path = Path.join(root, "push-args")
    push_env_path = Path.join(root, "push-env")
    config_env_path = Path.join(root, "config-env")
    hook_leak_path = Path.join(root, "hook-leak")
    config_leak_path = Path.join(root, "config-leak")

    File.write!(git_path, fake_git_script())
    File.chmod!(git_path, 0o700)

    hook_path = Path.join(hooks, "pre-push")

    File.write!(
      hook_path,
      "#!/bin/sh\nprintf '%s' \"${SYMPHONY_GIT_CREDENTIAL:-}\" > \"$SYMPHONY_TEST_HOOK_LEAK\"\n"
    )

    File.chmod!(hook_path, 0o700)

    values = %{
      "PATH" => bin <> ":" <> (System.get_env("PATH") || ""),
      "SYMPHONY_TEST_ARGS" => args_path,
      "SYMPHONY_TEST_PUSH_ENV" => push_env_path,
      "SYMPHONY_TEST_CONFIG_ENV" => config_env_path,
      "SYMPHONY_TEST_HOOK_LEAK" => hook_leak_path,
      "SYMPHONY_TEST_CONFIG_LEAK" => config_leak_path,
      "SYMPHONY_TEST_CONFIG_KEYS" => config_keys,
      "SYMPHONY_TEST_CONFIG_STATUS" => "0",
      "SYMPHONY_TEST_PUSH_STATUS" => "0",
      "SYMPHONY_TEST_REMOVE_WORKSPACE" => "0",
      "GIT_ASKPASS" => "/tmp/credential-stealer",
      "SSH_ASKPASS" => "/tmp/credential-stealer",
      "GIT_PROXY_COMMAND" => "/tmp/proxy-stealer",
      "HTTP_PROXY" => "http://attacker.invalid",
      "HTTPS_PROXY" => "http://attacker.invalid",
      "ALL_PROXY" => "http://attacker.invalid",
      "http_proxy" => "http://attacker.invalid",
      "https_proxy" => "http://attacker.invalid",
      "all_proxy" => "http://attacker.invalid",
      "GIT_CONFIG_NOSYSTEM" => "0",
      "GIT_CONFIG_GLOBAL" => "/tmp/attacker-gitconfig"
    }

    preserve_environment(values)

    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      workspace: workspace,
      args_path: args_path,
      push_env_path: push_env_path,
      config_env_path: config_env_path,
      hook_leak_path: hook_leak_path,
      config_leak_path: config_leak_path,
      config: %{
        settings: %{
          workspace: workspace,
          remote_url: "https://code.example.test/acme/app.git",
          repository: "acme/app",
          git_trusted_origins: ["https://code.example.test"],
          git_endpoint_resolver: fn _host, _family -> {:ok, [{93, 184, 216, 34}]} end
        }
      }
    }
  end

  defp preserve_environment(values) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)
    Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  defp put_env_on_exit(key, value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(key)
        previous -> System.put_env(key, previous)
      end
    end)
  end

  defp fake_git_script do
    """
    #!/bin/sh
    set -eu

    if [ "${1:-}" = "config" ]; then
      /usr/bin/env > "$SYMPHONY_TEST_CONFIG_ENV"

      if [ -n "${SYMPHONY_GIT_CREDENTIAL:-}" ]; then
        printf '%s' "$SYMPHONY_GIT_CREDENTIAL" > "$SYMPHONY_TEST_CONFIG_LEAK"
      fi

      if [ "${SYMPHONY_TEST_REMOVE_WORKSPACE:-0}" = "1" ]; then
        /bin/rm -rf "$PWD"
      fi

      if [ "${SYMPHONY_TEST_CONFIG_SLEEP:-0}" = "1" ]; then
        while :; do sleep 1; done
      fi

      printf '%s\n' "${SYMPHONY_TEST_CONFIG_KEYS:-}"
      exit "${SYMPHONY_TEST_CONFIG_STATUS:-0}"
    fi

    : > "$SYMPHONY_TEST_ARGS"
    for argument in "$@"; do
      printf '%s\n' "$argument" >> "$SYMPHONY_TEST_ARGS"
    done

    if [ -n "${SYMPHONY_TEST_PUSH_PARENT_PID:-}" ] && [ -n "${SYMPHONY_TEST_PUSH_CHILD_PID:-}" ]; then
      printf '%s\n' "$$" > "$SYMPHONY_TEST_PUSH_PARENT_PID"
      (
        trap '' TERM
        while :; do sleep 1; done
      ) &
      child_pid=$!
      printf '%s\n' "$child_pid" > "$SYMPHONY_TEST_PUSH_CHILD_PID"
      wait "$child_pid"
    fi

    /usr/bin/env > "$SYMPHONY_TEST_PUSH_ENV"
    hooks_disabled=0

    for argument in "$@"; do
      if [ "$argument" = "core.hooksPath=/dev/null" ]; then
        hooks_disabled=1
      fi
    done

    if [ "$hooks_disabled" = "0" ] && [ -x "$PWD/.git/hooks/pre-push" ]; then
      "$PWD/.git/hooks/pre-push"
    fi

    exit "${SYMPHONY_TEST_PUSH_STATUS:-0}"
    """
  end

  defp read_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp read_env(path) do
    path
    |> read_lines()
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> [{key, value}]
        [_continuation] -> []
      end
    end)
    |> Map.new()
  end

  defp read_pid(path) do
    case File.read(path) do
      {:ok, pid} ->
        pid
        |> String.trim()
        |> Integer.parse()
        |> case do
          {pid, ""} -> pid
          _invalid -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp refute_os_process_alive(pid) when is_integer(pid) do
    assert eventually_value(fn ->
             if not os_process_alive?(pid), do: true
           end),
           "expected OS process #{pid} to stop"
  end

  defp eventually_value(fun, attempts \\ 200)
  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(20)
        eventually_value(fun, attempts - 1)

      false ->
        Process.sleep(20)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
