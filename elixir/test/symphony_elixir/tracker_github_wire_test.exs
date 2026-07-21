defmodule SymphonyElixir.TrackerGitHubWireTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.Adapters.GitHub
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport

  test "health check proves scope read state mapping comment permission and bot identity without mutation" do
    test_pid = self()

    responses = %{
      "https://api.github.test/user" => fixture("health_user.json"),
      "https://api.github.test/repos/acme/symphony" => fixture("health_repository.json"),
      "https://api.github.test/repos/acme/symphony/issues" => fixture("health_issues.json")
    }

    handler = fn request ->
      assert request.method == :get
      refute Map.has_key?(request, :body)
      send(test_pid, {:health_request, request})
      {:ok, %{status: 200, headers: %{}, body: Map.fetch!(responses, request.url)}}
    end

    assert {:ok,
            %{
              provider: "github",
              status: :healthy,
              evidence: %{
                http_status: 200,
                credentials: :verified,
                scope: :verified,
                configured_scope: "acme/symphony",
                bot_actor_id: "42",
                issue_read: :verified,
                state_mappings: :verified,
                comment_permissions: :verified
              }
            }} = GitHub.health_check(github_config(), github_transport_opts(handler))

    assert_receive {:health_request, %{url: "https://api.github.test/user"}}
    assert_receive {:health_request, %{url: "https://api.github.test/repos/acme/symphony"}}

    assert_receive {:health_request,
                    %{
                      url: "https://api.github.test/repos/acme/symphony/issues",
                      params: [state: "all", per_page: 2]
                    }}

    refute_receive {:health_request, _request}
  end

  test "health check rejects malformed successful issue samples" do
    responses = %{
      "https://api.github.test/user" => fixture("health_user.json"),
      "https://api.github.test/repos/acme/symphony" => fixture("health_repository.json"),
      "https://api.github.test/repos/acme/symphony/issues" => [fixture("malformed_issue.json")]
    }

    handler = fn request ->
      {:ok, %{status: 200, headers: %{}, body: Map.fetch!(responses, request.url)}}
    end

    assert {:error, %{provider: "github", code: :invalid_response, retryable: false}} =
             GitHub.health_check(github_config(), github_transport_opts(handler))
  end

  test "health check rejects a credential for a different bot identity" do
    handler = fn request ->
      assert request.url == "https://api.github.test/user"
      {:ok, %{status: 200, headers: %{}, body: fixture("health_user_wrong_bot.json")}}
    end

    assert {:error, %{provider: "github", code: :identity_mismatch, retryable: false}} =
             GitHub.health_check(github_config(), github_transport_opts(handler))
  end

  test "health check rejects repository access without comment permission" do
    responses = %{
      "https://api.github.test/user" => fixture("health_user.json"),
      "https://api.github.test/repos/acme/symphony" => fixture("health_repository_read_only.json")
    }

    handler = fn request ->
      {:ok, %{status: 200, headers: %{}, body: Map.fetch!(responses, request.url)}}
    end

    assert {:error, %{provider: "github", code: :forbidden, retryable: false}} =
             GitHub.health_check(github_config(), github_transport_opts(handler))
  end

  test "REST issue number remains the downstream operation identity" do
    open_issue = fixture("issue_open.json")
    closed_issue = fixture("issue_closed.json")
    created_comment = fixture("comment_created.json")
    final_comment = fixture("final_comment_created.json")

    handler = fn request ->
      case {request.method, request.url} do
        {:get, "https://api.github.test/repos/acme/symphony/issues"} ->
          {:ok, %{status: 200, headers: %{}, body: [open_issue]}}

        {:patch, "https://api.github.test/repos/acme/symphony/issues/17"} ->
          {:ok, %{status: 200, headers: %{}, body: closed_issue}}

        {:get, "https://api.github.test/repos/acme/symphony/issues/17"} ->
          {:ok, %{status: 200, headers: %{}, body: open_issue}}

        {:get, "https://api.github.test/repos/acme/symphony/issues/17/comments"} ->
          {:ok, %{status: 200, headers: %{}, body: []}}

        {:post, "https://api.github.test/repos/acme/symphony/issues/17/comments"} ->
          body =
            if String.starts_with?(request.body.body, "<!-- symphony-tracker:final") do
              final_comment
            else
              created_comment
            end

          {:ok, %{status: 201, headers: %{}, body: body}}

        other ->
          flunk("unexpected GitHub request: #{inspect(other)}")
      end
    end

    opts = github_transport_opts(handler)

    assert {:ok, [%Issue{id: "17", native_ref: %{provider: "github", number: 17}} = issue]} =
             GitHub.fetch_eligible(
               github_config(),
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               opts
             )

    assert {:ok, [%Issue{id: "17"}]} =
             GitHub.fetch_by_ids(github_config(), [issue.id], opts)

    assert {:ok, %{issue_id: "17", state: "closed"}} =
             GitHub.transition_issue(github_config(), issue.id, :closed, opts)

    assert {:ok, %{issue_id: "17", external_id: "7001"}} =
             GitHub.upsert_progress(github_config(), issue.id, "running", opts)

    assert {:ok, %{issue_id: "17", external_id: "7002"}} =
             GitHub.append_final_summary(github_config(), issue.id, "accepted", opts)
  end

  test "mixed open and closed criteria request all provider states" do
    open_issue = fixture("issue_open.json")
    closed_issue = fixture("issue_closed.json")

    handler = fn request ->
      assert request.method == :get
      assert request.url == "https://api.github.test/repos/acme/symphony/issues"
      assert Keyword.fetch!(request.params, :state) == "all"
      {:ok, %{status: 200, headers: %{}, body: [open_issue, closed_issue]}}
    end

    assert {:ok, [%Issue{id: "17", state: "open"}]} =
             GitHub.fetch_eligible(
               github_config(),
               %{"states" => ["closed", "open"], "required_labels" => ["ready-for-agent"]},
               github_transport_opts(handler)
             )
  end

  test "malformed successful issue lists return invalid_response" do
    malformed_issue = fixture("malformed_issue.json")
    handler = fn _request -> {:ok, %{status: 200, headers: %{}, body: [malformed_issue]}} end

    assert {:error,
            %{
              provider: "github",
              code: :invalid_response,
              retryable: false,
              message: "tracker provider returned an invalid response"
            }} =
             GitHub.fetch_eligible(
               github_config(),
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               github_transport_opts(handler)
             )
  end

  test "malformed successful issue lookup returns invalid_response" do
    malformed_issue = fixture("malformed_issue.json")
    handler = fn _request -> {:ok, %{status: 200, headers: %{}, body: malformed_issue}} end

    assert {:error, %{provider: "github", code: :invalid_response, retryable: false}} =
             GitHub.fetch_by_ids(github_config(), ["99"], github_transport_opts(handler))
  end

  test "issue lookup rejects a successful response for a different REST number" do
    handler = fn _request ->
      {:ok, %{status: 200, headers: %{}, body: fixture("issue_open.json")}}
    end

    assert {:error, %{provider: "github", code: :invalid_response, retryable: false}} =
             GitHub.fetch_by_ids(github_config(), ["99"], github_transport_opts(handler))
  end

  test "malformed successful comment lists stop before mutation" do
    malformed_comment = fixture("malformed_comment.json")

    handler = fn request ->
      case request.method do
        :get -> {:ok, %{status: 200, headers: %{}, body: [malformed_comment]}}
        mutation -> flunk("malformed comments must stop before #{mutation}")
      end
    end

    assert {:error, %{provider: "github", code: :invalid_response, retryable: false}} =
             GitHub.upsert_progress(
               github_config(),
               "17",
               "running",
               github_transport_opts(handler)
             )
  end

  test "malformed successful issue transitions return invalid_response" do
    malformed_mutation = fixture("malformed_mutation.json")
    handler = fn _request -> {:ok, %{status: 200, headers: %{}, body: malformed_mutation}} end

    assert {:error, %{provider: "github", code: :invalid_response, retryable: false}} =
             GitHub.transition_issue(
               github_config(),
               "17",
               :closed,
               github_transport_opts(handler)
             )
  end

  test "malformed successful comment mutations return invalid_response" do
    malformed_mutation = fixture("malformed_mutation.json")

    handler = fn request ->
      case request.method do
        :get -> {:ok, %{status: 200, headers: %{}, body: []}}
        :post -> {:ok, %{status: 201, headers: %{}, body: malformed_mutation}}
      end
    end

    assert {:error, %{provider: "github", code: :invalid_response, retryable: false}} =
             GitHub.append_final_summary(
               github_config(),
               "17",
               "accepted",
               github_transport_opts(handler)
             )
  end

  test "marker must be the exact first comment line" do
    quoted_marker = fixture("quoted_marker_comment.json")
    created_comment = fixture("comment_created.json")

    handler = fn request ->
      case request.method do
        :get -> {:ok, %{status: 200, headers: %{}, body: [quoted_marker]}}
        :post -> {:ok, %{status: 201, headers: %{}, body: created_comment}}
        :patch -> flunk("a quoted marker must not select an existing comment")
      end
    end

    assert {:ok, %{action: :created, external_id: "7001"}} =
             GitHub.upsert_progress(
               github_config(),
               "17",
               "running",
               github_transport_opts(handler)
             )
  end

  test "signed webhooks require nonblank delivery and event headers" do
    body = fixture_body("webhook_issue_open.json")
    secret = "github-webhook-secret"

    headers = %{
      "x-github-event" => "issues",
      "x-github-delivery" => "delivery-17",
      "x-hub-signature-256" => github_signature(body, secret)
    }

    invalid_headers = [
      Map.delete(headers, "x-github-delivery"),
      Map.put(headers, "x-github-delivery", "   "),
      Map.delete(headers, "x-github-event"),
      Map.put(headers, "x-github-event", "   ")
    ]

    Enum.each(invalid_headers, fn invalid ->
      assert {:error, %{provider: "github", code: :invalid_webhook, retryable: false}} =
               GitHub.normalize_webhook(
                 github_config(),
                 %{headers: invalid, body: body},
                 webhook_opts(secret)
               )
    end)
  end

  test "signed body digest is stable replay identity across changed delivery headers" do
    body = fixture_body("webhook_issue_open.json")
    secret = "github-webhook-secret"
    signature = github_signature(body, secret)

    request = fn delivery_id ->
      %{
        headers: %{
          "x-github-event" => "issues",
          "x-github-delivery" => delivery_id,
          "x-hub-signature-256" => signature
        },
        body: body
      }
    end

    assert {:ok, first} =
             GitHub.normalize_webhook(
               github_config(),
               request.("delivery-a"),
               webhook_opts(secret)
             )

    assert {:ok, second} =
             GitHub.normalize_webhook(
               github_config(),
               request.("delivery-b"),
               webhook_opts(secret)
             )

    assert first.delivery_id == "delivery-a"
    assert second.delivery_id == "delivery-b"

    assert first.reconciliation_key ==
             "github:sha256:cf3530e38db0553aae839cf23ff09134baa9c682190c908c072d6d09710f5ab0"

    assert second.reconciliation_key == first.reconciliation_key
  end

  test "closed issue webhooks become explicit human-terminal signals" do
    body = fixture_body("webhook_issue_closed.json")
    secret = "github-webhook-secret"

    request = %{
      headers: %{
        "x-github-event" => "issues",
        "x-github-delivery" => "delivery-closed-17",
        "x-hub-signature-256" => github_signature(body, secret)
      },
      body: body
    }

    assert {:ok,
            %{
              provider: "github",
              kind: :human_terminal,
              action: "closed",
              issue_id: "17",
              state: "closed",
              delivery_id: "delivery-closed-17"
            }} = GitHub.normalize_webhook(github_config(), request, webhook_opts(secret))
  end

  test "signed pull request issue webhooks are ignored as change requests" do
    body =
      "issue_open.json"
      |> fixture()
      |> Map.put("pull_request", %{"url" => "https://api.github.test/repos/acme/symphony/pulls/17"})
      |> then(&Jason.encode!(%{"action" => "opened", "issue" => &1}))

    secret = "github-webhook-secret"

    request = %{
      headers: %{
        "x-github-event" => "issues",
        "x-github-delivery" => "delivery-pr-17",
        "x-hub-signature-256" => github_signature(body, secret)
      },
      body: body
    }

    assert {:ok,
            %{
              provider: "github",
              kind: :ignored,
              reason: :change_request,
              delivery_id: "delivery-pr-17"
            }} = GitHub.normalize_webhook(github_config(), request, webhook_opts(secret))
  end

  test "signed issue webhooks require a REST issue number" do
    body = fixture_body("webhook_issue_missing_number.json")
    secret = "github-webhook-secret"

    request = %{
      headers: %{
        "x-github-event" => "issues",
        "x-github-delivery" => "delivery-missing-number",
        "x-hub-signature-256" => github_signature(body, secret)
      },
      body: body
    }

    assert {:error, %{provider: "github", code: :invalid_webhook, retryable: false}} =
             GitHub.normalize_webhook(github_config(), request, webhook_opts(secret))
  end

  test "health check rejects every malformed successful capability response" do
    user = fixture("health_user.json")
    repository = fixture("health_repository.json")
    issues = fixture("health_issues.json")

    body_handler = fn bodies ->
      fn request ->
        {:ok, %{status: 200, headers: %{}, body: Map.fetch!(bodies, request.url)}}
      end
    end

    handlers = [
      fn _request -> {:ok, %{status: 200, headers: %{}}} end,
      body_handler.(%{"https://api.github.test/user" => %{"id" => nil, "login" => ""}}),
      body_handler.(%{
        "https://api.github.test/user" => user,
        "https://api.github.test/repos/acme/symphony" => %{}
      }),
      body_handler.(%{
        "https://api.github.test/user" => user,
        "https://api.github.test/repos/acme/symphony" => Map.delete(repository, "permissions")
      }),
      body_handler.(%{
        "https://api.github.test/user" => user,
        "https://api.github.test/repos/acme/symphony" => repository,
        "https://api.github.test/repos/acme/symphony/issues" => %{"issues" => issues}
      })
    ]

    Enum.each(handlers, fn handler ->
      assert {:error, %{provider: "github", code: :invalid_response, retryable: false}} =
               GitHub.health_check(github_config(), github_transport_opts(handler))
    end)
  end

  test "fetch_by_ids skips not-found items and rejects non-map successes" do
    issue = fixture("issue_open.json")

    handler = fn request ->
      case request.url do
        "https://api.github.test/repos/acme/symphony/issues/404" ->
          {:ok, %{status: 404, headers: %{}, body: %{"message" => "missing"}}}

        "https://api.github.test/repos/acme/symphony/issues/17" ->
          {:ok, %{status: 200, headers: %{}, body: issue}}
      end
    end

    assert {:ok, [%Issue{id: "17"}]} =
             GitHub.fetch_by_ids(
               github_config(),
               ["404", "17"],
               github_transport_opts(handler)
             )

    malformed_handler = fn _request ->
      {:ok, %{status: 200, headers: %{}, body: []}}
    end

    assert {:error, %{code: :invalid_response}} =
             GitHub.fetch_by_ids(
               github_config(),
               ["17"],
               github_transport_opts(malformed_handler)
             )
  end

  test "fetch_eligible covers closed state malformed links and response failures" do
    closed_handler = fn request ->
      assert request.params[:state] == "closed"
      {:ok, %{status: 200, headers: %{}, body: [fixture("issue_closed.json")]}}
    end

    assert {:ok, []} =
             GitHub.fetch_eligible(
               github_config(),
               %{"states" => ["closed"], "required_labels" => ["ready-for-agent"]},
               github_transport_opts(closed_handler)
             )

    malformed_link_handler = fn _request ->
      {:ok,
       %{
         status: 200,
         headers: %{"link" => "<https://api.github.test/issues?page=next>; rel=\"next\""},
         body: [fixture("issue_open.json")]
       }}
    end

    assert {:ok, [%Issue{id: "17"}]} =
             GitHub.fetch_eligible(
               github_config(),
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               github_transport_opts(malformed_link_handler)
             )

    provider_error_handler = fn _request ->
      {:ok, %{status: 503, headers: %{}, body: %{"message" => "unavailable"}}}
    end

    assert {:error, %{code: :provider_unavailable}} =
             GitHub.fetch_eligible(
               github_config(),
               %{"states" => ["open"]},
               github_transport_opts(provider_error_handler)
             )

    for body <- [%{"issues" => []}, [nil]] do
      malformed_handler = fn _request -> {:ok, %{status: 200, headers: %{}, body: body}} end

      assert {:error, %{code: :invalid_response}} =
               GitHub.fetch_eligible(
                 github_config(),
                 %{"states" => ["open"]},
                 github_transport_opts(malformed_handler)
               )
    end
  end

  test "issue normalization accepts documented optional wire variants" do
    issue =
      fixture("issue_open.json")
      |> Map.put("labels", ["ready-for-agent", %{"color" => "red"}])
      |> Map.put("assignee", %{"login" => "worker"})
      |> Map.put("created_at", "not-a-timestamp")
      |> Map.put("updated_at", nil)

    handler = fn _request -> {:ok, %{status: 200, headers: %{}, body: issue}} end

    assert {:ok,
            [
              %Issue{
                id: "17",
                labels: ["ready-for-agent"],
                assignee_id: "worker",
                created_at: nil,
                updated_at: nil
              }
            ]} =
             GitHub.fetch_by_ids(
               github_config(),
               ["17"],
               github_transport_opts(handler)
             )
  end

  test "webhook normalization contains malformed header and body exceptions" do
    assert {:error, %{code: :invalid_webhook}} =
             GitHub.normalize_webhook(
               github_config(),
               %{headers: nil, body: "{}"},
               webhook_opts("github-webhook-secret")
             )

    assert {:error, %{code: :invalid_webhook}} =
             GitHub.normalize_webhook(
               github_config(),
               %{
                 headers: %{
                   "x-github-event" => "issues",
                   "x-github-delivery" => "delivery-invalid-body",
                   "x-hub-signature-256" => "sha256=ignored"
                 },
                 body: :not_binary
               },
               webhook_opts("github-webhook-secret")
             )
  end

  test "transition_issue covers open unsupported provider and malformed responses" do
    open_handler = fn _request ->
      {:ok, %{status: 200, headers: %{}, body: fixture("issue_open.json")}}
    end

    assert {:ok, %{state: "open"}} =
             GitHub.transition_issue(
               github_config(),
               "17",
               :open,
               github_transport_opts(open_handler)
             )

    assert {:error, %{code: :unsupported_transition}} =
             GitHub.transition_issue(
               github_config(),
               "17",
               :archived,
               github_transport_opts(fn _request -> flunk("must not request") end)
             )

    provider_error_handler = fn _request ->
      {:ok, %{status: 422, headers: %{}, body: %{"message" => "invalid"}}}
    end

    assert {:error, %{code: :provider_error}} =
             GitHub.transition_issue(
               github_config(),
               "17",
               :closed,
               github_transport_opts(provider_error_handler)
             )

    malformed_handler = fn _request -> {:ok, %{status: 204, headers: %{}}} end

    assert {:error, %{code: :invalid_response}} =
             GitHub.transition_issue(
               github_config(),
               "17",
               :closed,
               github_transport_opts(malformed_handler)
             )
  end

  test "comment operations normalize list mutation and transport failures" do
    list_provider_error = fn _request ->
      {:ok, %{status: 503, headers: %{}, body: %{"message" => "unavailable"}}}
    end

    assert {:error, %{code: :provider_unavailable}} =
             GitHub.upsert_progress(
               github_config(),
               "17",
               "running",
               github_transport_opts(list_provider_error)
             )

    malformed_list = fn _request ->
      {:ok, %{status: 200, headers: %{}, body: %{"comments" => []}}}
    end

    assert {:error, %{code: :invalid_response}} =
             GitHub.upsert_progress(
               github_config(),
               "17",
               "running",
               github_transport_opts(malformed_list)
             )

    for {mutation_response, expected_code} <- [
          {{:ok, %{status: 422, headers: %{}, body: %{"message" => "invalid"}}}, :provider_error},
          {{:error, :timeout}, :transport_failed}
        ] do
      handler = fn request ->
        if request.method == :get do
          {:ok, %{status: 200, headers: %{}, body: []}}
        else
          mutation_response
        end
      end

      assert {:error, %{code: ^expected_code}} =
               GitHub.append_final_summary(
                 github_config(),
                 "17",
                 "accepted",
                 github_transport_opts(handler)
               )
    end
  end

  test "comment operations reject pagination before a capped GitHub page request" do
    assert {:error, %{code: :pagination_limit, retryable: false}} =
             GitHub.upsert_progress(
               github_config(),
               "17",
               "running",
               github_transport_opts(fn _request -> flunk("pagination cap must stop before transport") end)
               |> Keyword.put(:max_pages, 0)
             )
  end

  test "comment identity accepts strings and missing bot ownership creates a new comment" do
    string_id_handler = fn request ->
      case request.method do
        :get ->
          {:ok, %{status: 200, headers: %{}, body: []}}

        :post ->
          comment = fixture("comment_created.json") |> Map.put("id", "7001")
          {:ok, %{status: 201, headers: %{}, body: comment}}
      end
    end

    assert {:ok, %{external_comment_id: "7001"}} =
             GitHub.upsert_progress(
               github_config(),
               "17",
               "running",
               github_transport_opts(string_id_handler)
             )

    config_without_bot = update_in(github_config(), ["settings"], &Map.delete(&1, "bot_actor_id"))
    existing = fixture("comment_created.json")

    missing_bot_handler = fn request ->
      case request.method do
        :get ->
          {:ok, %{status: 200, headers: %{}, body: [existing]}}

        :post ->
          created = existing |> Map.put("id", 7_003) |> Map.put("body", request.body.body)
          {:ok, %{status: 201, headers: %{}, body: created}}
      end
    end

    assert {:ok, %{action: :created, external_comment_id: "7003"}} =
             GitHub.upsert_progress(
               config_without_bot,
               "17",
               "running",
               github_transport_opts(missing_bot_handler)
             )
  end

  defp github_config do
    %{
      "settings" => %{
        "endpoint" => "https://api.github.test",
        "owner" => "acme",
        "repository" => "symphony",
        "bot_actor_id" => "42"
      }
    }
  end

  defp fixture(name) do
    name
    |> fixture_body()
    |> Jason.decode!()
  end

  defp fixture_body(name) do
    __DIR__
    |> Path.join("../fixtures/trackers/github/#{name}")
    |> File.read!()
  end

  defp github_signature(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  defp webhook_opts(secret) do
    [
      credential: secret,
      endpoint_trusted_origins: ["https://api.github.test"],
      endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
    ]
  end

  defp github_transport_opts(handler) do
    [
      credential: "github-token",
      transport: {Transport, handler: handler},
      endpoint_trusted_origins: ["https://api.github.test"],
      endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
    ]
  end
end

defmodule SymphonyElixir.TrackerGitHubSharedContractTest do
  use SymphonyElixir.TrackerContract,
    provider: "github",
    adapter: SymphonyElixir.Tracker.Adapters.GitHub,
    async: true

  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport
  alias SymphonyElixir.TrackerContract.Broker

  @credential_ref "00000000-0000-4000-8000-000000000208"
  @webhook_secret_ref "00000000-0000-4000-8000-000000000209"
  @credential "github-contract-token"
  @webhook_secret "github-contract-webhook-secret"

  defp tracker_contract_case(:health_check) do
    put_main_credential()

    responses = %{
      "https://api.github.test/user" => fixture("health_user.json"),
      "https://api.github.test/repos/acme/symphony" => fixture("health_repository.json"),
      "https://api.github.test/repos/acme/symphony/issues" => fixture("health_issues.json")
    }

    handler = fn request ->
      assert request.method == :get
      refute Map.has_key?(request, :body)
      {:ok, %{status: 200, headers: %{}, body: Map.fetch!(responses, request.url)}}
    end

    contract(:tracker_health_check, tracker_opts(handler))
  end

  defp tracker_contract_case(:fetch_eligible) do
    put_main_credential()

    handler = fn request ->
      assert request.params[:state] == "open"
      {:ok, %{status: 200, headers: %{}, body: [fixture("issue_open.json")]}}
    end

    contract(:tracker_fetch_eligible, tracker_opts(handler))
    |> Map.merge(%{
      criteria: %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
      expected_ids: ["17"]
    })
  end

  defp tracker_contract_case(:fetch_by_ids) do
    put_main_credential()
    [issue_17, issue_18] = fixture("health_issues.json")

    handler = fn request ->
      body =
        case request.url do
          "https://api.github.test/repos/acme/symphony/issues/18" -> issue_18
          "https://api.github.test/repos/acme/symphony/issues/17" -> issue_17
        end

      {:ok, %{status: 200, headers: %{}, body: body}}
    end

    contract(:tracker_fetch_by_ids, tracker_opts(handler))
    |> Map.merge(%{issue_ids: ["18", "17"], expected_ids: ["18", "17"]})
  end

  defp tracker_contract_case(:normalize_webhook) do
    Broker.put_secret(@webhook_secret_ref, @webhook_secret)
    body = fixture_body("webhook_issue_closed.json")

    request = %{
      headers: %{
        "x-github-event" => "issues",
        "x-github-delivery" => "contract-delivery-17",
        "x-hub-signature-256" => github_signature(body, @webhook_secret)
      },
      body: body
    }

    %{
      config: github_config(),
      opts: tracker_opts(),
      request: request,
      expected_issue_id: "17",
      credential_ref: @webhook_secret_ref,
      credential_purpose: :tracker_normalize_webhook
    }
  end

  defp tracker_contract_case(:transition_issue) do
    put_main_credential()

    handler = fn request ->
      assert request.url == "https://api.github.test/repos/acme/symphony/issues/17"
      {:ok, %{status: 200, headers: %{}, body: fixture("issue_closed.json")}}
    end

    contract(:tracker_transition_issue, tracker_opts(handler))
    |> Map.merge(%{issue_id: "17", target_state: :closed, expected_state: "closed"})
  end

  defp tracker_contract_case(:upsert_progress) do
    comment_contract(:tracker_upsert_progress)
    |> Map.merge(%{
      issue_id: "17",
      first_text: "progress revision 1",
      second_text: "progress revision 2"
    })
  end

  defp tracker_contract_case(:append_final_summary) do
    comment_contract(:tracker_append_final_summary)
    |> Map.merge(%{
      issue_id: "17",
      first_text: "final summary 1",
      second_text: "final summary 2"
    })
  end

  defp comment_contract(purpose) do
    put_main_credential()
    {:ok, comments} = Agent.start_link(fn -> [] end)

    handler = fn request ->
      Agent.get_and_update(comments, &comment_state_transition(&1, request, purpose))
    end

    contract(purpose, tracker_opts(handler))
  end

  defp comment_state_transition(stored, %{method: :get}, _purpose) do
    {{:ok, %{status: 200, headers: %{}, body: stored}}, stored}
  end

  defp comment_state_transition(_stored, %{method: :post} = request, purpose) do
    id = comment_id_for_purpose(purpose)
    comment = github_comment(id, request.body.body)
    {{:ok, %{status: 201, headers: %{}, body: comment}}, [comment]}
  end

  defp comment_state_transition(stored, %{method: :patch} = request, _purpose) do
    [existing] = stored
    comment = github_comment(existing["id"], request.body.body)
    {{:ok, %{status: 200, headers: %{}, body: comment}}, [comment]}
  end

  defp comment_id_for_purpose(:tracker_upsert_progress), do: 7_001
  defp comment_id_for_purpose(_purpose), do: 7_002

  defp contract(purpose, opts) do
    %{
      config: github_config(),
      opts: opts,
      credential_ref: @credential_ref,
      credential_purpose: purpose
    }
  end

  defp github_config do
    %{
      "provider" => "github",
      "credential_ref" => @credential_ref,
      "settings" => %{
        "endpoint" => "https://api.github.test",
        "owner" => "acme",
        "repository" => "symphony",
        "bot_actor_id" => "42",
        "webhook_secret_ref" => @webhook_secret_ref
      }
    }
  end

  defp tracker_opts(handler \\ nil) do
    opts = [
      credential_broker: Broker,
      endpoint_trusted_origins: ["https://api.github.test"],
      endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
    ]

    if handler do
      Keyword.put(opts, :transport, {Transport, handler: handler})
    else
      opts
    end
  end

  defp put_main_credential, do: Broker.put_secret(@credential_ref, @credential)

  defp github_comment(id, body) do
    %{"id" => id, "body" => body, "user" => %{"id" => 42, "login" => "symphony-bot"}}
  end

  defp fixture(name), do: name |> fixture_body() |> Jason.decode!()

  defp fixture_body(name) do
    __DIR__
    |> Path.join("../fixtures/trackers/github/#{name}")
    |> File.read!()
  end

  defp github_signature(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end
end
