defmodule SymphonyElixir.TrackerContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport
  alias SymphonyElixir.TrackerContract.Broker

  test "contract broker reports missing process-local secrets without invoking callback" do
    callback = fn _plaintext -> flunk("missing broker secret must not invoke callback") end

    assert {:error, :not_found} =
             Broker.with_secret("missing-tracker-reference", :tracker_health, callback)

    assert_received {:tracker_broker_called, "missing-tracker-reference", :tracker_health}
  end

  defmodule ErrorBroker do
    @moduledoc false

    def with_secret(_reference, _purpose, _callback) do
      {:error, Process.get({__MODULE__, :reason})}
    end
  end

  defmodule RaisingBroker do
    @moduledoc false

    def with_secret(_reference, _purpose, _callback), do: raise("broker failed")
  end

  defmodule ThrowingBroker do
    @moduledoc false

    def with_secret(_reference, _purpose, _callback), do: throw(:broker_failed)
  end

  test "health_check/1 dispatches a deterministic fixture through the public tracker seam" do
    config = %{
      "provider" => "fixture",
      "settings" => %{"scenario" => "healthy"}
    }

    assert {:ok,
            %{
              provider: "fixture",
              status: :healthy,
              evidence: %{
                transport: :deterministic_fixture,
                credentials: :verified,
                scope: :verified,
                issue_read: :verified,
                state_mappings: :verified,
                comment_permissions: :verified
              }
            }} = Tracker.health_check(config)
  end

  test "fixture health scenario deterministically proves a failed activation probe" do
    assert {:error, %{provider: "fixture", code: :fixture_unhealthy, retryable: false}} =
             Tracker.health_check(%{
               "provider" => "fixture",
               "settings" => %{"scenario" => "unhealthy"}
             })
  end

  test "health strips runtime-only credentials from config and rejects plaintext evidence" do
    credential = "runtime-only-api-secret"
    webhook_secret = "runtime-only-webhook-secret"

    config = %{
      "provider" => "fixture",
      "credential" => credential,
      "webhook_secret" => webhook_secret,
      "settings" => %{"scenario" => "healthy"}
    }

    assert {:ok, evidence} = Tracker.health_check(config, health_observer: self())

    assert_receive {:fixture_health_called, received_config, received_opts}
    assert received_opts[:credential] == credential
    assert received_opts[:webhook_secret] == webhook_secret

    refute Map.has_key?(received_config, "credential")
    refute Map.has_key?(received_config, "webhook_secret")
    refute inspect(evidence) =~ credential
    refute inspect(evidence) =~ webhook_secret

    assert {:error, %{code: :unsafe_provider_response, retryable: false} = error} =
             Tracker.health_check(put_in(config, ["settings", "scenario"], "echo_runtime_secrets"))

    refute inspect(error) =~ credential
    refute inspect(error) =~ webhook_secret

    assert {:error, %{code: :unsafe_provider_response}} =
             Tracker.health_check(put_in(config, ["settings", "scenario"], "echo_runtime_secret_list"))
  end

  test "public normalized Tracker calls reject malformed arguments consistently" do
    assert {:error, %{provider: nil, code: :invalid_config}} = Tracker.health_check(:invalid)

    assert {:error, %{provider: nil, code: :invalid_request}} =
             Tracker.fetch_eligible(%{}, :invalid)

    assert {:error, %{provider: nil, code: :invalid_request}} =
             Tracker.fetch_by_ids(%{}, :invalid)

    assert {:error, %{provider: nil, code: :invalid_request}} =
             Tracker.normalize_webhook(%{}, :invalid)

    assert {:error, %{provider: nil, code: :invalid_request}} =
             Tracker.transition_issue(%{}, :invalid, :closed)

    assert {:error, %{provider: nil, code: :invalid_request}} =
             Tracker.upsert_progress(%{}, :invalid, "progress")

    assert {:error, %{provider: nil, code: :invalid_request}} =
             Tracker.append_final_summary(%{}, "FIX-1", :invalid)

    assert {:error, %{provider: nil, code: :missing_provider}} =
             Tracker.health_check(%{settings: %{}})

    assert {:error, %{provider: "unknown", code: :unsupported_provider}} =
             Tracker.health_check(%{provider: "unknown", settings: %{}})

    assert {:error, %{provider: "github", code: :invalid_config}} =
             Tracker.health_check(%{
               provider: "github",
               credential_ref: "00000000-0000-4000-8000-000000000111",
               settings: :invalid
             })
  end

  test "fixture validation and adapter failures remain normalized" do
    assert {:error, %{provider: "fixture", code: :invalid_config}} =
             Tracker.health_check(%{provider: "fixture", settings: :invalid})

    for {scenario, code} <- [{"raise", :adapter_failed}, {"throw", :adapter_failed}] do
      assert {:error, %{provider: "fixture", code: ^code, retryable: false}} =
               Tracker.health_check(%{provider: "fixture", settings: %{scenario: scenario}})
    end

    assert {:ok, %{external_comment_id: "fixture-progress-FIX-1"}} =
             Tracker.upsert_progress(%{provider: "fixture", settings: %{}}, "FIX-1", "progress")

    assert {:ok, %{external_comment_id: "fixture-final-FIX-1"}} =
             Tracker.append_final_summary(
               %{provider: "fixture", settings: %{}},
               "FIX-1",
               "summary"
             )

    assert {:ok, %{kind: :issue}} =
             Tracker.normalize_webhook(
               %{provider: "fixture", settings: %{}},
               %{body: %{event_id: "event-1", issue_id: "FIX-1", kind: 123}}
             )
  end

  test "credential broker failures, raises, and throws are redacted by the facade" do
    {config, _credential_ref} = github_config()
    handler = fn _request -> flunk("broker failures must not reach transport") end

    for {reason, expected_code} <- [
          {:not_found, :credential_unavailable},
          {:plaintext_returned, :unsafe_provider_response},
          {:unexpected, :adapter_failed}
        ] do
      Process.put({ErrorBroker, :reason}, reason)

      assert {:error, %{provider: "github", code: ^expected_code, retryable: false}} =
               Tracker.fetch_by_ids(
                 config,
                 ["1"],
                 github_opts(
                   credential_broker: ErrorBroker,
                   transport: {Transport, handler: handler}
                 )
               )
    end

    for {broker, expected_code} <- [
          {RaisingBroker, :credential_unavailable},
          {ThrowingBroker, :credential_unavailable}
        ] do
      assert {:error, %{provider: "github", code: ^expected_code, retryable: false}} =
               Tracker.fetch_by_ids(
                 config,
                 ["1"],
                 github_opts(
                   credential_broker: broker,
                   transport: {Transport, handler: handler}
                 )
               )
    end
  end

  test "fetch_eligible/2 applies the complete provider-neutral eligibility rule" do
    config = %{
      "provider" => "fixture",
      "settings" => %{
        "issues" => [
          %{
            "id" => "eligible",
            "identifier" => "FIX-1",
            "title" => "Eligible",
            "state" => "Open",
            "labels" => ["Ready-For-Agent", "backend"],
            "assignee_id" => "worker-1",
            "blocked_by" => [%{"external_id" => "BLOCK-1", "completed?" => false}]
          },
          %{
            "id" => "wrong-label",
            "identifier" => "FIX-2",
            "title" => "Wrong label",
            "state" => "Open",
            "labels" => ["backend"],
            "assignee_id" => "worker-1"
          },
          %{
            "id" => "wrong-assignee",
            "identifier" => "FIX-3",
            "title" => "Wrong assignee",
            "state" => "Open",
            "labels" => ["ready-for-agent"],
            "assignee_id" => "worker-2"
          },
          %{
            "id" => "delivery-artifact",
            "identifier" => "FIX-4",
            "title" => "Pull request",
            "state" => "Open",
            "labels" => ["ready-for-agent", "backend"],
            "assignee_id" => "worker-1",
            "dispatchable" => false
          }
        ]
      }
    }

    assert {:ok,
            [
              %SymphonyElixir.Tracker.Issue{
                id: "eligible",
                dispatchable: true,
                blocked_by: [%{"external_id" => "BLOCK-1", "completed?" => false}]
              }
            ]} =
             Tracker.fetch_eligible(config, %{
               "states" => ["open"],
               "required_labels" => ["ready-for-agent"],
               "assignee_id" => "worker-1"
             })
  end

  test "fetch_by_ids/2 returns normalized issues in requested order" do
    created_at = ~U[2026-07-20 00:00:00Z]
    updated_at = ~U[2026-07-20 00:01:00Z]

    config = %{
      provider: "fixture",
      settings: %{
        issues: [
          %{
            id: "a",
            native_ref: %{provider: "fixture", id: "native-a"},
            identifier: "FIX-1",
            title: "First",
            state: "open",
            created_at: created_at,
            updated_at: updated_at
          },
          %{id: "b", identifier: "FIX-2", title: "Second", state: "open"}
        ]
      }
    }

    assert {:ok,
            [
              %SymphonyElixir.Tracker.Issue{id: "b", identifier: "FIX-2"},
              %SymphonyElixir.Tracker.Issue{
                id: "a",
                identifier: "FIX-1",
                native_ref: %{provider: "fixture", id: "native-a"},
                created_at: ^created_at,
                updated_at: ^updated_at
              }
            ]} = Tracker.fetch_by_ids(config, ["b", "missing", "a"])
  end

  test "fixture adapter implements the complete mutation and reconciliation contract" do
    config = %{provider: "fixture", settings: %{}}

    {:ok, fixture_state} = Agent.start_link(fn -> %{} end)

    opts = [fixture_state: fixture_state]

    assert {:ok, %{kind: :issue, reconciliation_key: "fixture:event-1"}} =
             Tracker.normalize_webhook(config, %{
               body: %{event_id: "event-1", issue_id: "FIX-1", action: "updated"}
             })

    assert {:ok, %{state: "closed"}} = Tracker.transition_issue(config, "FIX-1", :closed)

    assert {:ok,
            %{
              action: :created,
              external_id: "fixture-progress-FIX-1",
              external_comment_id: "fixture-progress-FIX-1"
            } = first_progress} =
             Tracker.upsert_progress(config, "FIX-1", "running", Keyword.put(opts, :operation_id, "progress-1"))

    assert {:ok, ^first_progress} =
             Tracker.upsert_progress(config, "FIX-1", "ignored replay", Keyword.put(opts, :operation_id, "progress-1"))

    assert {:ok,
            %{
              action: :updated,
              external_comment_id: "fixture-progress-FIX-1"
            }} =
             Tracker.upsert_progress(config, "FIX-1", "running again", Keyword.put(opts, :operation_id, "progress-2"))

    assert {:ok,
            %{
              action: :created,
              external_id: "fixture-final-FIX-1",
              external_comment_id: "fixture-final-FIX-1"
            }} =
             Tracker.append_final_summary(
               config,
               "FIX-1",
               "accepted",
               Keyword.put(opts, :operation_id, "final-1")
             )

    assert Agent.get(fixture_state, & &1) == %{
             {:comment, :final, "FIX-1"} => "accepted",
             {:comment, :progress, "FIX-1"} => "running again",
             {:operation, "final-1"} => %{
               action: :created,
               external_comment_id: "fixture-final-FIX-1",
               external_id: "fixture-final-FIX-1",
               issue_id: "FIX-1",
               marker: "<!-- symphony-tracker:final issue=fixture:FIX-1 -->",
               provider: "fixture"
             },
             {:operation, "progress-1"} => first_progress,
             {:operation, "progress-2"} => %{
               action: :updated,
               external_comment_id: "fixture-progress-FIX-1",
               external_id: "fixture-progress-FIX-1",
               issue_id: "FIX-1",
               marker: "<!-- symphony-tracker:progress issue=fixture:FIX-1 -->",
               provider: "fixture"
             }
           }
  end

  test "fixture webhook distinguishes human terminal changes and delivery artifacts" do
    config = %{provider: "fixture", settings: %{}}

    assert {:ok, %{kind: :human_terminal, issue_id: "FIX-1"}} =
             Tracker.normalize_webhook(config, %{
               body: %{event_id: "terminal-1", issue_id: "FIX-1", state: "cancelled"}
             })

    assert {:ok, %{kind: :delivery_artifact, issue_id: "PR-1"}} =
             Tracker.normalize_webhook(config, %{
               body: %{event_id: "artifact-1", issue_id: "PR-1", kind: "pull_request"}
             })
  end

  test "fixture webhook rejects missing stable identifiers" do
    config = %{provider: "fixture", settings: %{}}

    for body <- [
          %{issue_id: "FIX-1"},
          %{event_id: "event-1"},
          %{event_id: "", issue_id: "FIX-1"},
          %{event_id: "event-1", issue_id: ""}
        ] do
      assert {:error,
              %{
                provider: "fixture",
                code: :invalid_webhook,
                retryable: false
              }} = Tracker.normalize_webhook(config, %{body: body})
    end
  end

  test "GitHub health check brokers the credential and returns only redacted evidence" do
    credential_ref = "00000000-0000-4000-8000-000000000008"
    secret = "github-health-secret"
    Broker.put_secret(credential_ref, secret)

    config = %{
      "provider" => "github",
      "credential_ref" => credential_ref,
      "settings" => %{
        "endpoint" => "https://api.github.test",
        "bot_actor_id" => "42",
        "owner" => "acme",
        "repository" => "symphony"
      }
    }

    handler = fn request ->
      assert request.method == :get
      assert request.headers["authorization"] == "Bearer #{secret}"

      case request.url do
        "https://api.github.test/user" ->
          {:ok, %{status: 200, headers: %{}, body: %{"id" => 42, "login" => "symphony-bot"}}}

        "https://api.github.test/repos/acme/symphony" ->
          {:ok,
           %{
             status: 200,
             headers: %{},
             body: %{
               "full_name" => "acme/symphony",
               "permissions" => %{"push" => true}
             }
           }}

        "https://api.github.test/repos/acme/symphony/issues" ->
          assert request.params == [state: "all", per_page: 2]
          {:ok, %{status: 200, headers: %{}, body: []}}
      end
    end

    assert {:ok,
            %{
              provider: "github",
              status: :healthy,
              evidence: %{
                http_status: 200,
                credentials: :verified,
                scope: :verified,
                issue_read: :verified,
                state_mappings: :verified,
                comment_permissions: :verified
              }
            } = evidence} =
             Tracker.health_check(
               config,
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )

    assert_receive {:tracker_broker_called, ^credential_ref, :tracker_health_check}
    refute inspect(evidence) =~ secret
    refute inspect(evidence) =~ credential_ref
  end

  test "health_check consumes a runtime-only credential without brokering it again" do
    {base_config, _credential_ref} = github_config()
    runtime_secret = "runtime-only-health-secret"
    webhook_secret = "runtime-only-health-webhook-secret"

    config =
      base_config
      |> Map.put("credential", runtime_secret)
      |> Map.put("webhook_secret", webhook_secret)

    handler = fn request ->
      assert request.headers["authorization"] == "Bearer #{runtime_secret}"

      case request.url do
        "https://api.github.test/user" ->
          {:ok, %{status: 200, headers: %{}, body: %{"id" => 42, "login" => "symphony-bot"}}}

        "https://api.github.test/repos/acme/symphony" ->
          {:ok,
           %{
             status: 200,
             headers: %{},
             body: %{
               "full_name" => "acme/symphony",
               "permissions" => %{"push" => true}
             }
           }}

        "https://api.github.test/repos/acme/symphony/issues" ->
          {:ok, %{status: 200, headers: %{}, body: []}}
      end
    end

    assert {:ok, evidence} =
             Tracker.health_check(
               config,
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )

    refute_receive {:tracker_broker_called, _, :tracker_health_check}
    refute inspect(evidence) =~ runtime_secret
    refute inspect(evidence) =~ webhook_secret
  end

  test "all provider health checks normalize rate limits without echoing response secrets" do
    Enum.each(provider_health_configs(), fn {provider, config, credential_ref} ->
      secret = "#{provider}-rate-limit-secret"
      Broker.put_secret(credential_ref, secret)

      handler = fn _request ->
        {:ok,
         %{
           status: 429,
           headers: %{"retry-after" => "7"},
           body: %{"error" => "provider echoed #{secret}"}
         }}
      end

      assert {:error,
              %{
                provider: ^provider,
                code: :rate_limited,
                retryable: true,
                retry_after_ms: 7_000
              } = error} =
               Tracker.health_check(
                 config,
                 provider_opts(
                   provider,
                   credential_broker: Broker,
                   transport: {Transport, handler: handler}
                 )
               )

      refute inspect(error) =~ secret
      refute inspect(error) =~ credential_ref
    end)
  end

  test "all provider health checks reject malformed success payloads with one safe error" do
    Enum.each(provider_health_configs(), fn {provider, config, credential_ref} ->
      secret = "#{provider}-malformed-secret"
      Broker.put_secret(credential_ref, secret)
      handler = fn _request -> {:ok, %{status: 200, headers: %{}, body: %{"echo" => secret}}} end

      assert {:error, %{provider: ^provider, code: :invalid_response, retryable: false} = error} =
               Tracker.health_check(
                 config,
                 provider_opts(
                   provider,
                   credential_broker: Broker,
                   transport: {Transport, handler: handler}
                 )
               )

      refute inspect(error) =~ secret
    end)
  end

  test "health_check rejects prefixed references before outbound work" do
    {base_config, _credential_ref} = github_config()

    invalid_config =
      Map.put(base_config, "credential_ref", "secret:00000000-0000-4000-8000-000000000108")

    handler = fn _request -> flunk("invalid tracker config must not reach transport") end

    assert {:error, %{provider: "github", code: :invalid_config} = error} =
             Tracker.health_check(
               invalid_config,
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )

    assert error.message == "tracker integration configuration is invalid"
    refute_receive {:tracker_broker_called, _, _}
  end

  test "health_check rejects untrusted and unsafe endpoints with a valid credential reference" do
    {base_config, credential_ref} = github_config()
    Broker.put_secret(credential_ref, "must-not-leave-the-broker")
    handler = fn _request -> flunk("unsafe tracker config must not reach transport") end

    cases = [
      {"http://api.github.test", ["http://api.github.test"], fn _ -> {:ok, [{93, 184, 216, 34}]} end},
      {"https://user:secret@api.github.test", ["https://api.github.test"],
       fn _ ->
         {:ok, [{93, 184, 216, 34}]}
       end},
      {"https://api.github.test?token=secret", ["https://api.github.test"],
       fn _ ->
         {:ok, [{93, 184, 216, 34}]}
       end},
      {"https://127.0.0.1", ["https://127.0.0.1"], fn _ -> {:ok, [{127, 0, 0, 1}]} end},
      {"https://private.example.com", ["https://private.example.com"],
       fn _ ->
         {:ok, [{10, 0, 0, 1}]}
       end},
      {"https://metadata.example.com", ["https://metadata.example.com"],
       fn _ ->
         {:ok, [{169, 254, 169, 254}]}
       end},
      {"https://attacker.example.com", ["https://api.github.com"],
       fn _ ->
         flunk("untrusted origin must be rejected before DNS")
       end}
    ]

    Enum.each(cases, fn {endpoint, trusted_origins, resolver} ->
      config = put_in(base_config, ["settings", "endpoint"], endpoint)

      assert {:error, %{provider: "github", code: :invalid_config, retryable: false}} =
               Tracker.health_check(config,
                 credential_broker: Broker,
                 transport: {Transport, handler: handler},
                 endpoint_trusted_origins: trusted_origins,
                 endpoint_resolver: resolver
               )

      refute_receive {:tracker_broker_called, ^credential_ref, _purpose}
    end)
  end

  test "GitHub fetch_eligible paginates issues and excludes pull requests" do
    {config, credential_ref} = github_config()
    Broker.put_secret(credential_ref, "github-fetch-secret")

    handler = fn request ->
      assert request.url == "https://api.github.test/repos/acme/symphony/issues"

      case Keyword.fetch!(request.params, :page) do
        1 ->
          {:ok,
           %{
             status: 200,
             headers: %{
               "link" => "<https://api.github.test/repos/acme/symphony/issues?page=2&per_page=100>; rel=\"next\""
             },
             body: [
               github_issue(1, "First issue"),
               github_issue(2, "Delivery artifact") |> Map.put("pull_request", %{"url" => "pr"})
             ]
           }}

        2 ->
          {:ok, %{status: 200, headers: %{}, body: [github_issue(3, "Second issue")]}}
      end
    end

    assert {:ok,
            [
              %SymphonyElixir.Tracker.Issue{id: "1", identifier: "#1"},
              %SymphonyElixir.Tracker.Issue{id: "3", identifier: "#3"}
            ]} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "GitHub fetch_eligible rejects a repeated pagination cursor" do
    {config, credential_ref} = github_config()
    Broker.put_secret(credential_ref, "github-loop-secret")
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    handler = fn _request ->
      call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

      if call > 1 do
        flunk("repeated page must be rejected before a second outbound request")
      end

      {:ok,
       %{
         status: 200,
         headers: %{
           "link" => "<https://api.github.test/repos/acme/symphony/issues?page=1>; rel=\"next\""
         },
         body: []
       }}
    end

    assert {:error, %{code: :pagination_limit, retryable: false}} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler},
                 max_pages: 2
               )
             )
  end

  test "GitHub fetch_by_ids preserves requested order and never returns a pull request" do
    {config, credential_ref} = github_config()
    Broker.put_secret(credential_ref, "github-by-id-secret")

    handler = fn request ->
      case request.url do
        "https://api.github.test/repos/acme/symphony/issues/3" ->
          {:ok, %{status: 200, headers: %{}, body: github_issue(3, "Third")}}

        "https://api.github.test/repos/acme/symphony/issues/2" ->
          {:ok,
           %{
             status: 200,
             headers: %{},
             body: github_issue(2, "PR") |> Map.put("pull_request", %{"url" => "pr"})
           }}
      end
    end

    assert {:ok, [%SymphonyElixir.Tracker.Issue{identifier: "#3"}]} =
             Tracker.fetch_by_ids(
               config,
               ["3", "2"],
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "GitHub normalize_webhook verifies HMAC before returning a reconciliation signal" do
    {base_config, _credential_ref} = github_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000009"
    config = put_in(base_config, ["settings", "webhook_secret_ref"], webhook_secret_ref)
    secret = "github-webhook-secret"
    Broker.put_secret(webhook_secret_ref, secret)

    body = Jason.encode!(%{"action" => "edited", "issue" => github_issue(1, "Changed")})
    signature = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))

    request = %{
      "headers" => %{
        "x-github-event" => "issues",
        "x-github-delivery" => "delivery-1",
        "x-hub-signature-256" => signature
      },
      "body" => body
    }

    assert {:ok,
            %{
              provider: "github",
              kind: :issue,
              action: "edited",
              issue_id: "1",
              delivery_id: "delivery-1",
              reconciliation_key: reconciliation_key
            }} =
             Tracker.normalize_webhook(
               config,
               request,
               github_opts(credential_broker: Broker)
             )

    assert "github:sha256:" <> digest = reconciliation_key
    assert byte_size(digest) == 64

    assert {:error, %{code: :invalid_signature, retryable: false} = error} =
             Tracker.normalize_webhook(
               config,
               put_in(request, ["headers", "x-hub-signature-256"], "sha256=bad"),
               github_opts(credential_broker: Broker)
             )

    refute inspect(error) =~ secret
  end

  test "GitHub transition_issue maps the normalized target state" do
    {config, credential_ref} = github_config()
    Broker.put_secret(credential_ref, "github-transition-secret")

    handler = fn request ->
      assert request.method == :patch
      assert request.url == "https://api.github.test/repos/acme/symphony/issues/1"
      assert request.body == %{state: "closed"}
      {:ok, %{status: 200, headers: %{}, body: github_issue(1, "Closed") |> Map.put("state", "closed")}}
    end

    assert {:ok, %{provider: "github", issue_id: "1", state: "closed"}} =
             Tracker.transition_issue(
               config,
               "1",
               :closed,
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "GitHub upsert_progress creates once and then updates the stable marker comment" do
    {config, credential_ref} = github_config()
    Broker.put_secret(credential_ref, "github-progress-secret")

    forged = %{
      "id" => 54,
      "body" => "<!-- symphony-tracker:progress issue=github:1 -->\nforged",
      "user" => %{"id" => 7}
    }

    {:ok, state} = Agent.start_link(fn -> %{comments: [forged], creates: 0} end)

    handler = fn request ->
      Agent.get_and_update(state, fn current ->
        case {request.method, request.url} do
          {:get, "https://api.github.test/repos/acme/symphony/issues/1/comments"} ->
            case Keyword.fetch!(request.params, :page) do
              1 ->
                headers = %{
                  "link" => "<https://api.github.test/repos/acme/symphony/issues/1/comments?page=2>; rel=\"next\""
                }

                comments = Enum.filter(current.comments, &(&1["id"] == 54))
                {{:ok, %{status: 200, headers: headers, body: comments}}, current}

              2 ->
                comments = Enum.reject(current.comments, &(&1["id"] == 54))
                {{:ok, %{status: 200, headers: %{}, body: comments}}, current}
            end

          {:post, "https://api.github.test/repos/acme/symphony/issues/1/comments"} ->
            assert current.creates == 0
            assert request.body.body =~ "<!-- symphony-tracker:progress issue=github:1 -->"
            comment = %{"id" => 55, "body" => request.body.body, "user" => %{"id" => 42}}

            next = %{current | comments: current.comments ++ [comment], creates: 1}
            {{:ok, %{status: 201, headers: %{}, body: comment}}, next}

          {:patch, "https://api.github.test/repos/acme/symphony/issues/comments/55"} ->
            assert request.body.body =~ "plan revision 2"
            comment = %{"id" => 55, "body" => request.body.body, "user" => %{"id" => 42}}

            comments =
              Enum.map(current.comments, fn existing ->
                if existing["id"] == 55, do: comment, else: existing
              end)

            {{:ok, %{status: 200, headers: %{}, body: comment}}, %{current | comments: comments}}
        end
      end)
    end

    opts = github_opts(credential_broker: Broker, transport: {Transport, handler: handler})

    assert {:ok, %{action: :created, external_id: "55"}} =
             Tracker.upsert_progress(config, "1", "plan revision 1", opts)

    assert {:ok, %{action: :updated, external_id: "55"}} =
             Tracker.upsert_progress(config, "1", "plan revision 2", opts)

    assert Agent.get(state, & &1.creates) == 1
  end

  test "GitHub append_final_summary reuses the independent final marker" do
    {config, credential_ref} = github_config()
    Broker.put_secret(credential_ref, "github-final-secret")
    marker = "<!-- symphony-tracker:final issue=github:1 -->"

    handler = fn request ->
      case request.method do
        :get ->
          {:ok,
           %{
             status: 200,
             headers: %{},
             body: [%{"id" => 77, "body" => marker <> "\nold", "user" => %{"id" => 42}}]
           }}

        :patch ->
          assert request.url == "https://api.github.test/repos/acme/symphony/issues/comments/77"
          assert request.body.body == marker <> "\naccepted"
          {:ok, %{status: 200, headers: %{}, body: %{"id" => 77}}}
      end
    end

    assert {:ok, %{action: :updated, external_id: "77", marker: ^marker}} =
             Tracker.append_final_summary(
               config,
               "1",
               "accepted",
               github_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  defp github_config do
    credential_ref = "00000000-0000-4000-8000-000000000008"

    {%{
       "provider" => "github",
       "credential_ref" => credential_ref,
       "settings" => %{
         "endpoint" => "https://api.github.test",
         "bot_actor_id" => "42",
         "owner" => "acme",
         "repository" => "symphony"
       }
     }, credential_ref}
  end

  defp github_issue(number, title) do
    %{
      "id" => 1000 + number,
      "number" => number,
      "title" => title,
      "body" => "Issue body",
      "state" => "open",
      "labels" => [%{"name" => "ready-for-agent"}],
      "assignee" => %{"id" => 42, "login" => "worker"},
      "html_url" => "https://github.test/acme/symphony/issues/#{number}",
      "created_at" => "2026-07-20T00:00:00Z",
      "updated_at" => "2026-07-20T00:01:00Z"
    }
  end

  defp github_opts(opts), do: endpoint_opts("https://api.github.test", opts)

  defp provider_opts("github", opts), do: endpoint_opts("https://github.test", opts)
  defp provider_opts("gitlab", opts), do: endpoint_opts("https://gitlab.test", opts)
  defp provider_opts("linear", opts), do: endpoint_opts("https://linear.test", opts)

  defp endpoint_opts(origin, opts) do
    Keyword.merge(
      [
        endpoint_trusted_origins: [origin],
        endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
      ],
      opts
    )
  end

  defp provider_health_configs do
    [
      {"github",
       %{
         provider: "github",
         credential_ref: "00000000-0000-4000-8000-000000000108",
         settings: %{endpoint: "https://github.test", owner: "acme", repository: "symphony"}
       }, "00000000-0000-4000-8000-000000000108"},
      {"linear",
       %{
         provider: "linear",
         credential_ref: "00000000-0000-4000-8000-000000000118",
         settings: %{endpoint: "https://linear.test/graphql", project_slug: "ENG"}
       }, "00000000-0000-4000-8000-000000000118"},
      {"gitlab",
       %{
         provider: "gitlab",
         credential_ref: "00000000-0000-4000-8000-000000000128",
         settings: %{endpoint: "https://gitlab.test/api/v4", project_id: "acme/symphony"}
       }, "00000000-0000-4000-8000-000000000128"}
    ]
  end
end

defmodule SymphonyElixir.TrackerEndpointDefaultsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport
  alias SymphonyElixir.TrackerContract.Broker

  setup do
    previous = Application.get_env(:symphony_elixir, :tracker_trusted_origins)
    Application.delete_env(:symphony_elixir, :tracker_trusted_origins)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :tracker_trusted_origins)
      else
        Application.put_env(:symphony_elixir, :tracker_trusted_origins, previous)
      end
    end)

    :ok
  end

  test "official provider endpoints are trusted when configuration omits an override" do
    Enum.each(default_provider_configs(), fn {provider, config, credential_ref} ->
      Broker.put_secret(credential_ref, "#{provider}-default-endpoint-secret")

      handler = fn _request ->
        {:ok, %{status: 503, headers: %{}, body: %{}}}
      end

      assert {:error, %{provider: ^provider, code: :provider_unavailable, retryable: true}} =
               Tracker.health_check(config,
                 credential_broker: Broker,
                 endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
                 transport: {Transport, handler: handler}
               )
    end)
  end

  test "invalid operator trust configuration falls back to official origins" do
    Application.put_env(:symphony_elixir, :tracker_trusted_origins, :invalid)
    {"github", config, credential_ref} = hd(default_provider_configs())
    Broker.put_secret(credential_ref, "github-invalid-trust-config-secret")

    assert {:error, %{provider: "github", code: :provider_unavailable}} =
             Tracker.health_check(config,
               credential_broker: Broker,
               endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
               transport:
                 {Transport,
                  handler: fn _request ->
                    {:ok, %{status: 503, headers: %{}, body: %{}}}
                  end}
             )
  end

  test "public IP endpoint validation does not require a DNS resolver" do
    {"github", base_config, credential_ref} = hd(default_provider_configs())
    config = put_in(base_config, [:settings, :endpoint], "https://93.184.216.34")
    Broker.put_secret(credential_ref, "github-pinned-ip-secret")

    assert {:error, %{provider: "github", code: :provider_unavailable}} =
             Tracker.health_check(config,
               credential_broker: Broker,
               endpoint_trusted_origins: ["https://93.184.216.34"],
               transport:
                 {Transport,
                  handler: fn _request ->
                    {:ok, %{status: 503, headers: %{}, body: %{}}}
                  end}
             )
  end

  test "facade forwards a dual-family resolver before brokered transport" do
    {"github", base_config, credential_ref} = hd(default_provider_configs())
    config = put_in(base_config, [:settings, :endpoint], "https://tracker.example.com")
    Broker.put_secret(credential_ref, "github-dual-family-resolver-secret")
    test_pid = self()

    resolver = fn host, family ->
      send(test_pid, {:tracker_resolved, host, family})

      case family do
        :inet -> {:ok, [{93, 184, 216, 34}]}
        :inet6 -> {:error, :nxdomain}
      end
    end

    handler = fn request ->
      send(test_pid, {:tracker_transport_reached, request.url})
      {:ok, %{status: 503, headers: %{}, body: %{}}}
    end

    assert {:error, %{provider: "github", code: :provider_unavailable}} =
             Tracker.health_check(config,
               credential_broker: Broker,
               endpoint_trusted_origins: ["https://tracker.example.com"],
               endpoint_resolver: resolver,
               transport: {Transport, handler: handler}
             )

    assert_receive {:tracker_resolved, ~c"tracker.example.com", :inet}
    assert_receive {:tracker_resolved, ~c"tracker.example.com", :inet6}
    assert_receive {:tracker_transport_reached, "https://tracker.example.com/user"}
  end

  test "dashboard-shaped config cannot inject trust, policy, or request functions" do
    {"github", base_config, credential_ref} = hd(default_provider_configs())

    config =
      base_config
      |> put_in([:settings, :endpoint], "https://attacker.example.com")
      |> Map.put(:endpoint_trusted_origins, ["https://attacker.example.com"])
      |> Map.put(:endpoint_resolver, "attacker-controlled")
      |> Map.put(:endpoint_policy, %{"host" => "attacker.example.com"})
      |> Map.put(:request_fun, "attacker-controlled")

    handler = fn _request -> flunk("untrusted config must not reach transport") end

    assert {:error, %{provider: "github", code: :invalid_config}} =
             Tracker.health_check(config,
               credential_broker: Broker,
               transport: {Transport, handler: handler}
             )

    refute_receive {:tracker_broker_called, ^credential_ref, _purpose}
  end

  defp default_provider_configs do
    [
      {"github",
       %{
         provider: "github",
         credential_ref: "00000000-0000-4000-8000-000000000208",
         settings: %{bot_actor_id: "42", owner: "acme", repository: "symphony"}
       }, "00000000-0000-4000-8000-000000000208"},
      {"gitlab",
       %{
         provider: "gitlab",
         credential_ref: "00000000-0000-4000-8000-000000000218",
         settings: %{bot_actor_id: "42", project_id: "acme/symphony"}
       }, "00000000-0000-4000-8000-000000000218"},
      {"linear",
       %{
         provider: "linear",
         credential_ref: "00000000-0000-4000-8000-000000000228",
         settings: %{
           bot_actor_id: "actor-42",
           project_slug: "ENG",
           state_ids: %{open: "state-open", closed: "state-closed"}
         }
       }, "00000000-0000-4000-8000-000000000228"}
    ]
  end
