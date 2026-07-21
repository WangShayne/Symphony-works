defmodule SymphonyElixir.TrackerGitLabTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport
  alias SymphonyElixir.TrackerContract.Broker

  test "health check proves GitLab scope, bot identity, issue read, state mapping, and note permission read-only" do
    {config, credential_ref} = gitlab_config()
    secret = "gitlab-health-secret"
    Broker.put_secret(credential_ref, secret)

    handler = fn %{method: :get} = request ->
      assert request.method == :get
      assert request.headers["private-token"] == secret

      case request.url do
        "https://gitlab.test/api/v4/projects/acme%2Fsymphony" ->
          {:ok, %{status: 200, headers: %{}, body: fixture!("project.json")}}

        "https://gitlab.test/api/v4/user" ->
          {:ok, %{status: 200, headers: %{}, body: fixture!("user.json")}}

        "https://gitlab.test/api/v4/personal_access_tokens/self" ->
          {:ok, %{status: 200, headers: %{}, body: fixture!("personal_access_token.json")}}

        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues" ->
          assert Keyword.fetch!(request.params, :state) == "all"
          assert Keyword.fetch!(request.params, :per_page) == 1
          {:ok, %{status: 200, headers: %{}, body: [gitlab_issue(1)]}}
      end
    end

    assert {:ok,
            %{
              provider: "gitlab",
              status: :healthy,
              evidence: %{
                http_status: 200,
                credentials: :verified,
                scope: :verified,
                scope_ref: "acme/symphony",
                bot_actor_id: "42",
                issue_read: :verified,
                state_mappings: :verified,
                comment_permissions: :verified
              }
            } = evidence} =
             Tracker.health_check(
               config,
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )

    refute inspect(evidence) =~ secret
    refute inspect(evidence) =~ credential_ref
  end

  test "fetch_eligible returns project IIDs that round-trip and excludes merge requests" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-fetch-secret")

    handler = fn
      %{method: :get, url: "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues"} = request ->
        case Keyword.fetch!(request.params, :page) do
          1 ->
            {:ok,
             %{
               status: 200,
               headers: %{"x-next-page" => "2"},
               body: [
                 gitlab_issue(1),
                 %{"id" => 9002, "iid" => 2, "object_kind" => "merge_request", "title" => "MR"}
               ]
             }}

          2 ->
            {:ok, %{status: 200, headers: %{"x-next-page" => ""}, body: [gitlab_issue(3)]}}
        end

      %{method: :put, url: "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3"} = request ->
        assert request.body == %{state_event: "close"}

        {:ok,
         %{
           status: 200,
           headers: %{},
           body: gitlab_issue(3) |> Map.put("state", "closed")
         }}
    end

    assert {:ok, [first_issue, second_issue]} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )

    assert %SymphonyElixir.Tracker.Issue{id: "1", identifier: "#1"} = first_issue
    assert %SymphonyElixir.Tracker.Issue{id: "3", identifier: "#3"} = second_issue

    assert {:ok, %{provider: "gitlab", issue_id: "3", state: "closed"}} =
             Tracker.transition_issue(
               config,
               second_issue.id,
               :closed,
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "fetch_eligible rejects a GitLab pagination cap before transport" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-pagination-cap-secret")

    assert {:error, %{code: :pagination_limit, retryable: false}} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: fn _request -> flunk("pagination cap must stop before transport") end},
                 max_pages: 0
               )
             )
  end

  test "fetch_by_ids reads only the GitLab Issues endpoint" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-by-id-secret")

    handler = fn request ->
      refute request.url =~ "merge_requests"

      case request.url do
        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3" ->
          {:ok, %{status: 200, headers: %{}, body: gitlab_issue(3)}}

        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/404" ->
          {:ok, %{status: 404, headers: %{}, body: %{"message" => "missing"}}}
      end
    end

    assert {:ok, [%SymphonyElixir.Tracker.Issue{identifier: "#3"}]} =
             Tracker.fetch_by_ids(
               config,
               ["3", "404"],
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "fetch_by_ids rejects a malformed successful GitLab issue payload" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-malformed-issue-secret")

    handler = fn _request ->
      {:ok,
       %{
         status: 200,
         headers: %{},
         body: gitlab_issue(3) |> Map.delete("iid")
       }}
    end

    assert {:error, %{provider: "gitlab", code: :invalid_response, retryable: false}} =
             Tracker.fetch_by_ids(
               config,
               ["3"],
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "fetch_by_ids rejects a valid GitLab issue payload for a different project IID" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-mismatched-issue-secret")

    handler = fn _request ->
      {:ok, %{status: 200, headers: %{}, body: gitlab_issue(1)}}
    end

    assert {:error, %{provider: "gitlab", code: :invalid_response, retryable: false}} =
             Tracker.fetch_by_ids(
               config,
               ["3"],
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "fetch_eligible requests all GitLab states for mixed open and closed criteria" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-mixed-state-secret")

    handler = fn request ->
      assert Keyword.fetch!(request.params, :state) == "all"

      {:ok,
       %{
         status: 200,
         headers: %{"x-next-page" => ""},
         body: [gitlab_issue(1), gitlab_issue(3) |> Map.put("state", "closed")]
       }}
    end

    assert {:ok, [%{id: "1", state: "open"}]} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["open", "closed"], "required_labels" => ["ready-for-agent"]},
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "fetch_eligible rejects a malformed issue inside a successful GitLab page" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-malformed-page-secret")

    handler = fn _request ->
      {:ok,
       %{
         status: 200,
         headers: %{"x-next-page" => ""},
         body: [gitlab_issue(1) |> Map.delete("iid")]
       }}
    end

    assert {:error, %{provider: "gitlab", code: :invalid_response, retryable: false}} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "normalize_webhook verifies GitLab signing headers and separates merge requests" do
    {base_config, _credential_ref} = gitlab_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000029"
    config = put_in(base_config, ["settings", "webhook_secret_ref"], webhook_secret_ref)
    secret = "gitlab-webhook-secret"
    Broker.put_secret(webhook_secret_ref, secret)

    issue_body =
      Jason.encode!(%{
        "object_kind" => "issue",
        "object_attributes" => %{"iid" => 3, "action" => "update"}
      })

    issue_request = gitlab_webhook_request(issue_body, secret, "webhook-3", 1_000)

    assert {:ok,
            %{
              provider: "gitlab",
              kind: :issue,
              action: "update",
              issue_id: "3",
              reconciliation_key: "gitlab:webhook-3"
            }} =
             Tracker.normalize_webhook(
               config,
               issue_request,
               tracker_opts(
                 credential_broker: Broker,
                 now: 1_000
               )
             )

    invalid_request = put_in(issue_request, [:headers, "webhook-signature"], "v1,bad")

    assert {:error, %{code: :invalid_signature, retryable: false}} =
             Tracker.normalize_webhook(
               config,
               invalid_request,
               tracker_opts(
                 credential_broker: Broker,
                 now: 1_000
               )
             )

    mr_body = Jason.encode!(%{"object_kind" => "merge_request", "object_attributes" => %{"iid" => 4}})
    mr_request = gitlab_webhook_request(mr_body, secret, "webhook-4", 1_000)

    assert {:ok, %{kind: :ignored, reason: :change_request}} =
             Tracker.normalize_webhook(
               config,
               mr_request,
               tracker_opts(
                 credential_broker: Broker,
                 now: 1_000
               )
             )
  end

  test "normalize_webhook decodes a GitLab 19 whsec signing token before HMAC" do
    {base_config, _credential_ref} = gitlab_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000030"
    config = put_in(base_config, ["settings", "webhook_secret_ref"], webhook_secret_ref)
    signing_key = "gitlab-19-webhook-key"
    Broker.put_secret(webhook_secret_ref, "whsec_" <> Base.encode64(signing_key))

    body = fixture!("webhook_issue_closed.json") |> Jason.encode!()
    request = gitlab_webhook_request(body, signing_key, "webhook-whsec", 1_000)

    assert {:ok,
            %{
              provider: "gitlab",
              kind: :human_terminal,
              action: "close",
              issue_id: "3",
              reconciliation_key: "gitlab:webhook-whsec"
            }} =
             Tracker.normalize_webhook(
               config,
               request,
               tracker_opts(
                 credential_broker: Broker,
                 now: 1_000
               )
             )
  end

  test "normalize_webhook rejects a signed GitLab Issue Hook without a project IID" do
    {base_config, _credential_ref} = gitlab_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000033"
    config = put_in(base_config, ["settings", "webhook_secret_ref"], webhook_secret_ref)
    secret = "gitlab-malformed-webhook-secret"
    Broker.put_secret(webhook_secret_ref, secret)

    payload =
      fixture!("webhook_issue_closed.json")
      |> update_in(["object_attributes"], &Map.delete(&1, "iid"))

    body = Jason.encode!(payload)
    request = gitlab_webhook_request(body, secret, "webhook-missing-iid", 1_000)

    assert {:error, %{provider: "gitlab", code: :invalid_webhook, retryable: false}} =
             Tracker.normalize_webhook(
               config,
               request,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )
  end

  test "transition_issue maps normalized state to GitLab state_event" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-transition-secret")

    handler = fn request ->
      assert request.method == :put
      assert request.url == "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3"
      assert request.body == %{state_event: "close"}
      {:ok, %{status: 200, headers: %{}, body: gitlab_issue(3) |> Map.put("state", "closed")}}
    end

    assert {:ok, %{provider: "gitlab", issue_id: "3", state: "closed"}} =
             Tracker.transition_issue(
               config,
               "3",
               :closed,
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "transition_issue reopens GitLab and returns the normalized open state" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-reopen-secret")

    handler = fn request ->
      assert request.body == %{state_event: "reopen"}
      {:ok, %{status: 200, headers: %{}, body: gitlab_issue(3)}}
    end

    assert {:ok, %{provider: "gitlab", issue_id: "3", state: "open"}} =
             Tracker.transition_issue(
               config,
               "3",
               :open,
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "transition_issue rejects a malformed successful GitLab mutation payload" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-malformed-transition-secret")

    handler = fn _request ->
      {:ok,
       %{
         status: 200,
         headers: %{},
         body: gitlab_issue(3) |> Map.delete("state")
       }}
    end

    assert {:error, %{provider: "gitlab", code: :invalid_response, retryable: false}} =
             Tracker.transition_issue(
               config,
               "3",
               :closed,
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "upsert_progress creates the stable GitLab note marker" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-progress-secret")

    handler = fn request ->
      case request.method do
        :get ->
          assert request.url == "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3/notes"

          {:ok,
           %{
             status: 200,
             headers: %{},
             body: [fixture!("note_embedded_marker.json")]
           }}

        :post ->
          assert request.body.body =~ "<!-- symphony-tracker:progress issue=gitlab:3 -->"
          {:ok, %{status: 201, headers: %{}, body: %{"id" => 63}}}
      end
    end

    assert {:ok,
            %{
              provider: "gitlab",
              action: :created,
              external_id: "63",
              external_comment_id: "63"
            }} =
             Tracker.upsert_progress(
               config,
               "3",
               "running",
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "upsert_progress rejects a malformed successful GitLab notes page" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-malformed-notes-secret")

    handler = fn _request ->
      {:ok, %{status: 200, headers: %{}, body: [nil]}}
    end

    assert {:error, %{provider: "gitlab", code: :invalid_response, retryable: false}} =
             Tracker.upsert_progress(
               config,
               "3",
               "running",
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "upsert_progress rejects a malformed GitLab note author" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-malformed-note-author-secret")

    handler = fn _request ->
      {:ok, %{status: 200, headers: %{}, body: [fixture!("note_invalid_author.json")]}}
    end

    assert {:error, %{provider: "gitlab", code: :invalid_response, retryable: false}} =
             Tracker.upsert_progress(
               config,
               "3",
               "running",
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "upsert_progress rejects a malformed successful GitLab note mutation" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-malformed-note-mutation-secret")

    handler = fn request ->
      case request.method do
        :get -> {:ok, %{status: 200, headers: %{}, body: []}}
        :post -> {:ok, %{status: 201, headers: %{}, body: fixture!("note_missing_id.json")}}
      end
    end

    assert {:error, %{provider: "gitlab", code: :invalid_response, retryable: false}} =
             Tracker.upsert_progress(
               config,
               "3",
               "running",
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "append_final_summary updates the independent GitLab final marker" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-final-secret")
    marker = "<!-- symphony-tracker:final issue=gitlab:3 -->"

    handler = fn request ->
      case request.method do
        :get ->
          {:ok,
           %{
             status: 200,
             headers: %{},
             body: [
               %{"id" => 73, "body" => marker <> "\nold", "author" => %{"id" => 42}}
             ]
           }}

        :put ->
          assert request.url ==
                   "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3/notes/73"

          assert request.body.body == marker <> "\naccepted"
          {:ok, %{status: 200, headers: %{}, body: %{"id" => 73}}}
      end
    end

    assert {:ok,
            %{
              provider: "gitlab",
              action: :updated,
              external_id: "73",
              external_comment_id: "73"
            }} =
             Tracker.append_final_summary(
               config,
               "3",
               "accepted",
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "health_check rejects incomplete GitLab capability evidence and transport failures" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-health-errors-secret")

    project_url = "https://gitlab.test/api/v4/projects/acme%2Fsymphony"
    user_url = "https://gitlab.test/api/v4/user"
    token_url = "https://gitlab.test/api/v4/personal_access_tokens/self"
    issues_url = project_url <> "/issues"
    project = fixture!("project.json")

    low_access_project =
      put_in(project, ["permissions"], %{
        "project_access" => %{"access_level" => 0},
        "group_access" => nil
      })

    cases = [
      {%{project_url => {:ok, %{status: 200, headers: %{}, body: []}}}, :invalid_response},
      {%{project_url => {:ok, %{headers: %{}}}}, :invalid_response},
      {%{project_url => {:error, :timeout}}, :transport_failed},
      {%{project_url => health_response(Map.put(project, "issues_access_level", "disabled"))}, :forbidden},
      {%{project_url => health_response(low_access_project)}, :forbidden},
      {%{user_url => health_response(%{"id" => 7, "state" => "active"})}, :invalid_response},
      {%{user_url => health_response(%{"id" => 42, "state" => "blocked"})}, :invalid_response},
      {%{token_url => health_response(%{"active" => false, "revoked" => false, "scopes" => ["api"]})}, :forbidden},
      {%{issues_url => health_response([nil])}, :invalid_response}
    ]

    for {overrides, expected_code} <- cases do
      assert {:error, %{provider: "gitlab", code: ^expected_code}} =
               Tracker.health_check(
                 config,
                 tracker_opts(
                   credential_broker: Broker,
                   transport: {Transport, handler: health_handler(overrides)}
                 )
               )
    end
  end

  test "fetch_by_ids normalizes optional GitLab fields and skips merge request payloads" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-normalization-secret")

    first_issue =
      gitlab_issue(1)
      |> Map.put("iid", "1")
      |> Map.put("labels", nil)
      |> Map.put("assignee", %{"username" => "worker"})
      |> Map.put("created_at", "not-a-datetime")
      |> Map.put("updated_at", nil)

    second_issue = gitlab_issue(3) |> Map.put("assignee", %{})

    handler = fn request ->
      case request.url do
        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/1" ->
          health_response(first_issue)

        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3" ->
          health_response(second_issue)

        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/4" ->
          health_response(%{"object_kind" => "merge_request", "iid" => 4})
      end
    end

    assert {:ok, [first, second]} =
             Tracker.fetch_by_ids(
               config,
               ["1", "3", "4"],
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )

    assert %{id: "1", labels: [], assignee_id: "worker", created_at: nil, updated_at: nil} = first
    assert %{id: "3", assignee_id: nil} = second

    assert {:error, %{code: :transport_failed}} =
             Tracker.fetch_by_ids(
               config,
               ["5"],
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: fn _request -> {:error, :timeout} end}
               )
             )

    assert {:error, %{code: :invalid_response}} =
             Tracker.fetch_eligible(
               config,
               %{"states" => ["open"], "required_labels" => []},
               tracker_opts(
                 credential_broker: Broker,
                 transport:
                   {Transport,
                    handler: fn _request ->
                      {:ok, %{status: 200, headers: %{"x-next-page" => ""}, body: [nil]}}
                    end}
               )
             )
  end

  test "fetch_eligible maps GitLab HTTP and transport failures" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-fetch-errors-secret")
    criteria = %{"states" => ["open"], "required_labels" => []}

    assert {:error, %{code: :forbidden}} =
             Tracker.fetch_eligible(
               config,
               criteria,
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: fn _request -> {:ok, %{status: 403, headers: %{}, body: %{}}} end}
               )
             )

    assert {:error, %{code: :transport_failed}} =
             Tracker.fetch_eligible(
               config,
               criteria,
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: fn _request -> {:error, :timeout} end}
               )
             )
  end

  test "transition_issue maps unsupported, HTTP, malformed, and transport failures" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-transition-errors-secret")

    assert {:error, %{code: :unsupported_transition}} =
             Tracker.transition_issue(config, "3", :in_progress, tracker_opts(credential_broker: Broker))

    outcomes = [
      {{:ok, %{status: 403, headers: %{}, body: %{}}}, :forbidden},
      {{:ok, %{body: %{}}}, :invalid_response},
      {{:error, :timeout}, :transport_failed}
    ]

    for {outcome, expected_code} <- outcomes do
      assert {:error, %{code: ^expected_code}} =
               Tracker.transition_issue(
                 config,
                 "3",
                 :closed,
                 tracker_opts(
                   credential_broker: Broker,
                   transport: {Transport, handler: fn _request -> outcome end}
                 )
               )
    end
  end

  test "normalize_webhook rejects malformed GitLab delivery inputs without leaking credentials" do
    {base_config, _credential_ref} = gitlab_config()
    webhook_secret_ref = "00000000-0000-4000-8000-000000000034"
    config = put_in(base_config, ["settings", "webhook_secret_ref"], webhook_secret_ref)
    secret = "gitlab-webhook-coverage-secret"
    body = fixture!("webhook_issue_closed.json") |> Jason.encode!()

    Broker.put_secret(webhook_secret_ref, secret)

    invalid_timestamp = gitlab_webhook_request(body, secret, "invalid-timestamp", "not-a-timestamp")

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               invalid_timestamp,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )

    missing_timestamp =
      body
      |> gitlab_webhook_request(secret, "missing-timestamp", 1_000)
      |> update_in([:headers], &Map.delete(&1, "webhook-timestamp"))

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               missing_timestamp,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )

    malformed_json = gitlab_webhook_request("{", secret, "malformed-json", 1_000)

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               malformed_json,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )

    valid_request = gitlab_webhook_request(body, secret, "rescue", 1_000)

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               valid_request,
               tracker_opts(credential_broker: Broker, now: :invalid_now)
             )

    malformed_candidate = put_in(valid_request, [:headers, "webhook-signature"], "not-versioned")

    assert {:error, %{code: :invalid_signature}} =
             Tracker.normalize_webhook(
               config,
               malformed_candidate,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )

    Broker.put_secret(webhook_secret_ref, "whsec_not-base64!")

    assert {:error, %{code: :invalid_signature}} =
             Tracker.normalize_webhook(
               config,
               valid_request,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )

    Broker.put_secret(webhook_secret_ref, 123)

    assert {:error, %{code: :invalid_signature}} =
             Tracker.normalize_webhook(
               config,
               valid_request,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )

    Broker.put_secret(webhook_secret_ref, secret)
    missing_signature = update_in(valid_request, [:headers], &Map.delete(&1, "webhook-signature"))

    assert {:error, %{code: :invalid_signature}} =
             Tracker.normalize_webhook(
               config,
               missing_signature,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )

    unsupported_body = Jason.encode!(%{"object_kind" => "pipeline"})
    unsupported_request = gitlab_webhook_request(unsupported_body, secret, "unsupported-object", 1_000)

    assert {:error, %{code: :invalid_webhook}} =
             Tracker.normalize_webhook(
               config,
               unsupported_request,
               tracker_opts(credential_broker: Broker, now: 1_000)
             )
  end

  test "upsert_progress follows GitLab note pages and accepts a string note id" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-note-pagination-secret")

    handler = fn request ->
      case request.method do
        :get ->
          case Keyword.fetch!(request.params, :page) do
            1 ->
              {:ok,
               %{
                 status: 200,
                 headers: %{"x-next-page" => "2"},
                 body: [%{"id" => 60, "body" => "unrelated", "author" => %{"id" => 7}}]
               }}

            2 ->
              {:ok, %{status: 200, headers: %{"x-next-page" => ""}, body: []}}
          end

        :post ->
          {:ok, %{status: 201, headers: %{}, body: %{"id" => "note-63"}}}
      end
    end

    assert {:ok, %{action: :created, external_comment_id: "note-63"}} =
             Tracker.upsert_progress(
               config,
               "3",
               "running",
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: handler}
               )
             )
  end

  test "upsert_progress maps GitLab note page HTTP and transport failures" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-note-page-errors-secret")

    outcomes = [
      {{:ok, %{status: 403, headers: %{}, body: %{}}}, :forbidden},
      {{:error, :timeout}, :transport_failed}
    ]

    for {outcome, expected_code} <- outcomes do
      assert {:error, %{code: ^expected_code}} =
               Tracker.upsert_progress(
                 config,
                 "3",
                 "running",
                 tracker_opts(
                   credential_broker: Broker,
                   transport: {Transport, handler: fn _request -> outcome end}
                 )
               )
    end
  end

  test "upsert_progress rejects a GitLab note pagination cap before transport" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-note-pagination-cap-secret")

    assert {:error, %{code: :pagination_limit, retryable: false}} =
             Tracker.upsert_progress(
               config,
               "3",
               "running",
               tracker_opts(
                 credential_broker: Broker,
                 transport: {Transport, handler: fn _request -> flunk("pagination cap must stop before transport") end},
                 max_pages: 0
               )
             )
  end

  test "upsert_progress maps malformed, HTTP, and transport note mutation failures" do
    {config, credential_ref} = gitlab_config()
    Broker.put_secret(credential_ref, "gitlab-note-mutation-errors-secret")

    outcomes = [
      {{:ok, %{status: 201, headers: %{}, body: %{}}}, :invalid_response},
      {{:ok, %{status: 403, headers: %{}, body: %{}}}, :forbidden},
      {{:error, :timeout}, :transport_failed}
    ]

    for {mutation_outcome, expected_code} <- outcomes do
      handler = fn request ->
        case request.method do
          :get -> {:ok, %{status: 200, headers: %{}, body: []}}
          :post -> mutation_outcome
        end
      end

      assert {:error, %{code: ^expected_code}} =
               Tracker.upsert_progress(
                 config,
                 "3",
                 "running",
                 tracker_opts(
                   credential_broker: Broker,
                   transport: {Transport, handler: handler}
                 )
               )
    end
  end

  defp health_handler(overrides) do
    fn request ->
      Map.get_lazy(overrides, request.url, fn -> default_health_response(request.url) end)
    end
  end

  defp default_health_response("https://gitlab.test/api/v4/projects/acme%2Fsymphony"),
    do: health_response(fixture!("project.json"))

  defp default_health_response("https://gitlab.test/api/v4/user"),
    do: health_response(fixture!("user.json"))

  defp default_health_response("https://gitlab.test/api/v4/personal_access_tokens/self"),
    do: health_response(fixture!("personal_access_token.json"))

  defp default_health_response("https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues"),
    do: health_response([fixture!("issue_1.json")])

  defp health_response(body), do: {:ok, %{status: 200, headers: %{}, body: body}}

  defp gitlab_config do
    credential_ref = "00000000-0000-4000-8000-000000000028"

    {%{
       "provider" => "gitlab",
       "credential_ref" => credential_ref,
       "settings" => %{
         "endpoint" => "https://gitlab.test/api/v4",
         "bot_actor_id" => "42",
         "project_id" => "acme/symphony"
       }
     }, credential_ref}
  end

  defp gitlab_issue(iid) do
    fixture!("issue_#{iid}.json")
  end

  defp fixture!(name) do
    __DIR__
    |> Path.join("../fixtures/trackers/gitlab/#{name}")
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
  end

  defp gitlab_webhook_request(body, secret, webhook_id, timestamp) do
    signed = "#{webhook_id}.#{timestamp}.#{body}"
    signature = :crypto.mac(:hmac, :sha256, secret, signed) |> Base.encode64()

    %{
      headers: %{
        "webhook-id" => webhook_id,
        "webhook-timestamp" => to_string(timestamp),
        "webhook-signature" => "v1,#{signature}"
      },
      body: body
    }
  end

  defp tracker_opts(opts) do
    Keyword.merge(
      [
        endpoint_trusted_origins: ["https://gitlab.test"],
        endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
      ],
      opts
    )
  end
