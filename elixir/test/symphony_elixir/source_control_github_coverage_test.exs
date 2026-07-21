defmodule SymphonyElixir.SourceControlGitHubCoverageTest.QueueTransport do
  @moduledoc false

  @sha String.duplicate("a", 40)
  @desired_sha String.duplicate("b", 40)

  def start_link(responses) do
    Agent.start_link(fn -> %{responses: responses, requests: [], failures: []} end)
  end

  def request(request, agent) do
    Agent.get_and_update(agent, fn state ->
      {result, remaining, failures} = take_response(state, request)

      {result,
       %{
         state
         | responses: remaining,
           requests: state.requests ++ [request],
           failures: state.failures ++ failures
       }}
    end)
  end

  def requests(agent), do: Agent.get(agent, & &1.requests)

  def audit(agent) do
    Agent.get(agent, fn state ->
      %{remaining: length(state.responses), failures: state.failures}
    end)
  end

  defp take_response(%{responses: []}, request) do
    {{:error, :queue_exhausted}, [], ["unexpected request after queue exhaustion: #{inspect(request)}"]}
  end

  defp take_response(%{responses: [response | rest], requests: requests}, request) do
    result =
      case response do
        fun when is_function(fun, 2) -> fun.(request, requests)
        fixed -> fixed
      end

    failures =
      case validate_request(request) do
        :ok -> []
        {:error, reason} -> [reason]
      end

    {result, rest, failures}
  end

  defp validate_request(%{method: :get, path: path} = request) do
    cond do
      path == "/repos/acme/widget/pulls" ->
        validate_query(request, %{"state" => "all", "per_page" => 100, "page" => request.query["page"]})

      Regex.match?(~r{/repos/acme/widget/issues/\d+/comments\z}, path) ->
        validate_query(request, %{"per_page" => 100, "page" => request.query["page"]})

      String.ends_with?(path, "/check-runs") ->
        validate_query(request, %{"filter" => "latest", "per_page" => 100})

      String.ends_with?(path, "/statuses") ->
        validate_query(request, %{"per_page" => 100})

      valid_read_path?(path) ->
        validate_query(request, nil)

      true ->
        {:error, "unexpected GitHub GET path: #{path}"}
    end
  end

  defp validate_request(%{method: :post, path: "/repos/acme/widget/git/refs"} = request) do
    case request.json do
      %{"ref" => "refs/heads/topic", "sha" => @sha} ->
        validate_query(request, nil)

      json ->
        {:error, "unexpected branch-create JSON: #{inspect(json)}"}
    end
  end

  defp validate_request(%{method: :post, path: "/repos/acme/widget/pulls"} = request) do
    case request.json do
      %{
        "title" => "Deliver topic",
        "head" => "topic",
        "base" => "main",
        "body" => body,
        "draft" => true
      } ->
        if String.starts_with?(body, "Acceptance evidence") and
             String.contains?(body, "<!-- symphony:") do
          validate_query(request, nil)
        else
          {:error, "pull-create body lacks stable operation marker: #{inspect(body)}"}
        end

      json ->
        {:error, "unexpected pull-create JSON: #{inspect(json)}"}
    end
  end

  defp validate_request(%{method: :post, path: "/graphql"} = request) do
    case request.json do
      %{
        "query" => query,
        "variables" => %{
          "input" => %{"pullRequestId" => pull_request_id, "clientMutationId" => operation_id}
        }
      }
      when is_binary(query) and is_binary(pull_request_id) and is_binary(operation_id) ->
        if pull_request_id == "PR_node_1" and
             (String.contains?(query, "markPullRequestReadyForReview") or
                String.contains?(query, "convertPullRequestToDraft")) do
          validate_query(request, nil)
        else
          {:error, "unexpected GraphQL mutation identity: #{inspect(request.json)}"}
        end

      json ->
        {:error, "unexpected GraphQL JSON: #{inspect(json)}"}
    end
  end

  defp validate_request(%{method: :post, path: path} = request) do
    if Regex.match?(~r{/repos/acme/widget/issues/\d+/comments\z}, path) and
         match?(%{"body" => "ship it" <> _marker}, request.json) and
         String.contains?(request.json["body"], "<!-- symphony:") do
      validate_query(request, nil)
    else
      {:error, "unexpected GitHub POST request: #{path} #{inspect(request.json)}"}
    end
  end

  defp validate_request(%{method: :patch, path: path} = request) do
    if Regex.match?(~r{/repos/acme/widget/pulls/\d+\z}, path) and
         request.json == %{"state" => "closed"} do
      validate_query(request, nil)
    else
      {:error, "unexpected GitHub PATCH request: #{path} #{inspect(request.json)}"}
    end
  end

  defp validate_request(%{method: :git_push, path: "refs/heads/" <> branch} = request)
       when byte_size(branch) > 0 do
    if branch == "topic" and request.branch == branch and
         request.desired_commit_sha == @desired_sha and request.expected_remote_sha == @sha do
      validate_query(request, nil)
    else
      {:error, "unexpected Git push payload: #{inspect(request)}"}
    end
  end

  defp validate_request(request), do: {:error, "unexpected GitHub request: #{inspect(request)}"}

  defp validate_query(request, expected) do
    query = Map.get(request, :query)
    json = Map.get(request, :json)
    authorization = get_in(request, [:headers, "authorization"])

    cond do
      query != expected -> {:error, "unexpected query for #{request.path}: #{inspect(query)}"}
      not is_nil(json) and request.method == :get -> {:error, "GET carried JSON for #{request.path}"}
      authorization != "Bearer github-secret-value" -> {:error, "missing GitHub authorization"}
      true -> :ok
    end
  end

  defp valid_read_path?(path) do
    path == "/repos/acme/widget" or
      Regex.match?(~r{/repos/acme/widget/(?:branches|rules/branches)/[^/]+\z}, path) or
      Regex.match?(~r{/repos/acme/widget/git/ref/heads/[^/]+\z}, path) or
      Regex.match?(~r{/repos/acme/widget/pulls/\d+(?:/merge)?\z}, path) or
      Regex.match?(~r{/repos/acme/widget/branches/[^/]+/protection/required_status_checks\z}, path)
  end
