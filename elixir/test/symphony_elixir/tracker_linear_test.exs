defmodule SymphonyElixir.TrackerLinearTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Adapters.Linear, as: LinearAdapter
  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport
  alias SymphonyElixir.TrackerContract.Broker

  @fixture_dir Path.expand("../fixtures/trackers/linear", __DIR__)

  test "health check uses the normalized seam and returns redacted Linear evidence" do
    {config, credential_ref} = linear_config()
    secret = "linear-health-secret"
    Broker.put_secret(credential_ref, secret)

    handler = fn request ->
      assert request.method == :post
      assert request.url == "https://linear.test/graphql"
      assert request.headers["authorization"] == secret
      assert request.body.query =~ "viewer"
      assert request.body.query =~ "projects"
      assert request.body.query =~ "workflowStates"
      assert request.body.query =~ "commentCreate"
      assert request.body.query =~ "issues"
      refute request.body.query =~ "mutation"
      assert request.body.variables == %{projectSlug: "ENG"}
      response_fixture("health.json")
    end

    assert {:ok,
            %{
              provider: "linear",
              status: :healthy,
              evidence: %{
                credentials: :verified,
                scope: :verified,
                issue_read: :verified,
                state_mappings: :verified,
                comment_permissions: :verified,
                http_status: 200,
                details: %{
                  tracker_scope: "ENG",
                  bot_actor_id: "linear-bot",
                  state_mapping: %{
                    "started" => %{
                      id: "state-started",
                      name: "Custom building name",
                      type: "started"
                    },
                    "completed" => %{
                      id: "state-completed",
                      name: "Released to customers",
                      type: "completed"
                    },
                    "cancelled" => %{
                      id: "state-cancelled",
                      name: "Will not pursue",
                      type: "canceled"
                    }
                  }
                }
              }
            } = evidence} =
             Tracker.health_check(
               config,
               tracker_opts(transport: {Transport, handler: handler})
             )

    refute inspect(evidence) =~ secret
    refute inspect(evidence) =~ credential_ref
  end

  test "health check rejects scope, identity, state mapping, or comment capability mismatches" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-health-negative-secret")
    healthy_handler = fn _request -> response_fixture("health.json") end

    invalid_configs = [
      put_in(config, [:settings, :project_slug], "OTHER"),
      put_in(config, [:settings, :bot_actor_id], "different-bot"),
      put_in(config, [:settings, :state_ids, "completed"], "missing-state")
    ]

    Enum.each(invalid_configs, fn invalid_config ->
      assert {:error, %{provider: "linear", code: :invalid_response, retryable: false}} =
               Tracker.health_check(
                 invalid_config,
                 tracker_opts(transport: {Transport, handler: healthy_handler})
               )
    end)

    no_comment_handler = fn _request -> response_fixture("health_no_comment_permission.json") end

    assert {:error, %{provider: "linear", code: :forbidden, retryable: false}} =
             Tracker.health_check(
               config,
               tracker_opts(transport: {Transport, handler: no_comment_handler})
             )
  end

  test "fetch_eligible follows Linear cursors and normalizes the full issue" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-fetch-secret")

    handler = fn request ->
      case request.body.variables.after do
        nil ->
          linear_page([linear_issue("issue-1", "ENG-1")], true, "cursor-1")

        "cursor-1" ->
          linear_page([linear_issue("issue-2", "ENG-2")], false, nil)
      end
    end

    assert {:ok,
            [
              %SymphonyElixir.Tracker.Issue{id: "issue-1", identifier: "ENG-1"},
              %SymphonyElixir.Tracker.Issue{id: "issue-2", identifier: "ENG-2"}
            ]} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["In Progress"], "required_labels" => ["ready-for-agent"]},
               tracker_opts(transport: {Transport, handler: handler})
             )
  end

  test "fetch_eligible rejects a Linear pagination cap before transport" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-fetch-pagination-cap-secret")

    assert {:error, %{code: :pagination_limit, retryable: false}} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["In Progress"], "required_labels" => ["ready-for-agent"]},
               tracker_opts(
                 transport: {Transport, handler: fn _request -> flunk("pagination cap must stop before transport") end},
                 max_pages: 0
               )
             )
  end

  test "fetch_by_ids restores Linear results to requested order" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-by-id-secret")

    handler = fn request ->
      assert request.body.variables.ids == ["issue-1", "issue-2"]

      {:ok,
       %{
         status: 200,
         headers: %{},
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 linear_issue("issue-2", "ENG-2"),
                 linear_issue("issue-1", "ENG-1")
               ]
             }
           }
         }
       }}
    end

    assert {:ok,
            [
              %SymphonyElixir.Tracker.Issue{id: "issue-1"},
              %SymphonyElixir.Tracker.Issue{id: "issue-2"}
            ]} =
             Tracker.fetch_by_ids(
               config,
               ["issue-1", "issue-2"],
               tracker_opts(transport: {Transport, handler: handler})
             )
  end

  test "GraphQL RATELIMITED errors normalize retry guidance even on HTTP 400" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-rate-limit-secret")
    handler = fn _request -> response_fixture("graphql_rate_limited.json") end

    assert {:error,
            %{
              provider: "linear",
              code: :rate_limited,
              retryable: true,
              retry_after_ms: 9_000
            } = error} =
             Tracker.fetch_by_ids(
               config,
               ["issue-1"],
               tracker_opts(transport: {Transport, handler: handler})
             )

    refute inspect(error) =~ "fixture-secret"
  end

  test "nonempty GraphQL errors reject partial data" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-partial-error-secret")
    handler = fn _request -> response_fixture("graphql_partial_error.json") end

    assert {:error, %{provider: "linear", code: :provider_error, retryable: false} = error} =
             Tracker.fetch_by_ids(
               config,
               ["issue-1"],
               tracker_opts(transport: {Transport, handler: handler})
             )

    refute inspect(error) =~ "fixture-secret"
  end

  test "stable Linear state types normalize blocker completion and custom terminal names" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-state-type-secret")

    handler = fn request ->
      assert request.body.query =~ "state { name type }"
      response_fixture("issues_state_types.json")
    end

    assert {:ok, [active, terminal]} =
             Tracker.fetch_by_ids(
               config,
               ["issue-1", "issue-2"],
               tracker_opts(transport: {Transport, handler: handler})
             )

    assert active.state == "Custom building name"
    refute active.dispatchable

    assert [completed_blocker, active_blocker] = active.blocked_by

    assert %{
             external_id: "ENG-90",
             completed?: true,
             terminal: true,
             state: "Released to customers"
           } = completed_blocker

    assert %{
             external_id: "ENG-91",
             completed?: false,
             terminal: false,
             state: "Waiting on legal"
           } = active_blocker

    assert terminal.state == "Released to customers"
    refute terminal.dispatchable
  end

  test "truncated Linear blocker connections fail closed" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-truncated-blockers-secret")

    handler = fn request ->
      assert request.body.query =~ "pageInfo { hasNextPage endCursor }"
      response_fixture("issues_truncated_blockers.json")
    end

    assert {:ok, [issue]} =
             Tracker.fetch_by_ids(
               config,
               ["issue-truncated"],
               tracker_opts(transport: {Transport, handler: handler})
             )

    assert [%{external_id: "ENG-92", completed?: true}] = issue.blocked_by
    refute issue.dispatchable
  end

  test "normalize_webhook verifies the independent Linear signing secret" do
    {base_config, _credential_ref} = linear_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000019"
    config = put_in(base_config, [:settings, :webhook_secret_ref], webhook_secret_ref)
    secret = "linear-webhook-secret"
    Broker.put_secret(webhook_secret_ref, secret)

    request = signed_webhook_request("webhook_active.json", secret)

    assert {:ok,
            %{
              provider: "linear",
              kind: :issue,
              action: "update",
              issue_id: "issue-1",
              reconciliation_key: "linear:webhook-active"
            }} =
             Tracker.normalize_webhook(
               config,
               request,
               tracker_opts(clock: fn -> 1_721_430_030_000 end)
             )

    assert {:error, %{code: :invalid_signature, retryable: false}} =
             Tracker.normalize_webhook(
               config,
               put_in(request, [:headers, "linear-signature"], "bad"),
               tracker_opts(clock: fn -> 1_721_430_030_000 end)
             )
  end

  test "normalize_webhook rejects stale and excessively future Linear deliveries" do
    {base_config, _credential_ref} = linear_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000119"
    config = put_in(base_config, [:settings, :webhook_secret_ref], webhook_secret_ref)
    secret = "linear-webhook-freshness-secret"
    Broker.put_secret(webhook_secret_ref, secret)
    request = signed_webhook_request("webhook_active.json", secret)

    assert {:error, %{code: :stale_webhook, retryable: false}} =
             Tracker.normalize_webhook(
               config,
               request,
               tracker_opts(
                 clock: fn -> 1_721_430_060_001 end,
                 webhook_tolerance_ms: 60_000,
                 webhook_future_tolerance_ms: 5_000
               )
             )

    assert {:error, %{code: :stale_webhook, retryable: false}} =
             Tracker.normalize_webhook(
               config,
               request,
               tracker_opts(
                 clock: fn -> 1_721_429_994_999 end,
                 webhook_tolerance_ms: 60_000,
                 webhook_future_tolerance_ms: 5_000
               )
             )
  end

  test "completed and cancelled Linear webhooks become human terminal signals" do
    {base_config, _credential_ref} = linear_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000219"
    config = put_in(base_config, [:settings, :webhook_secret_ref], webhook_secret_ref)
    secret = "linear-webhook-terminal-secret"
    Broker.put_secret(webhook_secret_ref, secret)

    Enum.each(
      [
        {"webhook_completed.json", :completed, "linear:webhook-completed"},
        {"webhook_cancelled.json", :cancelled, "linear:webhook-cancelled"}
      ],
      fn {fixture, terminal_state, reconciliation_key} ->
        assert {:ok,
                %{
                  provider: "linear",
                  kind: :human_terminal,
                  terminal_state: ^terminal_state,
                  issue_id: "issue-1",
                  reconciliation_key: ^reconciliation_key
                }} =
                 Tracker.normalize_webhook(
                   config,
                   signed_webhook_request(fixture, secret),
                   tracker_opts(clock: fn -> 1_721_430_030_000 end)
                 )
      end
    )
  end

  test "transition_issue resolves the configured Linear state id" do
    {base_config, credential_ref} = linear_config()
    config = put_in(base_config, [:settings, :state_ids], %{"completed" => "state-completed"})
    Broker.put_secret(credential_ref, "linear-transition-secret")

    handler = fn request ->
      assert request.body.variables == %{id: "issue-1", stateId: "state-completed"}

      {:ok,
       %{
         status: 200,
         headers: %{},
         body: %{
           "data" => %{
             "issueUpdate" => %{
               "success" => true,
               "issue" => %{"id" => "issue-1", "state" => %{"name" => "Completed"}}
             }
           }
         }
       }}
    end

    assert {:ok, %{provider: "linear", issue_id: "issue-1", state: "completed"}} =
             Tracker.transition_issue(
               config,
               "issue-1",
               :completed,
               tracker_opts(transport: {Transport, handler: handler})
             )
  end

  test "upsert_progress creates the stable Linear progress comment" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-progress-secret")

    handler = fn request ->
      case request.body.operation_name do
        "SymphonyTrackerComments" ->
          response_fixture("comments_progress_forged.json")

        "SymphonyTrackerCommentCreate" ->
          assert request.body.variables.body =~
                   "<!-- symphony-tracker:progress issue=linear:issue-1 -->"

          response_fixture("comment_create.json")
      end
    end

    assert {:ok, %{provider: "linear", action: :created, external_id: "comment-1"}} =
             Tracker.upsert_progress(
               config,
               "issue-1",
               "running",
               tracker_opts(transport: {Transport, handler: handler})
             )
  end

  test "progress marker must be the exact first comment line" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-exact-marker-secret")

    handler = fn request ->
      case request.body.operation_name do
        "SymphonyTrackerComments" -> response_fixture("comments_embedded_marker.json")
        "SymphonyTrackerCommentCreate" -> response_fixture("comment_create.json")
      end
    end

    assert {:ok, %{provider: "linear", action: :created, external_id: "comment-1"}} =
             Tracker.upsert_progress(
               config,
               "issue-1",
               "running",
               tracker_opts(transport: {Transport, handler: handler})
             )
  end

  test "append_final_summary updates the independent Linear final marker" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-final-secret")
    marker = "<!-- symphony-tracker:final issue=linear:issue-1 -->"

    handler = fn request ->
      case request.body.operation_name do
        "SymphonyTrackerComments" ->
          case Map.get(request.body.variables, :after) do
            nil -> response_fixture("comments_final_page_1.json")
            "comments-2" -> response_fixture("comments_final_page_2.json")
          end

        "SymphonyTrackerCommentUpdate" ->
          assert request.body.variables.body == marker <> "\naccepted"

          response_fixture("comment_update.json")
      end
    end

    assert {:ok, %{provider: "linear", action: :updated, external_id: "comment-final"}} =
             Tracker.append_final_summary(
               config,
               "issue-1",
               "accepted",
               tracker_opts(transport: {Transport, handler: handler})
             )
  end

  test "health check rejects malformed read evidence and accepts every supported response key shape" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-health-coverage-secret")

    assert {:ok, %{status: :healthy}} =
             health_with_response(
               config,
               response_fixture("health.json", fn response ->
                 put_in(
                   response,
                   [:body, "data", "issues", "nodes", Access.at(0), "comments", "nodes"],
                   [%{"id" => "comment-read"}]
                 )
               end)
             )

    custom_mapping_config = put_in(config, [:settings, :state_ids, "qa"], "state-started")

    assert {:ok, %{evidence: %{details: %{state_mapping: %{"qa" => %{type: "started"}}}}}} =
             health_with_response(custom_mapping_config, response_fixture("health.json"))

    assert {:ok, %{status: :healthy}} =
             health_with_response(
               config,
               response_fixture("health.json", fn response ->
                 put_in(
                   response,
                   [:body, "data", "commentCreateCapability", "fields"],
                   [%{name: "commentCreate"}]
                 )
               end)
             )

    malformed_responses = [
      response_fixture("health.json", fn response ->
        put_in(response, [:body, "data", "issues", "nodes"], :not_a_list)
      end),
      response_fixture("health.json", fn response ->
        put_in(
          response,
          [:body, "data", "issues", "nodes", Access.at(0), "comments", "nodes"],
          [%{}]
        )
      end),
      response_fixture("health.json", fn response ->
        put_in(response, [:body, "data", "issues", "nodes"], [%{}])
      end),
      response_fixture("health.json", fn response ->
        put_in(response, [:body, "data", "workflowStates", "nodes"], [:invalid_state])
      end)
    ]

    Enum.each(malformed_responses, fn response ->
      assert {:error, %{code: :invalid_response}} = health_with_response(config, response)
    end)

    assert {:error, %{code: :invalid_response}} =
             config
             |> put_in([:settings, :state_ids], %{})
             |> health_with_response(response_fixture("health.json"))
  end

  test "optional Linear issue fields fail closed without breaking normalized reads" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-optional-fields-secret")
    response = fixture_response!("issues_state_types.json")
    [first, second] = get_in(response, [:body, "data", "issues", "nodes"])

    first =
      first
      |> put_in(["state", "type"], nil)
      |> put_in(["labels", "nodes"], [%{}])
      |> Map.put("inverseRelations", nil)
      |> Map.put("createdAt", "not-a-date")
      |> Map.put("updatedAt", nil)

    second =
      put_in(second, ["inverseRelations"], %{
        "nodes" => [%{"type" => "relates", "issue" => %{"id" => "related"}}],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      })

    response = put_in(response, [:body, "data", "issues", "nodes"], [first, second])
    handler = fn _request -> {:ok, response} end

    assert {:ok, [first_issue, second_issue]} =
             Tracker.fetch_by_ids(
               config,
               ["issue-1", "issue-2"],
               tracker_opts(transport: {Transport, handler: handler})
             )

    refute first_issue.dispatchable
    assert first_issue.labels == []
    assert first_issue.blocked_by == []
    assert first_issue.created_at == nil
    assert first_issue.updated_at == nil
    assert second_issue.blocked_by == []
  end

  test "fetch and transition callbacks normalize malformed, unsupported, cursor, and transport failures" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-callback-error-secret")

    assert {:error, %{code: :unsupported_transition, retryable: false}} =
             Tracker.transition_issue(config, "issue-1", :unknown, tracker_opts([]))

    rejected_transition =
      response_fixture("transition_success.json", fn response ->
        put_in(response, [:body, "data", "issueUpdate", "success"], false)
      end)

    assert {:error, %{code: :provider_error}} =
             Tracker.transition_issue(
               config,
               "issue-1",
               :completed,
               tracker_opts(transport: {Transport, response: rejected_transition})
             )

    transport_error = {Transport, response: {:error, :timeout}}

    assert {:error, %{code: :transport_failed, retryable: true}} =
             Tracker.transition_issue(
               config,
               "issue-1",
               :completed,
               tracker_opts(transport: transport_error)
             )

    invalid_nodes =
      response_fixture("issues_state_types.json", fn response ->
        put_in(response, [:body, "data", "issues", "nodes"], :not_a_list)
      end)

    assert {:error, %{code: :invalid_response}} =
             Tracker.fetch_by_ids(
               config,
               ["issue-1"],
               tracker_opts(transport: {Transport, response: invalid_nodes})
             )

    criteria = %{"states" => ["Custom building name"], "required_labels" => ["ready-for-agent"]}

    invalid_cursor =
      response_fixture("issues_eligible.json", fn response ->
        put_in(response, [:body, "data", "issues", "pageInfo"], %{"hasNextPage" => true})
      end)

    assert {:error, %{code: :invalid_response}} =
             Tracker.fetch_eligible(
               config,
               criteria,
               tracker_opts(transport: {Transport, response: invalid_cursor})
             )

    invalid_page =
      response_fixture("issues_eligible.json", fn response ->
        put_in(response, [:body, "data", "issues", "nodes"], :not_a_list)
      end)

    assert {:error, %{code: :invalid_response}} =
             Tracker.fetch_eligible(
               config,
               criteria,
               tracker_opts(transport: {Transport, response: invalid_page})
             )

    assert {:error, %{code: :transport_failed}} =
             Tracker.fetch_eligible(
               config,
               criteria,
               tracker_opts(transport: transport_error)
             )
  end

  test "signed Linear webhooks reject malformed payload shapes and ignore unsupported objects" do
    {base_config, _credential_ref} = linear_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000319"
    config = put_in(base_config, [:settings, :webhook_secret_ref], webhook_secret_ref)
    secret = "linear-webhook-shapes-secret"
    Broker.put_secret(webhook_secret_ref, secret)
    timestamp = 1_721_430_000_000
    opts = tracker_opts(clock: fn -> timestamp end)
    base_payload = fixture_json!("webhook_active.json")

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(config, signed_body_request("{", secret), opts)

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               %{headers: %{"linear-signature" => "unused"}, body: nil},
               opts
             )

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(config, signed_payload_request([], secret), opts)

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               base_payload
               |> put_in(["data", "id"], nil)
               |> signed_payload_request(secret),
               opts
             )

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               base_payload
               |> Map.delete("webhookId")
               |> signed_payload_request(secret),
               opts
             )

    assert {:ok, %{kind: :ignored, reason: :unsupported_object}} =
             Tracker.normalize_webhook(
               config,
               base_payload
               |> Map.put("type", "Comment")
               |> signed_payload_request(secret),
               opts
             )

    assert {:ok, %{kind: :issue}} =
             Tracker.normalize_webhook(
               config,
               base_payload
               |> Map.put("webhookTimestamp", Integer.to_string(timestamp))
               |> signed_payload_request(secret),
               opts
             )

    for invalid_timestamp <- ["not-a-timestamp", nil] do
      assert {:error, %{code: :invalid_webhook}} =
               Tracker.normalize_webhook(
                 config,
                 base_payload
                 |> Map.put("webhookTimestamp", invalid_timestamp)
                 |> signed_payload_request(secret),
                 opts
               )
    end
  end

  test "Linear webhook clock options and configured state ids normalize safely" do
    {base_config, _credential_ref} = linear_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000419"
    config = put_in(base_config, [:settings, :webhook_secret_ref], webhook_secret_ref)
    secret = "linear-webhook-options-secret"
    Broker.put_secret(webhook_secret_ref, secret)
    timestamp = 1_721_430_000_000
    base_payload = fixture_json!("webhook_active.json")

    assert {:ok, %{kind: :issue}} =
             Tracker.normalize_webhook(
               config,
               signed_payload_request(base_payload, secret),
               tracker_opts(now_ms: timestamp)
             )

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               signed_payload_request(base_payload, secret),
               tracker_opts(clock: :invalid)
             )

    assert {:ok, %{kind: :issue}} =
             Tracker.normalize_webhook(
               config,
               signed_payload_request(base_payload, secret),
               tracker_opts(
                 clock: fn -> timestamp end,
                 webhook_tolerance_ms: :invalid,
                 webhook_future_tolerance_ms: :invalid
               )
             )

    state_id_payload =
      base_payload
      |> update_in(["data"], &(&1 |> Map.delete("state") |> Map.put("stateId", "state-completed")))

    assert {:ok, %{kind: :human_terminal, terminal_state: :completed}} =
             Tracker.normalize_webhook(
               config,
               signed_payload_request(state_id_payload, secret),
               tracker_opts(clock: fn -> timestamp end)
             )

    atom_mapping_config = put_in(config, [:settings, :state_ids], %{completed: "state-completed"})

    assert {:ok, %{kind: :human_terminal, terminal_state: :completed}} =
             Tracker.normalize_webhook(
               atom_mapping_config,
               signed_payload_request(state_id_payload, secret),
               tracker_opts(clock: fn -> timestamp end)
             )

    no_state_payload = update_in(base_payload, ["data"], &Map.delete(&1, "state"))

    assert {:ok, %{kind: :issue}} =
             Tracker.normalize_webhook(
               config,
               signed_payload_request(no_state_payload, secret),
               tracker_opts(clock: fn -> timestamp end)
             )

    assert {:ok, %{kind: :issue}} =
             Tracker.normalize_webhook(
               put_in(config, [:settings, :state_ids], nil),
               state_id_payload
               |> put_in(["data", "stateId"], "unknown-state")
               |> signed_payload_request(secret),
               tracker_opts(clock: fn -> timestamp end)
             )

    assert {:ok, %{kind: :issue}} =
             Tracker.normalize_webhook(
               config,
               base_payload
               |> put_in(["data", "state", "type"], 123)
               |> signed_payload_request(secret),
               tracker_opts(clock: fn -> timestamp end)
             )
  end

  test "comment reads and mutations preserve safe errors across every response shape" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-comment-errors-secret")

    invalid_cursor =
      response_fixture("comments_empty.json", fn response ->
        put_in(response, [:body, "data", "issue", "comments", "pageInfo"], %{
          "hasNextPage" => true
        })
      end)

    invalid_nodes =
      response_fixture("comments_empty.json", fn response ->
        put_in(response, [:body, "data", "issue", "comments", "nodes"], :not_a_list)
      end)

    invalid_shape =
      response_fixture("comments_empty.json", fn response ->
        put_in(response, [:body, "data", "issue"], nil)
      end)

    for response <- [invalid_cursor, invalid_nodes, invalid_shape] do
      assert {:error, %{code: :invalid_response}} =
               Tracker.upsert_progress(
                 config,
                 "issue-1",
                 "progress",
                 tracker_opts(transport: {Transport, response: response})
               )
    end

    assert {:error, %{code: :transport_failed}} =
             Tracker.upsert_progress(
               config,
               "issue-1",
               "progress",
               tracker_opts(transport: {Transport, response: {:error, :timeout}})
             )

    rejected_create =
      response_fixture("comment_create.json", fn response ->
        put_in(response, [:body, "data", "commentCreate", "success"], false)
      end)

    assert {:error, %{code: :provider_error}} =
             Tracker.upsert_progress(
               config,
               "issue-1",
               "progress",
               tracker_opts(
                 transport:
                   {Transport,
                    handler:
                      response_sequence([
                        response_fixture("comments_empty.json"),
                        rejected_create
                      ])}
               )
             )

    assert {:error, %{code: :transport_failed}} =
             Tracker.upsert_progress(
               config,
               "issue-1",
               "progress",
               tracker_opts(
                 transport:
                   {Transport,
                    handler:
                      response_sequence([
                        response_fixture("comments_empty.json"),
                        {:error, :timeout}
                      ])}
               )
             )
  end

  test "upsert_progress rejects a Linear comment pagination cap before transport" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-comment-pagination-cap-secret")

    assert {:error, %{code: :pagination_limit, retryable: false}} =
             Tracker.upsert_progress(
               config,
               "issue-1",
               "progress",
               tracker_opts(
                 transport: {Transport, handler: fn _request -> flunk("pagination cap must stop before transport") end},
                 max_pages: 0
               )
             )
  end

  test "comment ownership handles non-text bodies and absent actor identities" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-comment-ownership-secret")

    non_text_body =
      response_fixture("comments_progress_owned.json", fn response ->
        put_in(response, [:body, "data", "issue", "comments", "nodes", Access.at(0), "body"], nil)
      end)

    absent_actor =
      response_fixture("comments_progress_owned.json", fn response ->
        put_in(response, [:body, "data", "issue", "comments", "nodes", Access.at(0), "user"], %{})
      end)

    for comments <- [non_text_body, absent_actor] do
      assert {:ok, %{action: :created, external_comment_id: "comment-1"}} =
               Tracker.upsert_progress(
                 config,
                 "issue-1",
                 "progress",
                 tracker_opts(
                   transport:
                     {Transport,
                      handler:
                        response_sequence([
                          comments,
                          response_fixture("comment_create.json")
                        ])}
                 )
               )
    end

    direct_config = put_in(config, [:settings, :bot_actor_id], nil)

    assert {:ok, %{action: :created}} =
             LinearAdapter.upsert_progress(
               direct_config,
               "issue-1",
               "progress",
               credential: "direct-linear-secret",
               transport:
                 {Transport,
                  handler:
                    response_sequence([
                      response_fixture("comments_progress_owned.json"),
                      response_fixture("comment_create.json")
                    ])}
             )
  end

  test "GraphQL response validation covers malformed errors and every retry hint shape" do
    {config, credential_ref} = linear_config()
    Broker.put_secret(credential_ref, "linear-graphql-matrix-secret")

    invalid_error_list =
      fixture_response!("issues_state_types.json")
      |> put_in([:body, "errors"], :not_a_list)

    for response <- [
          {:ok, invalid_error_list},
          {:ok, %{status: 200, headers: %{}, body: :not_a_map}},
          {:ok, %{headers: %{}, body: %{}}}
        ] do
      assert {:error, %{code: :invalid_response}} = fetch_with_response(config, response)
    end

    assert {:error, %{code: :provider_error, retryable: false}} =
             fetch_with_response(
               config,
               graphql_errors_response(400, [%{"extensions" => %{"code" => "BAD_USER_INPUT"}}])
             )

    for errors <- [
          [%{"extensions" => %{"code" => 123}}],
          [nil]
        ] do
      assert {:error, %{code: :provider_error, retryable: false}} =
               fetch_with_response(config, graphql_errors_response(200, errors))
    end

    assert {:error, %{code: :rate_limited, retry_after_ms: nil}} =
             fetch_with_response(
               config,
               graphql_errors_response(400, [rate_limit_error(%{})])
             )

    assert {:error, %{code: :rate_limited, retry_after_ms: 2_500}} =
             fetch_with_response(
               config,
               graphql_errors_response(400, [rate_limit_error(%{"retryAfterMs" => 2_500})])
             )

    assert {:error, %{code: :rate_limited, retry_after_ms: 3_000}} =
             fetch_with_response(
               config,
               graphql_errors_response(400, [rate_limit_error(%{"retry_after_ms" => "3000"})])
             )

    assert {:error, %{code: :rate_limited, retry_after_ms: 4_000}} =
             fetch_with_response(
               config,
               graphql_errors_response(400, [
                 rate_limit_error(%{
                   "retryAfterMs" => "invalid",
                   "retry_after_ms" => nil,
                   "retryAfter" => 4
                 })
               ])
             )

    assert {:error, %{code: :rate_limited, retry_after_ms: 5_000}} =
             fetch_with_response(
               config,
               graphql_errors_response(400, [
                 nil,
                 rate_limit_error(%{"retryAfter" => 5})
               ])
             )

    assert {:error, %{code: :rate_limited, retry_after_ms: 6_000}} =
             fetch_with_response(
               config,
               graphql_errors_response(400, [
                 %{"extensions" => :invalid},
                 rate_limit_error(%{"retryAfter" => 6})
               ])
             )

    invalid_project_id =
      response_fixture("health.json", fn response ->
        put_in(response, [:body, "data", "projects", "nodes", Access.at(0), "id"], 123)
      end)

    assert {:error, %{code: :invalid_response}} = health_with_response(config, invalid_project_id)
  end

  defp linear_config do
    credential_ref = "00000000-0000-4000-8000-000000000018"

    {%{
       provider: "linear",
       credential_ref: credential_ref,
       settings: %{
         endpoint: "https://linear.test/graphql",
         bot_actor_id: "linear-bot",
         project_slug: "ENG",
         state_ids: %{
           "started" => "state-started",
           "completed" => "state-completed",
           "cancelled" => "state-cancelled"
         }
       }
     }, credential_ref}
  end

  defp linear_page(issues, has_next_page, end_cursor) do
    {:ok,
     %{
       status: 200,
       headers: %{},
       body: %{
         "data" => %{
           "issues" => %{
             "nodes" => issues,
             "pageInfo" => %{
               "hasNextPage" => has_next_page,
               "endCursor" => end_cursor
             }
           }
         }
       }
     }}
  end

  defp linear_issue(id, identifier) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => "Linear issue #{identifier}",
      "description" => "Issue body",
      "priority" => 2,
      "state" => %{"name" => "In Progress", "type" => "started"},
      "branchName" => "feature/#{identifier}",
      "url" => "https://linear.test/issue/#{identifier}",
      "assignee" => %{"id" => "worker-1"},
      "labels" => %{"nodes" => [%{"name" => "ready-for-agent"}]},
      "inverseRelations" => %{
        "nodes" => [],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      },
      "createdAt" => "2026-07-20T00:00:00Z",
      "updatedAt" => "2026-07-20T00:01:00Z"
    }
  end

  defp response_fixture(name) do
    fixture = name |> fixture_path() |> File.read!() |> Jason.decode!()

    {:ok,
     %{
       status: Map.fetch!(fixture, "status"),
       headers: Map.get(fixture, "headers", %{}),
       body: Map.fetch!(fixture, "body")
     }}
  end

  defp response_fixture(name, update) when is_function(update, 1) do
    {:ok, response} = response_fixture(name)
    {:ok, update.(response)}
  end

  defp fixture_response!(name) do
    {:ok, response} = response_fixture(name)
    response
  end

  defp fixture_json!(name) do
    name |> fixture_path() |> File.read!() |> Jason.decode!()
  end

  defp signed_payload_request(payload, secret) do
    payload |> Jason.encode!() |> signed_body_request(secret)
  end

  defp signed_body_request(body, secret) do
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    %{headers: %{"linear-signature" => signature}, body: body}
  end

  defp health_with_response(config, response) do
    Tracker.health_check(
      config,
      tracker_opts(transport: {Transport, response: response})
    )
  end

  defp fetch_with_response(config, response) do
    Tracker.fetch_by_ids(
      config,
      ["issue-1"],
      tracker_opts(transport: {Transport, response: response})
    )
  end

  defp graphql_errors_response(status, errors) do
    {:ok, %{status: status, headers: %{}, body: %{"errors" => errors}}}
  end

  defp rate_limit_error(extensions) do
    %{"extensions" => Map.put(extensions, "code", "RATELIMITED")}
  end

  defp response_sequence(responses) do
    {:ok, state} = Agent.start_link(fn -> responses end)

    fn _request ->
      Agent.get_and_update(state, fn
        [response | remaining] -> {response, remaining}
        [] -> {{:error, :unexpected_fixture_request}, []}
      end)
    end
  end

  defp signed_webhook_request(name, secret) do
    body = name |> fixture_path() |> File.read!()
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    %{headers: %{"linear-signature" => signature}, body: body}
  end

  defp tracker_opts(extra) do
    Keyword.merge(
      [
        credential_broker: Broker,
        endpoint_trusted_origins: ["https://linear.test"],
        endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
      ],
      extra
    )
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, name)
end