end

defmodule SymphonyElixir.TrackerGitLabContractTest do
  use SymphonyElixir.TrackerContract,
    provider: "gitlab",
    adapter: SymphonyElixir.Tracker.Adapters.GitLab,
    async: true

  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport
  alias SymphonyElixir.TrackerContract.Broker

  @credential_ref "00000000-0000-4000-8000-000000000031"
  @webhook_secret_ref "00000000-0000-4000-8000-000000000032"

  def tracker_contract_case(:health_check) do
    handler = fn %{method: :get} = request ->
      case request.url do
        "https://gitlab.test/api/v4/projects/acme%2Fsymphony" ->
          ok(fixture!("project.json"))

        "https://gitlab.test/api/v4/user" ->
          ok(fixture!("user.json"))

        "https://gitlab.test/api/v4/personal_access_tokens/self" ->
          ok(fixture!("personal_access_token.json"))

        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues" ->
          assert Keyword.fetch!(request.params, :state) == "all"
          assert Keyword.fetch!(request.params, :per_page) == 1
          ok([fixture!("issue_1.json")])
      end
    end

    contract(:health_check, handler)
  end

  def tracker_contract_case(:fetch_eligible) do
    handler = fn request ->
      assert Keyword.fetch!(request.params, :state) == "opened"

      {:ok,
       %{
         status: 200,
         headers: %{"x-next-page" => ""},
         body: [fixture!("issue_1.json"), fixture!("issue_3.json")]
       }}
    end

    contract(:fetch_eligible, handler)
    |> Map.merge(%{
      criteria: %{"states" => ["open"], "required_labels" => ["ready-for-agent"]},
      expected_ids: ["1", "3"]
    })
  end

  def tracker_contract_case(:fetch_by_ids) do
    handler = fn request ->
      case request.url do
        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/1" -> ok(fixture!("issue_1.json"))
        "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3" -> ok(fixture!("issue_3.json"))
      end
    end

    contract(:fetch_by_ids, handler)
    |> Map.merge(%{issue_ids: ["3", "1"], expected_ids: ["3", "1"]})
  end

  def tracker_contract_case(:normalize_webhook) do
    signing_key = "gitlab-contract-webhook-key"
    Broker.put_secret(@webhook_secret_ref, "whsec_" <> Base.encode64(signing_key))
    body = fixture!("webhook_issue_closed.json") |> Jason.encode!()

    %{
      config: config(),
      request: signed_webhook(body, signing_key, "contract-terminal", 1_000),
      expected_issue_id: "3",
      credential_ref: @webhook_secret_ref,
      credential_purpose: :tracker_normalize_webhook,
      opts: tracker_opts(credential_broker: Broker, now: 1_000)
    }
  end

  def tracker_contract_case(:transition_issue) do
    handler = fn request ->
      assert request.url == "https://gitlab.test/api/v4/projects/acme%2Fsymphony/issues/3"
      assert request.body == %{state_event: "close"}
      ok(fixture!("issue_3.json") |> Map.put("state", "closed"))
    end

    contract(:transition_issue, handler)
    |> Map.merge(%{issue_id: "3", target_state: :closed, expected_state: "closed"})
  end

  def tracker_contract_case(:upsert_progress), do: comment_contract(:upsert_progress)
  def tracker_contract_case(:append_final_summary), do: comment_contract(:append_final_summary)

  defp comment_contract(operation) do
    {:ok, state} = Agent.start_link(fn -> %{notes: [], next_id: 70} end)

    handler = fn request ->
      Agent.get_and_update(state, &comment_state_transition(&1, request))
    end

    contract(operation, handler)
    |> Map.merge(%{
      issue_id: "3",
      first_text: "plan revision 1",
      second_text: "plan revision 2"
    })
  end

  defp comment_state_transition(current, %{method: :get}) do
    {ok(current.notes), current}
  end

  defp comment_state_transition(current, %{method: :post} = request) do
    note_id = current.next_id

    note = %{
      "id" => note_id,
      "body" => request.body.body,
      "author" => %{"id" => 42, "username" => "symphony-bot"}
    }

    {ok(%{"id" => note_id}), %{current | notes: [note | current.notes], next_id: note_id + 1}}
  end

  defp comment_state_transition(current, %{method: :put} = request) do
    note_id = request.url |> String.split("/") |> List.last() |> String.to_integer()
    notes = Enum.map(current.notes, &put_note_body(&1, note_id, request.body.body))

    {ok(%{"id" => note_id}), %{current | notes: notes}}
  end

  defp put_note_body(%{"id" => id} = note, note_id, body) when id == note_id,
    do: Map.put(note, "body", body)

  defp put_note_body(note, _note_id, _body), do: note

  defp contract(operation, handler) do
    Broker.put_secret(@credential_ref, "gitlab-contract-api-secret")

    %{
      config: config(),
      credential_ref: @credential_ref,
      credential_purpose: credential_purpose(operation),
      opts:
        tracker_opts(
          credential_broker: Broker,
          transport: {Transport, handler: handler}
        )
    }
  end

  defp credential_purpose(:health_check), do: :tracker_health_check
  defp credential_purpose(:fetch_eligible), do: :tracker_fetch_eligible
  defp credential_purpose(:fetch_by_ids), do: :tracker_fetch_by_ids
  defp credential_purpose(:transition_issue), do: :tracker_transition_issue
  defp credential_purpose(:upsert_progress), do: :tracker_upsert_progress
  defp credential_purpose(:append_final_summary), do: :tracker_append_final_summary

  defp config do
    %{
      "provider" => "gitlab",
      "credential_ref" => @credential_ref,
      "settings" => %{
        "endpoint" => "https://gitlab.test/api/v4",
        "bot_actor_id" => "42",
        "project_id" => "acme/symphony",
        "webhook_secret_ref" => @webhook_secret_ref
      }
    }
  end

  defp tracker_opts(opts) do
    Keyword.merge(
      [
        endpoint_trusted_origins: ["https://gitlab.test"],
        endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
      ],
      opts
    )
  end

  defp signed_webhook(body, signing_key, webhook_id, timestamp) do
    signed = "#{webhook_id}.#{timestamp}.#{body}"
    signature = :crypto.mac(:hmac, :sha256, signing_key, signed) |> Base.encode64()

    %{
      headers: %{
        "webhook-id" => webhook_id,
        "webhook-timestamp" => to_string(timestamp),
        "webhook-signature" => "v1,#{signature}"
      },
      body: body
    }
  end

  defp ok(body), do: {:ok, %{status: 200, headers: %{"x-next-page" => ""}, body: body}}

  defp fixture!(name) do
    __DIR__
    |> Path.join("../fixtures/trackers/gitlab/#{name}")
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
  end
end