end

defmodule SymphonyElixir.SourceControlGitHubCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.{ChangeRequest, GitHub}
  alias SymphonyElixir.SourceControlGitHubCoverageTest.QueueTransport

  @sha String.duplicate("a", 40)
  @desired_sha String.duplicate("b", 40)

  test "public callbacks reject malformed provider input without mutating GitHub" do
    assert {:error, :invalid_configuration} =
             SourceControl.resolve_baseline(config([]), "")

    assert {:error, :invalid_configuration} =
             SourceControl.ensure_remote_branch(
               config([]),
               %{name: "", commit_sha: @sha},
               operation(:invalid_branch)
             )

    assert {:error, :invalid_configuration} =
             SourceControl.push_branch(
               config([]),
               "topic",
               "not-a-sha",
               operation(:invalid_push, expected_remote_sha: @sha)
             )

    assert {:error, :invalid_configuration} =
             SourceControl.ensure_change_request(
               %{repo: config([]), head: "topic", base: "main", title: "", body: "", draft: true},
               operation(:invalid_change_request)
             )

    assert {:error, :invalid_configuration} =
             SourceControl.set_draft(config([]), change_request(), operation(:invalid_draft))

    assert {:error, :invalid_configuration} =
             SourceControl.close_or_comment(
               config([]),
               %{change_request() | repository: "other/repo"},
               operation(:wrong_repository, action: :close)
             )

    assert {:error, :provider_failure} =
             SourceControl.state(config([]), %{change_request() | repository: "other/repo"})

    invalid_repository = put_in(config([]), [:settings, :repository], "too/many/segments")
    assert {:error, :invalid_configuration} = SourceControl.health_check(invalid_repository)
  end

  test "provider callbacks reject invalid states the facade makes unreachable" do
    assert {:error, :invalid_configuration} =
             GitHub.ensure_change_request(%{repo: :not_a_configuration},
               operation_id: "invalid-repo",
               dedupe_key: "invalid-repo"
             )

    assert {:error, :invalid_configuration} =
             GitHub.set_draft(config([]), change_request(),
               operation_id: "invalid-draft",
               dedupe_key: "invalid-draft"
             )

    assert {:error, :invalid_configuration} =
             GitHub.close_or_comment(config([]), change_request(),
               operation_id: "invalid-action",
               dedupe_key: "invalid-action",
               action: :merge
             )

    assert {:error, :invalid_configuration} =
             GitHub.close_or_comment(config([]), change_request(),
               operation_id: "empty-comment",
               dedupe_key: "empty-comment",
               action: :comment,
               body: ""
             )
  end

  test "health rejects malformed observations and denied or unknown write permissions" do
    malformed =
      config([
        ok(200, %{"permissions" => %{"push" => true}}, %{"x-oauth-scopes" => "repo"}),
        ok(200, %{"commit" => %{}}),
        ok(200, [])
      ])

    assert {:error, :invalid_configuration} = SourceControl.health_check(malformed)

    denied =
      config([
        ok(200, %{"permissions" => %{"push" => false}}),
        ok(200, %{"commit" => %{"sha" => @sha}}),
        ok(404, %{})
      ])

    assert {:error, :forbidden} = SourceControl.health_check(denied)

    unknown =
      config([
        ok(200, %{"permissions" => %{}}),
        ok(200, %{"commit" => %{"sha" => @sha}}),
        ok(200, [])
      ])

    assert {:error, :forbidden} = SourceControl.health_check(unknown)
  end

  test "health accepts repo oauth scope for change request writes" do
    config =
      config([
        ok(200, %{"permissions" => %{"push" => true}}, %{"x-oauth-scopes" => "repo"}),
        ok(200, %{"commit" => %{"sha" => @sha}}),
        ok(404, %{})
      ])

    assert {:ok, health} = SourceControl.health_check(config)
    assert health.permissions.change_request_write == :allowed
  end

  test "branch reads preserve authentication, transport, conflict, and malformed-body failures" do
    assert {:error, :unauthorized} =
             SourceControl.ensure_remote_branch(
               config([ok(401, %{})]),
               branch(),
               operation(:branch_unauthorized)
             )

    assert {:error, :transport_failure} =
             SourceControl.ensure_remote_branch(
               config([{:error, :closed}]),
               branch(),
               operation(:branch_transport)
             )

    assert {:error, :conflict} =
             SourceControl.ensure_remote_branch(
               config([ok(200, branch_body(@desired_sha))]),
               branch(),
               operation(:branch_conflict)
             )

    assert {:error, :provider_failure} =
             SourceControl.ensure_remote_branch(
               config([ok(200, %{"object" => %{}})]),
               branch(),
               operation(:branch_malformed)
             )
  end

  test "branch creation reconciles provider races and unknown mutation outcomes" do
    assert {:ok, reconciled} =
             SourceControl.ensure_remote_branch(
               config([ok(404, %{}), ok(409, %{}), ok(200, branch_body(@sha))]),
               branch(),
               operation(:branch_race)
             )

    assert reconciled.disposition == :reconciled
    assert reconciled.repository == "acme/widget"
    assert reconciled.name == "topic"
    assert reconciled.commit_sha == @sha
    assert reconciled.remote_ref == "refs/heads/topic"

    assert {:ok, reconciled_after_error} =
             SourceControl.ensure_remote_branch(
               config([ok(404, %{}), {:error, :timeout}, ok(200, branch_body(@sha))]),
               branch(),
               operation(:branch_transport_reconcile)
             )

    assert reconciled_after_error.disposition == :reconciled
    assert reconciled_after_error.name == "topic"
    assert reconciled_after_error.commit_sha == @sha

    assert {:error, :unknown_outcome} =
             SourceControl.ensure_remote_branch(
               config([ok(404, %{}), ok(422, %{}), ok(404, %{})]),
               branch(),
               operation(:branch_unknown)
             )
  end

  test "branch creation maps unexpected provider responses" do
    for {status, expected} <- [
          {403, :forbidden},
          {404, :not_found},
          {418, :provider_failure}
        ] do
      assert {:error, ^expected} =
               SourceControl.ensure_remote_branch(
                 config([ok(404, %{}), ok(status, %{})]),
                 branch(),
                 operation({:branch_response, status})
               )
    end
  end

  test "push reconciliation distinguishes transport failure, conflict, corruption, and uncertainty" do
    assert {:error, :transport_failure} =
             SourceControl.push_branch(
               config([{:error, :push_failed}, ok(200, branch_body(@sha))]),
               "topic",
               @desired_sha,
               operation(:push_failed, expected_remote_sha: @sha)
             )

    assert {:error, :conflict} =
             SourceControl.push_branch(
               config([:ok, ok(200, branch_body(String.duplicate("c", 40)))]),
               "topic",
               @desired_sha,
               operation(:push_conflict, expected_remote_sha: @sha)
             )

    assert {:error, :provider_failure} =
             SourceControl.push_branch(
               config([:ok, ok(200, %{"object" => %{}})]),
               "topic",
               @desired_sha,
               operation(:push_malformed, expected_remote_sha: @sha)
             )

    assert {:error, :unknown_outcome} =
             SourceControl.push_branch(
               config([:ok, {:error, :read_failed}]),
               "topic",
               @desired_sha,
               operation(:push_unknown, expected_remote_sha: @sha)
             )
  end

  test "change request creation reconciles duplicate races and failed replies by marker" do
    marker_response = fn _request, requests ->
      body = mutation_body(requests, "/repos/acme/widget/pulls")
      ok(200, [pull(%{"body" => body})])
    end

    for {mutation_response, suffix} <- [{ok(409, %{}), :conflict}, {{:error, :timeout}, :error}] do
      assert {:ok, reconciled} =
               SourceControl.ensure_change_request(
                 change_request_attrs(config([ok(200, []), mutation_response, marker_response])),
                 operation({:create_change_request, suffix})
               )

      assert reconciled.disposition == :reconciled
      assert reconciled.external_id == "1001"
      assert reconciled.number == 1
      assert reconciled.head_branch == "topic"
      assert reconciled.base_branch == "main"
      assert reconciled.draft?
    end
  end

  test "change request reconciliation reports unknown and transport outcomes" do
    assert {:error, :unknown_outcome} =
             SourceControl.ensure_change_request(
               change_request_attrs(config([ok(200, []), ok(500, %{}), ok(200, [])])),
               operation(:change_request_unknown)
             )

    assert {:error, :transport_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config([ok(200, []), ok(422, %{}), {:error, :closed}])),
               operation(:change_request_reconcile_error)
             )

    assert {:error, :provider_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config([ok(200, []), ok(418, %{})])),
               operation(:change_request_unexpected)
             )
  end

  test "change request listing rejects transport and malformed collection responses" do
    assert {:error, :transport_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config([{:error, :closed}])),
               operation(:change_request_list_transport)
             )

    assert {:error, :provider_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config([ok(200, %{"not" => "a list"})])),
               operation(:change_request_list_malformed)
             )
  end

  test "change request pagination has a hard provider-safety limit" do
    pages =
      List.duplicate(
        ok(200, [], %{"link" => ~s(<https://api.github.test/pulls?page=2>; rel="next")}),
        20
      )

    transport = start_transport(pages)

    assert {:error, :provider_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(transport)),
               operation(:change_request_page_limit)
             )

    requests = QueueTransport.requests(transport)
    assert length(requests) == 20
    assert Enum.all?(requests, &(&1.method == :get and &1.path == "/repos/acme/widget/pulls"))
    assert Enum.map(requests, & &1.query["page"]) == [1 | List.duplicate(2, 19)]
  end

  test "already-correct draft state reconciles without GraphQL" do
    transport = start_transport([ok(200, pull(%{"draft" => true}))])

    assert {:ok, reconciled} =
             SourceControl.set_draft(config(transport), change_request(%{draft?: true}),
               operation_id: "draft-already",
               dedupe_key: "draft-already",
               draft: true
             )

    assert reconciled.disposition == :reconciled
    assert reconciled.number == 1
    assert reconciled.head_branch == "topic"
    assert reconciled.base_branch == "main"
    assert reconciled.draft?
    assert Enum.map(QueueTransport.requests(transport), & &1.method) == [:get]
  end

  test "state tolerates irrelevant rules and reports closed checking changes" do
    observed = pull(%{"state" => "closed", "mergeable" => nil})
    assert {:ok, state} = SourceControl.state(config(state_responses(observed)), change_request())
    assert state.status == :closed
    assert state.mergeability == :checking
    assert state.required_checks == []
    assert state.checks_status == :passed
  end

  test "state preserves every non-merged GitHub mergeability observation" do
    cases = [
      {%{"mergeable" => false, "mergeable_state" => "dirty"}, :conflicting},
      {%{"mergeable" => false, "mergeable_state" => "clean"}, :blocked},
      {%{"mergeable" => true, "mergeable_state" => "blocked"}, :blocked},
      {%{"mergeable" => "unknown", "mergeable_state" => "unknown"}, :unknown}
    ]

    for {overrides, expected} <- cases do
      assert {:ok, state} =
               SourceControl.state(config(state_responses(pull(overrides))), change_request())

      assert state.mergeability == expected
    end
  end

  test "required checks bind apps and keep newest status evidence" do
    rules = [
      %{
        "type" => "required_status_checks",
        "parameters" => %{
          "required_status_checks" => [
            %{"context" => "queued"},
            %{"context" => "unknown-check"},
            %{"context" => "unknown-status"},
            %{"context" => "missing-app", "integration_id" => 42},
            %{"context" => "no-app", "integration_id" => 100},
            %{"context" => "matched-app", "integration_id" => 7},
            %{"context" => "newest-status"}
          ]
        }
      }
    ]

    checks = %{
      "check_runs" => [
        %{"name" => "queued", "status" => "queued", "details_url" => "https://checks/queued"},
        %{"name" => "unknown-check", "conclusion" => nil, "details_url" => "https://checks/unknown"},
        %{
          "name" => "missing-app",
          "conclusion" => "success",
          "details_url" => "https://checks/wrong-app",
          "app" => %{"id" => 99}
        },
        %{
          "name" => "matched-app",
          "conclusion" => "success",
          "details_url" => "https://checks/right-app",
          "app" => %{"id" => 7}
        },
        %{
          "name" => "no-app",
          "conclusion" => "success",
          "details_url" => "https://checks/no-app"
        }
      ]
    }

    statuses = [
      %{"context" => "unknown-status", "state" => "mystery", "target_url" => "https://status/unknown"},
      %{"context" => "newest-status", "state" => "failure", "target_url" => "https://status/newest"},
      %{"context" => "newest-status", "state" => "success", "target_url" => "https://status/older"}
    ]

    responses = state_responses(pull(), rules, checks, statuses)
    assert {:ok, state} = SourceControl.state(config(responses), change_request())

    assert Enum.find(state.required_checks, &(&1.name == "queued")).status == :pending
    assert Enum.find(state.required_checks, &(&1.name == "unknown-check")).status == :unknown
    assert Enum.find(state.required_checks, &(&1.name == "unknown-status")).status == :unknown

    assert %{status: :pending, url: nil} =
             Enum.find(state.required_checks, &(&1.name == "missing-app"))

    assert %{status: :pending, url: nil} =
             Enum.find(state.required_checks, &(&1.name == "no-app"))

    assert %{status: :passed, url: "https://checks/right-app"} =
             Enum.find(state.required_checks, &(&1.name == "matched-app"))

    assert %{status: :failed, url: "https://status/newest"} =
             Enum.find(state.required_checks, &(&1.name == "newest-status"))

    assert state.checks_status == :failed
  end

  test "required checks report passed only when every required check passes" do
    rules = required_rules([%{"context" => "ci"}])
    checks = %{"check_runs" => [%{"name" => "ci", "conclusion" => "success"}]}

    assert {:ok, state} =
             SourceControl.state(
               config(state_responses(pull(), rules, checks, [])),
               change_request()
             )

    assert state.checks_status == :passed
  end

  test "empty rulesets fall back to classic protection before evaluating checks" do
    responses = [
      ok(200, pull()),
      ok(404, %{}),
      ok(200, []),
      ok(200, %{"checks" => [%{"context" => "classic", "app_id" => 7}], "contexts" => []}),
      ok(200, %{
        "check_runs" => [
          %{"name" => "classic", "conclusion" => "success", "app" => %{"id" => 7}}
        ]
      }),
      ok(200, [])
    ]

    transport = start_transport(responses)

    assert {:ok, state} = SourceControl.state(config(transport), change_request())
    assert state.required_checks == [%{name: "classic", status: :passed, url: nil}]
    assert state.checks_status == :passed

    assert Enum.map(QueueTransport.requests(transport), & &1.path) == [
             "/repos/acme/widget/pulls/1",
             "/repos/acme/widget/pulls/1/merge",
             "/repos/acme/widget/rules/branches/main",
             "/repos/acme/widget/branches/main/protection/required_status_checks",
             "/repos/acme/widget/commits/#{@sha}/check-runs",
             "/repos/acme/widget/commits/#{@sha}/statuses"
           ]
  end

  test "missing rulesets and missing classic protection legitimately mean no checks" do
    responses = [
      ok(200, pull()),
      ok(404, %{}),
      ok(404, %{}),
      ok(404, %{}),
      ok(200, %{"check_runs" => []}),
      ok(200, [])
    ]

    assert {:ok, state} = SourceControl.state(config(responses), change_request())
    assert state.required_checks == []
    assert state.checks_status == :passed

    empty_protection = [
      ok(200, pull()),
      ok(404, %{}),
      ok(200, []),
      ok(200, %{"checks" => [], "contexts" => []}),
      ok(200, %{"check_runs" => []}),
      ok(200, [])
    ]

    assert {:ok, empty_state} = SourceControl.state(config(empty_protection), change_request())
    assert empty_state.required_checks == []
    assert empty_state.checks_status == :passed
  end

  test "state preserves rule and protection endpoint failures" do
    assert {:error, :unauthorized} =
             SourceControl.state(
               config([ok(200, pull()), ok(404, %{}), ok(401, %{})]),
               change_request()
             )

    assert {:error, :transport_failure} =
             SourceControl.state(
               config([ok(200, pull()), ok(404, %{}), {:error, :closed}]),
               change_request()
             )

    prefix = [ok(200, pull()), ok(404, %{}), ok(200, [])]

    assert {:error, :provider_failure} =
             SourceControl.state(config(prefix ++ [ok(418, %{})]), change_request())

    assert {:error, :transport_failure} =
             SourceControl.state(config(prefix ++ [{:error, :closed}]), change_request())
  end

  test "state fails closed on malformed configured required rules" do
    malformed_rules = [
      %{"unexpected" => true},
      ["not-a-rule"],
      [%{"type" => "required_status_checks"}],
      [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => "ci"}}],
      required_rules([%{"context" => ""}]),
      required_rules([%{"context" => "ci", "integration_id" => "bad"}]),
      required_rules([%{"missing" => "context"}])
    ]

    for rules <- malformed_rules do
      assert {:error, :provider_failure} =
               SourceControl.state(
                 config(state_responses(pull(), rules, %{"check_runs" => []}, [])),
                 change_request()
               )
    end
  end

  test "state fails closed on malformed check-run and commit-status payloads" do
    for checks <- [
          [],
          %{},
          %{"check_runs" => "not-a-list"},
          %{"check_runs" => [%{}]},
          %{"check_runs" => [%{"name" => "ci", "app" => %{"id" => "bad"}}]}
        ] do
      assert {:error, :provider_failure} =
               SourceControl.state(
                 config(state_responses(pull(), [%{"type" => "informational"}], checks, [])),
                 change_request()
               )
    end

    for statuses <- [%{}, ["not-a-status"], [%{"state" => "success"}], [%{"context" => ""}]] do
      assert {:error, :provider_failure} =
               SourceControl.state(
                 config(
                   state_responses(
                     pull(),
                     [%{"type" => "informational"}],
                     %{"check_runs" => []},
                     statuses
                   )
                 ),
                 change_request()
               )
    end
  end

  test "state fails closed on malformed classic protection payloads" do
    malformed_protection = [
      %{"checks" => "not-a-list"},
      %{"contexts" => "not-a-list"},
      %{"checks" => [%{}]},
      %{"checks" => [%{"context" => "ci", "app_id" => "bad"}]},
      %{"contexts" => [""]}
    ]

    for protection <- malformed_protection do
      assert {:error, :provider_failure} =
               SourceControl.state(
                 config([ok(200, pull()), ok(404, %{}), ok(200, []), ok(200, protection)]),
                 change_request()
               )
    end
  end

  test "state preserves malformed endpoint and transport failures" do
    assert {:error, :provider_failure} =
             SourceControl.state(
               config([ok(200, pull()), ok(500, %{})]),
               change_request()
             )

    assert {:error, :transport_failure} =
             SourceControl.state(
               config([{:error, :closed}]),
               change_request()
             )
  end

  test "draft mutation reconciles provider ambiguity without retrying GraphQL" do
    before = pull(%{"draft" => true})
    ready = pull(%{"draft" => false})

    assert {:ok, reconciled} =
             SourceControl.set_draft(
               config([ok(200, before), {:error, :timeout}, ok(200, ready)]),
               change_request(%{draft?: true}),
               operation(:draft_reconciled, draft: false)
             )

    assert reconciled.disposition == :reconciled
    refute reconciled.draft?
    assert reconciled.number == 1
    assert reconciled.head_branch == "topic"
    assert reconciled.base_branch == "main"

    assert {:error, :provider_failure} =
             SourceControl.set_draft(
               config([ok(200, before), graphql_ready(), ok(200, before)]),
               change_request(%{draft?: true}),
               operation(:draft_provider_failure, draft: false)
             )

    assert {:error, :transport_failure} =
             SourceControl.set_draft(
               config([ok(200, before), {:error, :timeout}, ok(200, before)]),
               change_request(%{draft?: true}),
               operation(:draft_transport_failure, draft: false)
             )
  end

  test "close observes already-merged and already-closed requests" do
    for observed <- [
          pull(%{"merged" => true}),
          pull(%{"merged" => false, "merged_at" => "2026-07-20T00:00:00Z"}),
          pull(%{"state" => "closed"})
        ] do
      assert {:ok, %{action: :already_applied}} =
               SourceControl.close_or_comment(
                 config([ok(200, observed)]),
                 change_request(),
                 operation({:close_observed, observed["state"]}, action: :close)
               )
    end
  end

  test "close reconciles successful and ambiguous REST mutations" do
    open = pull(%{"state" => "open"})
    closed = pull(%{"state" => "closed"})

    assert {:ok, %{action: :closed}} =
             SourceControl.close_or_comment(
               config([ok(200, open), ok(200, closed), ok(200, closed)]),
               change_request(),
               operation(:close_success, action: :close)
             )

    assert {:ok, %{action: :already_applied}} =
             SourceControl.close_or_comment(
               config([ok(200, open), {:error, :timeout}, ok(200, closed)]),
               change_request(),
               operation(:close_reconciled, action: :close)
             )

    assert {:error, :provider_failure} =
             SourceControl.close_or_comment(
               config([ok(200, open), ok(200, open), ok(200, open)]),
               change_request(),
               operation(:close_provider_failure, action: :close)
             )

    assert {:error, :transport_failure} =
             SourceControl.close_or_comment(
               config([ok(200, open), {:error, :timeout}, ok(200, open)]),
               change_request(),
               operation(:close_transport_failure, action: :close)
             )

    assert {:error, :unknown_outcome} =
             SourceControl.close_or_comment(
               config([ok(200, open), ok(200, open), {:error, :closed}]),
               change_request(),
               operation(:close_unknown, action: :close)
             )
  end

  test "comment replay returns the original comment without a second mutation" do
    replay = fn _request, requests ->
      ok(200, [%{"id" => 44, "body" => mutation_body(requests, "/comments")}])
    end

    transport = start_transport([ok(200, []), ok(201, %{"id" => 44}), replay])

    opts = operation(:comment_replay, action: :comment, body: "ship it")

    assert {:ok, %{action: :commented}} =
             SourceControl.close_or_comment(config(transport), change_request(), opts)

    assert {:ok, %{action: :already_applied, external_id: "44"}} =
             SourceControl.close_or_comment(config(transport), change_request(), opts)

    assert Enum.count(QueueTransport.requests(transport), &(&1.method == :post)) == 1
  end

  test "comment mutations reconcile conflicts and transport failures by marker" do
    marker_response = fn _request, requests ->
      ok(200, [%{"id" => 55, "body" => mutation_body(requests, "/comments")}])
    end

    for {mutation_response, suffix} <- [{ok(409, %{}), :conflict}, {{:error, :timeout}, :error}] do
      assert {:ok, %{action: :already_applied, external_id: "55"}} =
               SourceControl.close_or_comment(
                 config([ok(200, []), mutation_response, marker_response]),
                 change_request(),
                 operation({:comment_reconcile, suffix}, action: :comment, body: "ship it")
               )
    end
  end

  test "comment mutation and reconciliation failures remain distinguishable" do
    assert {:error, :provider_failure} =
             SourceControl.close_or_comment(
               config([ok(200, []), ok(418, %{})]),
               change_request(),
               operation(:comment_unexpected, action: :comment, body: "ship it")
             )

    assert {:error, :unknown_outcome} =
             SourceControl.close_or_comment(
               config([ok(200, []), {:error, :timeout}, ok(200, [])]),
               change_request(),
               operation(:comment_unknown, action: :comment, body: "ship it")
             )

    assert {:error, :transport_failure} =
             SourceControl.close_or_comment(
               config([ok(200, []), ok(409, %{}), {:error, :closed}]),
               change_request(),
               operation(:comment_reconcile_error, action: :comment, body: "ship it")
             )
  end

  test "comment listing paginates and enforces its hard safety limit" do
    next_page = ok(200, [], %{"link" => ~s(<https://api.github.test/comments?page=2>; rel="next")})

    assert {:ok, %{action: :commented}} =
             SourceControl.close_or_comment(
               config([next_page, ok(200, []), ok(201, %{"id" => 77})]),
               change_request(),
               operation(:comment_page, action: :comment, body: "ship it")
             )

    limit_transport = start_transport(List.duplicate(next_page, 20))

    assert {:error, :provider_failure} =
             SourceControl.close_or_comment(
               config(limit_transport),
               change_request(),
               operation(:comment_page_limit, action: :comment, body: "ship it")
             )

    requests = QueueTransport.requests(limit_transport)
    assert length(requests) == 20

    assert Enum.all?(requests, fn request ->
             request.method == :get and request.path == "/repos/acme/widget/issues/1/comments"
           end)

    assert Enum.map(requests, & &1.query["page"]) == [1 | List.duplicate(2, 19)]
  end

  test "comment listing rejects transport and malformed collection responses" do
    assert {:error, :transport_failure} =
             SourceControl.close_or_comment(
               config([{:error, :closed}]),
               change_request(),
               operation(:comment_list_transport, action: :comment, body: "ship it")
             )

    assert {:error, :provider_failure} =
             SourceControl.close_or_comment(
               config([ok(200, %{"not" => "comments"})]),
               change_request(),
               operation(:comment_list_malformed, action: :comment, body: "ship it")
             )
  end

  defp config(responses) when is_list(responses) do
    responses |> start_transport() |> config()
  end

  defp config(transport) when is_pid(transport) do
    %{
      provider: :github,
      credential_ref: "00000000-0000-0000-0000-000000000001",
      credential: "github-secret-value",
      settings: %{
        repository: "acme/widget",
        base_branch: "main",
        api_base_url: "https://api.github.test"
      },
      transport: {QueueTransport, transport}
    }
  end

  defp start_transport(responses) do
    {:ok, transport} = QueueTransport.start_link(responses)
    Process.unlink(transport)

    on_exit(fn ->
      assert Process.alive?(transport), "GitHub queue transport crashed"
      audit = QueueTransport.audit(transport)
      Agent.stop(transport)
      assert audit == %{remaining: 0, failures: []}, "GitHub queue audit failed: #{inspect(audit)}"
    end)

    transport
  end

  defp operation(name, extra \\ []) do
    id = name |> inspect() |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    [operation_id: "op-#{id}", dedupe_key: "dedupe-#{id}"] ++ extra
  end

  defp branch, do: %{name: "topic", commit_sha: @sha}
  defp branch_body(sha), do: %{"object" => %{"sha" => sha}}

  defp change_request(overrides \\ %{}) do
    struct!(
      ChangeRequest,
      Map.merge(
        %{
          provider: :github,
          external_id: "1001",
          number: 1,
          url: "https://github.test/acme/widget/pull/1",
          repository: "acme/widget",
          head_branch: "topic",
          base_branch: "main",
          title: "Deliver topic",
          draft?: true,
          disposition: :reconciled
        },
        overrides
      )
    )
  end

  defp change_request_attrs(repo) do
    %{
      repo: repo,
      head: "topic",
      base: "main",
      title: "Deliver topic",
      body: "Acceptance evidence",
      draft: true
    }
  end

  defp pull(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 1001,
        "node_id" => "PR_node_1",
        "number" => 1,
        "html_url" => "https://github.test/acme/widget/pull/1",
        "title" => "Deliver topic",
        "body" => "Acceptance evidence",
        "state" => "open",
        "draft" => true,
        "merged" => false,
        "merged_at" => nil,
        "mergeable" => true,
        "mergeable_state" => "clean",
        "merge_commit_sha" => nil,
        "head" => %{"ref" => "topic", "sha" => @sha},
        "base" => %{"ref" => "main", "sha" => @desired_sha}
      },
      overrides
    )
  end

  defp state_responses(observed, rules \\ [%{"type" => "informational"}], checks \\ %{"check_runs" => []}, statuses \\ []) do
    [ok(200, observed), ok(404, %{}), ok(200, rules), ok(200, checks), ok(200, statuses)]
  end

  defp required_rules(checks) do
    [
      %{
        "type" => "required_status_checks",
        "parameters" => %{"required_status_checks" => checks}
      }
    ]
  end

  defp graphql_ready do
    ok(200, %{
      "data" => %{
        "markPullRequestReadyForReview" => %{"pullRequest" => %{"isDraft" => false}}
      }
    })
  end

  defp mutation_body(requests, path_suffix) do
    requests
    |> Enum.reverse()
    |> Enum.find(fn request ->
      request.method == :post and String.ends_with?(request.path, path_suffix)
    end)
    |> get_in([:json, "body"])
  end

  defp ok(status, body, headers \\ %{}) do
    {:ok, %{status: status, headers: headers, body: body}}
  end
end