defmodule SymphonyElixir.TrackerLinearContractTest do
  use SymphonyElixir.TrackerContract,
    provider: "linear",
    adapter: SymphonyElixir.Tracker.Adapters.Linear,
    async: true

  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport
  alias SymphonyElixir.TrackerContract.Broker

  @fixture_dir Path.expand("../fixtures/trackers/linear", __DIR__)

  def tracker_contract_case(:health_check) do
    contract_case(
      :health_check,
      fixture_sequence([{"SymphonyTrackerHealth", "health.json"}])
    )
  end

  def tracker_contract_case(:fetch_eligible) do
    :fetch_eligible
    |> contract_case(fixture_sequence([{"SymphonyTrackerPoll", "issues_eligible.json"}]))
    |> Map.merge(%{
      criteria: %{
        "states" => ["Custom building name"],
        "required_labels" => ["ready-for-agent"]
      },
      expected_ids: ["issue-eligible"]
    })
  end

  def tracker_contract_case(:fetch_by_ids) do
    :fetch_by_ids
    |> contract_case(fixture_sequence([{"SymphonyTrackerIssuesById", "issues_state_types.json"}]))
    |> Map.merge(%{
      issue_ids: ["issue-2", "issue-1"],
      expected_ids: ["issue-2", "issue-1"]
    })
  end

  def tracker_contract_case(:normalize_webhook) do
    credential_ref = credential_ref(:normalize_webhook)
    webhook_secret_ref = "00000000-0000-4000-8000-000000000305"
    secret = "linear-contract-webhook-secret"
    Broker.put_secret(webhook_secret_ref, secret)

    %{
      config:
        credential_ref
        |> linear_config()
        |> put_in([:settings, :webhook_secret_ref], webhook_secret_ref),
      request: signed_webhook_request("webhook_completed.json", secret),
      opts: tracker_opts(clock: fn -> 1_721_430_030_000 end),
      expected_issue_id: "issue-1",
      credential_ref: webhook_secret_ref,
      credential_purpose: :tracker_normalize_webhook
    }
  end

  def tracker_contract_case(:transition_issue) do
    :transition_issue
    |> contract_case(fixture_sequence([{"SymphonyTrackerTransition", "transition_success.json"}]))
    |> Map.merge(%{
      issue_id: "issue-1",
      target_state: :completed,
      expected_state: "completed"
    })
  end

  def tracker_contract_case(:upsert_progress) do
    sequence = [
      {"SymphonyTrackerComments", "comments_empty.json"},
      {"SymphonyTrackerCommentCreate", "comment_create.json"},
      {"SymphonyTrackerComments", "comments_progress_owned.json"},
      {"SymphonyTrackerCommentUpdate", "comment_update_progress.json"}
    ]

    :upsert_progress
    |> contract_case(fixture_sequence(sequence))
    |> Map.merge(%{issue_id: "issue-1", first_text: "progress one", second_text: "progress two"})
  end

  def tracker_contract_case(:append_final_summary) do
    sequence = [
      {"SymphonyTrackerComments", "comments_empty.json"},
      {"SymphonyTrackerCommentCreate", "comment_create_final.json"},
      {"SymphonyTrackerComments", "comments_final_page_2.json"},
      {"SymphonyTrackerCommentUpdate", "comment_update.json"}
    ]

    :append_final_summary
    |> contract_case(fixture_sequence(sequence))
    |> Map.merge(%{issue_id: "issue-1", first_text: "final one", second_text: "final two"})
  end

  defp contract_case(operation, handler) do
    reference = credential_ref(operation)
    Broker.put_secret(reference, "linear-contract-#{operation}-secret")

    %{
      config: linear_config(reference),
      opts: tracker_opts(transport: {Transport, handler: handler}),
      credential_ref: reference,
      credential_purpose: credential_purpose(operation)
    }
  end

  defp fixture_sequence(steps) do
    {:ok, state} = Agent.start_link(fn -> steps end)

    fn request ->
      Agent.get_and_update(state, fn
        [{operation_name, fixture} | remaining] ->
          response =
            fixture_response_for_operation(request.body.operation_name, operation_name, fixture)

          {response, remaining}

        [] ->
          {{:error, :unexpected_fixture_request}, []}
      end)
    end
  end

  defp fixture_response_for_operation(actual, expected, fixture) when actual == expected,
    do: response_fixture(fixture)

  defp fixture_response_for_operation(actual, _expected, _fixture),
    do: {:error, {:unexpected_operation, actual}}

  defp response_fixture(name) do
    fixture = name |> fixture_path() |> File.read!() |> Jason.decode!()

    {:ok,
     %{
       status: Map.fetch!(fixture, "status"),
       headers: Map.get(fixture, "headers", %{}),
       body: Map.fetch!(fixture, "body")
     }}
  end

  defp signed_webhook_request(name, secret) do
    body = name |> fixture_path() |> File.read!()
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    %{headers: %{"linear-signature" => signature}, body: body}
  end

  defp tracker_opts(extra) do
    Keyword.merge(
      [
        credential_broker: Broker,
        endpoint_trusted_origins: ["https://linear.test"],
        endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
      ],
      extra
    )
  end

  defp linear_config(credential_ref) do
    %{
      provider: "linear",
      credential_ref: credential_ref,
      settings: %{
        endpoint: "https://linear.test/graphql",
        bot_actor_id: "linear-bot",
        project_slug: "ENG",
        state_ids: %{
          "started" => "state-started",
          "completed" => "state-completed",
          "cancelled" => "state-cancelled"
        }
      }
    }
  end

  defp credential_ref(:health_check), do: "00000000-0000-4000-8000-000000000301"
  defp credential_ref(:fetch_eligible), do: "00000000-0000-4000-8000-000000000302"
  defp credential_ref(:fetch_by_ids), do: "00000000-0000-4000-8000-000000000303"
  defp credential_ref(:normalize_webhook), do: "00000000-0000-4000-8000-000000000304"
  defp credential_ref(:transition_issue), do: "00000000-0000-4000-8000-000000000306"
  defp credential_ref(:upsert_progress), do: "00000000-0000-4000-8000-000000000307"
  defp credential_ref(:append_final_summary), do: "00000000-0000-4000-8000-000000000308"

  defp credential_purpose(:health_check), do: :tracker_health_check
  defp credential_purpose(:fetch_eligible), do: :tracker_fetch_eligible
  defp credential_purpose(:fetch_by_ids), do: :tracker_fetch_by_ids
  defp credential_purpose(:transition_issue), do: :tracker_transition_issue
  defp credential_purpose(:upsert_progress), do: :tracker_upsert_progress
  defp credential_purpose(:append_final_summary), do: :tracker_append_final_summary

  defp fixture_path(name), do: Path.join(@fixture_dir, name)
end