end

defmodule SymphonyElixir.TrackerFixtureSharedContractTest do
  use SymphonyElixir.TrackerContract,
    provider: "fixture",
    adapter: SymphonyElixir.Tracker.Adapters.Fixture,
    async: true

  defp tracker_contract_case(:health_check) do
    %{
      config: %{provider: "fixture", settings: %{scenario: "healthy"}},
      opts: []
    }
  end

  defp tracker_contract_case(:fetch_eligible) do
    %{
      config: %{
        provider: "fixture",
        settings: %{
          issues: [
            %{
              id: "FIX-1",
              identifier: "FIX-1",
              title: "Ready",
              state: "open",
              labels: ["ready-for-agent"],
              dispatchable: true
            }
          ]
        }
      },
      criteria: %{states: ["open"], required_labels: ["ready-for-agent"]},
      expected_ids: ["FIX-1"],
      opts: []
    }
  end

  defp tracker_contract_case(:fetch_by_ids) do
    %{
      config: %{
        provider: "fixture",
        settings: %{
          issues: [
            %{id: "FIX-1", identifier: "FIX-1", title: "First", state: "open"},
            %{id: "FIX-2", identifier: "FIX-2", title: "Second", state: "open"}
          ]
        }
      },
      issue_ids: ["FIX-2", "missing", "FIX-1"],
      expected_ids: ["FIX-2", "FIX-1"],
      opts: []
    }
  end

  defp tracker_contract_case(:normalize_webhook) do
    %{
      config: %{provider: "fixture", settings: %{}},
      request: %{
        body: %{
          event_id: "terminal-1",
          issue_id: "FIX-1",
          action: "closed",
          state: "closed"
        }
      },
      expected_issue_id: "FIX-1",
      opts: []
    }
  end

  defp tracker_contract_case(:transition_issue) do
    %{
      config: %{provider: "fixture", settings: %{}},
      issue_id: "FIX-1",
      target_state: :closed,
      expected_state: "closed",
      opts: []
    }
  end

  defp tracker_contract_case(operation)
       when operation in [:upsert_progress, :append_final_summary] do
    {:ok, state} = Agent.start_link(fn -> %{} end)

    %{
      config: %{provider: "fixture", settings: %{}},
      issue_id: "FIX-1",
      first_text: "version 1",
      second_text: "version 2",
      opts: [fixture_state: state]
    }
  end
end

defmodule SymphonyElixir.TrackerLegacyCompatibilityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Memory

  setup do
    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous)
      end
    end)

    :ok
  end

  test "legacy Memory and Linear adapter registrations and read callbacks remain intact" do
    open = %Issue{id: "MEM-1", identifier: "MEM-1", title: "Open", state: "Open"}
    closed = %Issue{id: "MEM-2", identifier: "MEM-2", title: "Closed", state: "Closed"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [open, closed, :invalid])

    assert {:ok, [^open]} = Memory.fetch_issues_by_states([" open "])
    assert {:ok, [^closed]} = Memory.fetch_issues_by_ids(["MEM-2"])

    assert {:ok, Memory} = Tracker.adapter_for_kind("memory")
    assert {:ok, SymphonyElixir.Linear.Adapter} = Tracker.adapter_for_kind("linear")

    for adapter <- [Memory, SymphonyElixir.Linear.Adapter],
        {callback, arity} <- [fetch_issues_by_states: 1, fetch_issues_by_ids: 1] do
      assert Code.ensure_loaded?(adapter)
      assert function_exported?(adapter, callback, arity)
    end
  end
end
