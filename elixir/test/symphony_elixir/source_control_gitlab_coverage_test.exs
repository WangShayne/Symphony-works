defmodule SymphonyElixir.SourceControlGitLabCoverageTest.ScriptTransport do
  @moduledoc false

  @type response ::
          {atom(), String.t(), term()}
          | {atom(), String.t(), (map(), [map()] -> term())}

  @spec start_link([response()]) :: Agent.on_start()
  def start_link(responses) do
    Agent.start_link(fn -> %{responses: responses, requests: []} end)
  end

  @spec request(map(), pid()) :: term()
  def request(request, agent) do
    Agent.get_and_update(agent, fn state ->
      case state.responses do
        [{method, path, result} | remaining]
        when method == request.method and path == request.path ->
          reply = resolve_result(result, request, state.requests)

          {reply,
           %{
             state
             | responses: remaining,
               requests: state.requests ++ [request]
           }}

        [expected | _remaining] ->
          {{:error, {:unexpected_request, expected, request}}, %{state | requests: state.requests ++ [request]}}

        [] ->
          {{:error, {:unexpected_request, request}}, %{state | requests: state.requests ++ [request]}}
      end
    end)
  end

  @spec requests(pid()) :: [map()]
  def requests(agent), do: Agent.get(agent, & &1.requests)

  @spec remaining(pid()) :: [response()]
  def remaining(agent), do: Agent.get(agent, & &1.responses)

  defp resolve_result(result, request, requests) when is_function(result, 2),
    do: result.(request, requests)

  defp resolve_result(result, _request, _requests), do: result
end

defmodule SymphonyElixir.SourceControlGitLabCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.AdapterSupport
  alias SymphonyElixir.SourceControl.ChangeRequest
  alias SymphonyElixir.SourceControl.GitLab
  alias SymphonyElixir.SourceControl.Transport
  alias SymphonyElixir.SourceControlGitLabCoverageTest.ScriptTransport

  @sha String.duplicate("1", 40)
  @desired_sha String.duplicate("2", 40)
  @other_sha String.duplicate("3", 40)
  @operation_id "00000000-0000-0000-0000-000000000008"
  @dedupe_key "gitlab-coverage"
  @bot_actor_id "31337"

  test "public mutations reject invalid provider input before transport dispatch" do
    {:ok, transport} = ScriptTransport.start_link([])
    config = config(transport)
    opts = operation_opts()

    assert {:error, :invalid_configuration} =
             SourceControl.health_check(put_in(config, [:settings, :repository], nil))

    assert {:error, :invalid_configuration} = SourceControl.resolve_baseline(config, " ")

    assert {:error, :invalid_configuration} =
             SourceControl.ensure_remote_branch(config, %{name: " ", commit_sha: @sha}, opts)

    assert {:error, :invalid_configuration} =
             SourceControl.push_branch(
               config,
               "topic",
               "not-a-sha",
               Keyword.put(opts, :expected_remote_sha, @sha)
             )

    assert {:error, :invalid_configuration} =
             GitLab.ensure_change_request(%{repo: :invalid}, opts)

    assert {:error, :invalid_configuration} =
             GitLab.set_draft(config, change_request(repository: "other/repository"), Keyword.put(opts, :draft, true))

    assert {:error, :invalid_configuration} =
             GitLab.close_or_comment(config, change_request(), Keyword.put(opts, :action, :invalid))

    assert {:error, :invalid_configuration} =
             GitLab.close_or_comment(
               config,
               change_request(repository: "other/repository"),
               Keyword.put(opts, :action, :close)
             )

    missing_actor_config = update_in(config, [:settings], &Map.delete(&1, :bot_actor_id))

    assert {:error, :invalid_configuration} =
             GitLab.ensure_change_request(
               change_request_attrs(missing_actor_config),
               operation_opts()
             )

    assert {:error, :invalid_configuration} =
             GitLab.close_or_comment(
               missing_actor_config,
               change_request(),
               Keyword.merge(opts, action: :comment, body: "Review complete")
             )

    assert [] = ScriptTransport.requests(transport)
  end

  test "public operation seams propagate missing operation identity without transport dispatch" do
    {:ok, transport} = ScriptTransport.start_link([])
    config = config(transport)

    assert {:error, _reason} =
             SourceControl.ensure_remote_branch(config, %{name: "topic", commit_sha: @sha}, [])

    assert {:error, _reason} =
             SourceControl.push_branch(
               config,
               "topic",
               @desired_sha,
               expected_remote_sha: @sha
             )

    assert {:error, _reason} =
             SourceControl.ensure_change_request(change_request_attrs(config), [])

    assert {:error, _reason} =
             SourceControl.set_draft(config, change_request(), draft: false)

    assert {:error, _reason} =
             SourceControl.close_or_comment(config, change_request(), action: :close)

    assert [] = ScriptTransport.requests(transport)

    invalid_repository_config = put_in(config, [:settings, :repository], nil)

    assert {:error, :invalid_configuration} =
             SourceControl.ensure_remote_branch(
               invalid_repository_config,
               %{name: "topic", commit_sha: @sha},
               operation_opts()
             )

    assert {:error, :invalid_configuration} =
             SourceControl.push_branch(
               invalid_repository_config,
               "topic",
               @desired_sha,
               Keyword.put(operation_opts(), :expected_remote_sha, @sha)
             )

    assert {:error, :invalid_configuration} =
             SourceControl.set_draft(
               invalid_repository_config,
               change_request(),
               Keyword.put(operation_opts(), :draft, false)
             )

    assert {:error, :invalid_configuration} =
             SourceControl.close_or_comment(
               invalid_repository_config,
               change_request(),
               Keyword.put(operation_opts(), :action, :close)
             )
  end

  test "health and baseline reject malformed successful responses" do
    {:ok, health_transport} =
      ScriptTransport.start_link([
        get("/projects/acme%2Fwidget", 200, project()),
        get("/projects/acme%2Fwidget/repository/branches/main", 200, branch(@sha)),
        get("/projects/acme%2Fwidget/protected_branches/main", 201, %{}),
        get("/user", 200, gitlab_user())
      ])

    assert {:error, :invalid_configuration} = SourceControl.health_check(config(health_transport))

    {:ok, baseline_transport} =
      ScriptTransport.start_link([
        get("/projects/acme%2Fwidget/repository/branches/main", 200, %{"commit" => %{}})
      ])

    assert {:error, :invalid_configuration} =
             SourceControl.resolve_baseline(config(baseline_transport), "main")

    {:ok, failed_baseline} =
      ScriptTransport.start_link([
        {:get, "/projects/acme%2Fwidget/repository/branches/main", {:error, :timeout}}
      ])

    assert {:error, :transport_failure} =
             SourceControl.resolve_baseline(config(failed_baseline), "main")

    {:ok, failed_health} =
      ScriptTransport.start_link([
        {:get, "/projects/acme%2Fwidget", {:error, :timeout}}
      ])

    assert {:error, :transport_failure} = SourceControl.health_check(config(failed_health))
  end

  test "health verifies GitLab credential actor against the configured bot actor" do
    project_path = "/projects/acme%2Fwidget"
    branch_path = project_path <> "/repository/branches/main"
    protected_path = project_path <> "/protected_branches/main"

    matched =
      ScriptTransport.start_link([
        get(project_path, 200, project()),
        get(branch_path, 200, branch(@sha)),
        get(protected_path, 200, %{}),
        get("/user", 200, gitlab_user())
      ])

    assert {:ok, matched_transport} = matched
    assert {:ok, health} = SourceControl.health_check(config(matched_transport))
    assert health.credential_actor == %{id: @bot_actor_id, matched?: true}
    assert [] = ScriptTransport.remaining(matched_transport)

    {:ok, mismatch} =
      ScriptTransport.start_link([
        get(project_path, 200, project()),
        get(branch_path, 200, branch(@sha)),
        get(protected_path, 200, %{}),
        get("/user", 200, gitlab_user(999_999))
      ])

    assert {:error, :forbidden} = SourceControl.health_check(config(mismatch))
    assert [] = ScriptTransport.remaining(mismatch)

    {:ok, string_actor} =
      ScriptTransport.start_link([
        get(project_path, 200, project()),
        get(branch_path, 200, branch(@sha)),
        get(protected_path, 200, %{}),
        get("/user", 200, gitlab_user(@bot_actor_id))
      ])

    assert {:error, :invalid_configuration} = SourceControl.health_check(config(string_actor))
    assert [] = ScriptTransport.remaining(string_actor)

    {:ok, malformed} =
      ScriptTransport.start_link([
        get(project_path, 200, project()),
        get(branch_path, 200, branch(@sha)),
        get(protected_path, 200, %{}),
        get("/user", 200, %{"username" => "missing-id"})
      ])

    assert {:error, :invalid_configuration} = SourceControl.health_check(config(malformed))
    assert [] = ScriptTransport.remaining(malformed)

    {:ok, unused} = ScriptTransport.start_link([])

    assert {:error, :invalid_configuration} =
             SourceControl.health_check(update_in(config(unused), [:settings], &Map.delete(&1, :bot_actor_id)))

    assert [] = ScriptTransport.requests(unused)
  end

  test "branch lookup propagates provider and transport failures" do
    path = "/projects/acme%2Fwidget/repository/branches/topic"
    branch_input = %{name: "topic", commit_sha: @sha}

    {:ok, unauthorized} = ScriptTransport.start_link([get(path, 401, %{})])

    unauthorized_result =
      SourceControl.ensure_remote_branch(config(unauthorized), branch_input, operation_opts())

    assert match?({:error, :unauthorized}, unauthorized_result),
           inspect(%{branch: branch_input, requests: ScriptTransport.requests(unauthorized)})

    {:ok, failed} = ScriptTransport.start_link([{:get, path, {:error, :timeout}}])

    assert {:error, :transport_failure} =
             SourceControl.ensure_remote_branch(config(failed), branch_input, operation_opts())
  end

  test "branch creation reconciles ambiguous mutations and detects conflicts" do
    path = "/projects/acme%2Fwidget/repository/branches/topic"
    create_path = "/projects/acme%2Fwidget/repository/branches"
    branch_input = %{name: "topic", commit_sha: @sha}

    {:ok, conflict_then_found} =
      ScriptTransport.start_link([
        get(path, 404, %{}),
        post(create_path, 409, %{}),
        get(path, 200, branch(@sha))
      ])

    assert {:ok, %{disposition: :reconciled, commit_sha: @sha}} =
             SourceControl.ensure_remote_branch(
               config(conflict_then_found),
               branch_input,
               operation_opts()
             )

    {:ok, timeout_then_found} =
      ScriptTransport.start_link([
        get(path, 404, %{}),
        {:post, create_path, {:error, :timeout}},
        get(path, 200, branch(@sha))
      ])

    assert {:ok, %{disposition: :reconciled}} =
             SourceControl.ensure_remote_branch(
               config(timeout_then_found),
               branch_input,
               operation_opts()
             )

    {:ok, created} =
      ScriptTransport.start_link([
        get(path, 404, %{}),
        post(create_path, 201, branch(@sha))
      ])

    assert {:ok, %{disposition: :created, commit_sha: @sha}} =
             SourceControl.ensure_remote_branch(
               config(created),
               branch_input,
               operation_opts()
             )

    {:ok, conflicting_remote} = ScriptTransport.start_link([get(path, 200, branch(@other_sha))])

    assert {:error, :conflict} =
             SourceControl.ensure_remote_branch(
               config(conflicting_remote),
               branch_input,
               operation_opts()
             )

    {:ok, malformed_remote} = ScriptTransport.start_link([get(path, 200, %{})])

    assert {:error, :provider_failure} =
             SourceControl.ensure_remote_branch(config(malformed_remote), branch_input, operation_opts())
  end

  test "branch creation reports rejected and unreconciled outcomes" do
    path = "/projects/acme%2Fwidget/repository/branches/topic"
    create_path = "/projects/acme%2Fwidget/repository/branches"
    branch_input = %{name: "topic", commit_sha: @sha}

    {:ok, rejected} =
      ScriptTransport.start_link([
        get(path, 404, %{}),
        post(create_path, 403, %{})
      ])

    assert {:error, :forbidden} =
             SourceControl.ensure_remote_branch(config(rejected), branch_input, operation_opts())

    {:ok, unknown} =
      ScriptTransport.start_link([
        get(path, 404, %{}),
        post(create_path, 409, %{}),
        get(path, 404, %{})
      ])

    assert {:error, :unknown_outcome} =
             SourceControl.ensure_remote_branch(config(unknown), branch_input, operation_opts())
  end

  test "compare-and-set push distinguishes updated, reconciled, stale, and unknown outcomes" do
    path = "/projects/acme%2Fwidget/repository/branches/topic"

    cases = [
      {:ok, branch(@desired_sha), {:ok, %{disposition: :updated}}},
      {{:error, :timeout}, branch(@desired_sha), {:ok, %{disposition: :reconciled}}},
      {{:error, :timeout}, branch(@sha), {:error, :transport_failure}},
      {:ok, branch(@other_sha), {:error, :conflict}},
      {:ok, %{}, {:error, :provider_failure}},
      {:ok, :unavailable, {:error, :unknown_outcome}}
    ]

    for {push_result, observed, expected} <- cases do
      get_result =
        case observed do
          :unavailable -> {:error, :timeout}
          body -> ok(200, body)
        end

      {:ok, transport} =
        ScriptTransport.start_link([
          {:git_push, "refs/heads/topic", push_result},
          {:get, path, get_result}
        ])

      result =
        SourceControl.push_branch(
          config(transport),
          "topic",
          @desired_sha,
          Keyword.put(operation_opts(), :expected_remote_sha, @sha)
        )

      assert_result(
        expected,
        result,
        ScriptTransport.requests(transport)
      )

      assert [] = ScriptTransport.remaining(transport)
    end
  end

  test "merge request creation performs canonical project lookup and stores the raw description" do
    project_path = "/projects/acme%2Fwidget"
    path = "/projects/acme%2Fwidget/merge_requests"

    {:ok, transport} =
      ScriptTransport.start_link([
        get(project_path, 200, %{"id" => 101}),
        get(path, 200, []),
        post(path, 201, merge_request())
      ])

    config =
      transport
      |> config()
      |> update_in([:settings], &Map.delete(&1, :project_id))

    assert {:ok, %{disposition: :created, number: 17}} =
             SourceControl.ensure_change_request(
               change_request_attrs(config),
               operation_opts()
             )

    [project, list, create] = ScriptTransport.requests(transport)
    assert project.method == :get
    assert project.path == project_path
    assert list.query == %{"scope" => "all", "state" => "all", "per_page" => 100, "page" => 1}
    assert create.method == :post
    assert create.retry == :never
    assert create.json["description"] == "Coverage body"
    refute create.json["description"] =~ "<!-- symphony:"
  end

  test "merge request precheck ignores valid unrelated identities before creating" do
    path = "/projects/acme%2Fwidget/merge_requests"

    unrelated =
      merge_request(%{
        "source_branch" => "other-topic",
        "target_branch" => "main",
        "source_project_id" => 101,
        "target_project_id" => 101
      })

    {:ok, transport} =
      ScriptTransport.start_link([
        canonical_project(),
        get(path, 200, [unrelated]),
        post(path, 201, merge_request())
      ])

    assert {:ok, %{disposition: :created}} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(transport)),
               operation_opts()
             )

    assert Enum.count(ScriptTransport.requests(transport), &(&1.method == :post)) == 1
  end

  test "merge request identity precheck follows all-state pagination before reporting conflict" do
    path = "/projects/acme%2Fwidget/merge_requests"

    {:ok, transport} =
      ScriptTransport.start_link([
        canonical_project(),
        get(path, 200, [], %{"x-next-page" => "2"}),
        get(path, 200, [merge_request()])
      ])

    assert {:error, :conflict} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(transport)),
               operation_opts()
             )

    assert [
             %{query: %{"scope" => "all", "state" => "all", "per_page" => 100, "page" => 1}},
             %{query: %{"scope" => "all", "state" => "all", "per_page" => 100, "page" => 2}}
           ] =
             transport
             |> ScriptTransport.requests()
             |> Enum.filter(&(&1.path == path))
             |> Enum.map(&Map.take(&1, [:query]))
  end

  test "merge request copied marker is not trusted and same immutable identity is a conflict" do
    path = "/projects/acme%2Fwidget/merge_requests"
    copied_marker = "<!-- symphony:dedupe-sha256=copied intent-sha256=copied -->"

    copied =
      merge_request(%{
        "description" => copied_marker,
        "author" => %{"id" => String.to_integer(@bot_actor_id)}
      })

    {:ok, transport} =
      ScriptTransport.start_link([
        canonical_project(),
        get(path, 200, [copied])
      ])

    assert {:error, :conflict} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(transport)),
               operation_opts()
             )

    assert [] = ScriptTransport.remaining(transport)
  end

  test "ambiguous merge request creation reports unknown without another list or post" do
    path = "/projects/acme%2Fwidget/merge_requests"
    attrs_for = &change_request_attrs(config(&1))

    unknown_status_transports =
      for status <- [400, 409, 422, 500, 501, 507, 599] do
        {:ok, transport} =
          ScriptTransport.start_link([
            canonical_project(),
            get(path, 200, []),
            post(path, status, %{})
          ])

        assert {:error, :unknown_outcome} =
                 SourceControl.ensure_change_request(
                   attrs_for.(transport),
                   operation_opts()
                 )

        transport
      end

    {:ok, failed_reconciliation} =
      ScriptTransport.start_link([
        canonical_project(),
        get(path, 200, []),
        {:post, path, {:error, :timeout}}
      ])

    assert {:error, :unknown_outcome} =
             SourceControl.ensure_change_request(
               attrs_for.(failed_reconciliation),
               operation_opts()
             )

    {:ok, rejected_create} =
      ScriptTransport.start_link([
        canonical_project(),
        get(path, 200, []),
        post(path, 401, %{})
      ])

    assert {:error, :unauthorized} =
             SourceControl.ensure_change_request(attrs_for.(rejected_create), operation_opts())

    for transport <- unknown_status_transports ++ [failed_reconciliation, rejected_create] do
      requests = ScriptTransport.requests(transport)
      assert Enum.count(requests, &(&1.method == :post)) == 1
      assert Enum.count(requests, &(&1.method == :get and &1.path == path)) == 1
    end
  end

  test "merge request creation returns unknown when the 201 response identity or ids are malformed" do
    path = "/projects/acme%2Fwidget/merge_requests"

    for response <- [
          merge_request(%{"target_project_id" => 202}),
          merge_request(%{"source_branch" => "other-topic"}),
          Map.delete(merge_request(), "iid"),
          merge_request(%{"id" => "501"}),
          merge_request(%{"iid" => "17"}),
          merge_request(%{"id" => 0}),
          merge_request(%{"source_project_id" => "101"}),
          merge_request(%{"target_project_id" => 0})
        ] do
      {:ok, transport} =
        ScriptTransport.start_link([
          canonical_project(),
          get(path, 200, []),
          post(path, 201, response)
        ])

      assert {:error, :unknown_outcome} =
               SourceControl.ensure_change_request(
                 change_request_attrs(config(transport)),
                 operation_opts()
               )

      assert [] = ScriptTransport.remaining(transport)
    end
  end

  test "merge request creation rejects config project mismatch before listing or posting" do
    path = "/projects/acme%2Fwidget/merge_requests"

    for configured <- [0, "0", "abc", 202, "202", [], %{}] do
      {:ok, transport} =
        ScriptTransport.start_link([
          canonical_project()
        ])

      bad_config =
        transport
        |> config()
        |> put_in([:settings, :project_id], configured)

      assert {:error, :invalid_configuration} =
               SourceControl.ensure_change_request(
                 change_request_attrs(bad_config),
                 operation_opts()
               )

      refute Enum.any?(ScriptTransport.requests(transport), &(&1.path == path))
    end

    {:ok, malformed_project} =
      ScriptTransport.start_link([
        get("/projects/acme%2Fwidget", 200, [])
      ])

    assert {:error, :provider_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(malformed_project)),
               operation_opts()
             )

    refute Enum.any?(ScriptTransport.requests(malformed_project), &(&1.path == path))
  end

  test "merge request listing fails closed on malformed, rejected, and excessive pagination" do
    path = "/projects/acme%2Fwidget/merge_requests"

    {:ok, rejected} = ScriptTransport.start_link([canonical_project(), get(path, 401, %{})])

    assert {:error, :unauthorized} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(rejected)),
               operation_opts()
             )

    {:ok, malformed} = ScriptTransport.start_link([canonical_project(), get(path, 200, %{})])

    assert {:error, :provider_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(malformed)),
               operation_opts()
             )

    malformed_unrelated =
      merge_request(%{
        "source_branch" => "other-topic",
        "source_project_id" => "101"
      })

    {:ok, malformed_unrelated_list} =
      ScriptTransport.start_link([canonical_project(), get(path, 200, [malformed_unrelated])])

    assert {:error, :provider_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(malformed_unrelated_list)),
               operation_opts()
             )

    refute Enum.any?(ScriptTransport.requests(malformed_unrelated_list), &(&1.method == :post))

    pages =
      [canonical_project()] ++
        Enum.map(1..20, fn page ->
          get(path, 200, [], %{"x-next-page" => Integer.to_string(page + 1)})
        end)

    {:ok, excessive} = ScriptTransport.start_link(pages)

    assert {:error, :provider_failure} =
             SourceControl.ensure_change_request(
               change_request_attrs(config(excessive)),
               operation_opts()
             )

    assert 20 = Enum.count(ScriptTransport.requests(excessive), &(&1.path == path))
  end

  test "state maps every required pipeline outcome without conflating mergeability" do
    cases = [
      {[], %{}, :pending, :pending},
      {[%{"sha" => @sha, "status" => "success"}], %{}, :passed, :passed},
      {[%{"sha" => @sha, "status" => "running", "web_url" => "https://ci.test/pipeline"}], %{}, :pending, :pending},
      {[%{"sha" => @sha, "status" => "skipped"}], %{"allow_merge_on_skipped_pipeline" => true}, :passed, :passed},
      {[%{"sha" => @sha, "status" => "failed"}], %{}, :failed, :failed},
      {[%{"sha" => @sha, "status" => "unexpected"}], %{}, :unknown, :pending}
    ]

    for {pipelines, project_overrides, check_status, aggregate_status} <- cases do
      responses =
        state_responses(
          %{},
          Map.put(project_overrides, "only_allow_merge_if_pipeline_succeeds", true),
          pipelines
        )

      {:ok, transport} = ScriptTransport.start_link(responses)

      assert {:ok, state} = SourceControl.state(config(transport), change_request())
      assert [%{name: "pipeline", status: ^check_status}] = state.required_checks
      assert state.checks_status == aggregate_status
      assert state.mergeability == :checking
    end
  end

  test "state normalizes external checks and preserves provider failure semantics" do
    checks = [
      %{"name" => "lint", "status" => "passed", "external_url" => "https://ci.test/lint"},
      %{"external_status_check" => %{"name" => "review"}, "status" => "running"},
      %{"status" => "failed"},
      %{"name" => "custom", "status" => "unexpected"}
    ]

    {:ok, transport} =
      ScriptTransport.start_link(
        state_responses(
          %{},
          %{"only_allow_merge_if_all_status_checks_passed" => true},
          [],
          200,
          checks
        )
      )

    assert {:ok, state} = SourceControl.state(config(transport), change_request())

    assert Enum.map(state.required_checks, &{&1.name, &1.status}) == [
             {"custom", :unknown},
             {"external", :failed},
             {"lint", :passed},
             {"review", :pending}
           ]

    assert state.checks_status == :failed

    {:ok, passed_transport} =
      ScriptTransport.start_link(
        state_responses(
          %{},
          %{"only_allow_merge_if_all_status_checks_passed" => true},
          [],
          200,
          [%{"name" => "lint", "status" => "success"}]
        )
      )

    assert {:ok, %{checks_status: :passed}} =
             SourceControl.state(config(passed_transport), change_request())

    {:ok, rejected_external_checks} =
      ScriptTransport.start_link(
        state_responses(
          %{},
          %{"only_allow_merge_if_all_status_checks_passed" => true},
          [],
          418,
          %{}
        )
      )

    assert {:error, :provider_failure} =
             SourceControl.state(config(rejected_external_checks), change_request())

    {:ok, malformed_transport} =
      ScriptTransport.start_link(
        state_responses(
          %{},
          %{"only_allow_merge_if_all_status_checks_passed" => true},
          [],
          200,
          %{"unexpected" => true}
        )
      )

    assert {:error, :provider_failure} =
             SourceControl.state(config(malformed_transport), change_request())
  end

  test "state keeps merge request status and mergeability as independent dimensions" do
    cases = [
      {%{"state" => "merged", "detailed_merge_status" => "mergeable"}, :merged, :mergeable, true, true},
      {%{"state" => "closed", "detailed_merge_status" => "conflict"}, :closed, :conflicting, false, true},
      {%{"detailed_merge_status" => "ci_must_pass"}, :open, :blocked, false, false},
      {%{"detailed_merge_status" => "unexpected"}, :open, :unknown, false, false}
    ]

    for {merge_request_overrides, status, mergeability, merged?, closed?} <- cases do
      {:ok, transport} =
        ScriptTransport.start_link(state_responses(merge_request_overrides, %{}, []))

      assert {:ok, state} = SourceControl.state(config(transport), change_request())
      assert state.status == status
      assert state.mergeability == mergeability
      assert state.merged? == merged?
      assert state.closed? == closed?
      assert state.required_checks == []
      assert state.checks_status == :passed
    end
  end

  test "state propagates read failures and rejects a mismatched repository" do
    path = "/projects/acme%2Fwidget/merge_requests/17"
    {:ok, failed} = ScriptTransport.start_link([{:get, path, {:error, :timeout}}])

    assert {:error, :transport_failure} =
             SourceControl.state(config(failed), change_request())

    {:ok, unused} = ScriptTransport.start_link([])

    assert {:error, :provider_failure} =
             SourceControl.state(
               config(unused),
               change_request(repository: "other/repository")
             )

    assert [] = ScriptTransport.requests(unused)
  end

  test "draft updates distinguish replay, unknown transport, and provider rejection" do
    merge_request_path = "/projects/acme%2Fwidget/merge_requests/17"
    notes_path = merge_request_path <> "/notes"
    ready_opts = Keyword.put(operation_opts(), :draft, false)

    {:ok, already_ready} =
      ScriptTransport.start_link([
        get(merge_request_path, 200, merge_request(%{"draft" => false}))
      ])

    assert {:ok, %{disposition: :reconciled, draft?: false}} =
             SourceControl.set_draft(config(already_ready), change_request(), ready_opts)

    {:ok, reconciled_timeout} =
      ScriptTransport.start_link([
        get(merge_request_path, 200, merge_request(%{"draft" => true})),
        {:post, notes_path, {:error, :timeout}},
        get(merge_request_path, 200, merge_request(%{"draft" => false}))
      ])

    assert {:ok, %{disposition: :reconciled, draft?: false}} =
             SourceControl.set_draft(config(reconciled_timeout), change_request(), ready_opts)

    {:ok, transport_rejected} =
      ScriptTransport.start_link([
        get(merge_request_path, 200, merge_request(%{"draft" => true})),
        {:post, notes_path, {:error, :timeout}},
        get(merge_request_path, 200, merge_request(%{"draft" => true}))
      ])

    assert {:error, :transport_failure} =
             SourceControl.set_draft(config(transport_rejected), change_request(), ready_opts)

    {:ok, provider_rejected} =
      ScriptTransport.start_link([
        get(merge_request_path, 200, merge_request(%{"draft" => true})),
        post(notes_path, 201, %{"id" => 900}),
        get(merge_request_path, 200, merge_request(%{"draft" => true}))
      ])

    assert {:error, :provider_failure} =
             SourceControl.set_draft(config(provider_rejected), change_request(), ready_opts)
  end

  test "close is replay-safe and verifies the terminal provider state" do
    path = "/projects/acme%2Fwidget/merge_requests/17"
    close_opts = Keyword.put(operation_opts(), :action, :close)

    {:ok, already_closed} =
      ScriptTransport.start_link([
        get(path, 200, merge_request(%{"state" => "closed"}))
      ])

    assert {:ok, %{action: :already_applied, external_id: "501"}} =
             SourceControl.close_or_comment(config(already_closed), change_request(), close_opts)

    {:ok, provider_rejected} =
      ScriptTransport.start_link([
        get(path, 200, merge_request(%{"state" => "opened"})),
        put(path, 200, merge_request(%{"state" => "closed"})),
        get(path, 200, merge_request(%{"state" => "opened"}))
      ])

    assert {:error, :provider_failure} =
             SourceControl.close_or_comment(config(provider_rejected), change_request(), close_opts)

    {:ok, closed_after_put} =
      ScriptTransport.start_link([
        get(path, 200, merge_request(%{"state" => "opened"})),
        put(path, 200, merge_request(%{"state" => "closed"})),
        get(path, 200, merge_request(%{"state" => "closed"}))
      ])

    assert {:ok, %{action: :closed, external_id: "501"}} =
             SourceControl.close_or_comment(config(closed_after_put), change_request(), close_opts)

    {:ok, transport_rejected} =
      ScriptTransport.start_link([
        get(path, 200, merge_request(%{"state" => "opened"})),
        {:put, path, {:error, :timeout}},
        get(path, 200, merge_request(%{"state" => "opened"}))
      ])

    assert {:error, :transport_failure} =
             SourceControl.close_or_comment(config(transport_rejected), change_request(), close_opts)

    {:ok, missing} = ScriptTransport.start_link([get(path, 404, %{})])

    assert {:error, :not_found} =
             SourceControl.close_or_comment(config(missing), change_request(), close_opts)
  end

  test "health requires both branch and merge request write permissions" do
    project_path = "/projects/acme%2Fwidget"
    branch_path = project_path <> "/repository/branches/main"
    protected_path = project_path <> "/protected_branches/main"

    cases = [
      {project(%{"permissions" => %{"project_access" => %{"access_level" => 20}}}), branch(@sha)},
      {project(%{"permissions" => %{}}), branch(@sha)},
      {project(), Map.put(branch(@sha), "can_push", false)},
      {project(), Map.put(branch(@sha), "can_push", "unknown")}
    ]

    for {project_body, branch_body} <- cases do
      {:ok, transport} =
        ScriptTransport.start_link([
          get(project_path, 200, project_body),
          get(branch_path, 200, branch_body),
          get(protected_path, 200, %{}),
          get("/user", 200, gitlab_user())
        ])

      assert {:error, :forbidden} = SourceControl.health_check(config(transport))
      assert [] = ScriptTransport.remaining(transport)
    end
  end

  test "comment validates content and replays the exact dual-key marker" do
    body = "Review complete"
    path = "/projects/acme%2Fwidget/merge_requests/17/notes"

    assert {:error, :invalid_configuration} =
             GitLab.close_or_comment(
               config(self()),
               change_request(),
               comment_opts(" ")
             )

    replay_response = fn _request, requests ->
      marker_body =
        requests
        |> Enum.find(&(&1.method == :post and &1.path == path))
        |> get_in([:json, "body"])

      ok(200, [
        %{
          "id" => 902,
          "body" => marker_body,
          "author" => %{"id" => String.to_integer(@bot_actor_id)}
        }
      ])
    end

    {:ok, transport} =
      ScriptTransport.start_link([
        get(path, 200, []),
        post(path, 201, %{"id" => 901, "body" => body}),
        {:get, path, replay_response}
      ])

    assert {:ok, %{action: :commented, external_id: "901"}} =
             SourceControl.close_or_comment(
               config(transport),
               change_request(),
               comment_opts(body)
             )

    assert {:ok, %{action: :already_applied, external_id: "902"}} =
             SourceControl.close_or_comment(
               config(transport),
               change_request(),
               comment_opts(body)
             )

    assert [] = ScriptTransport.remaining(transport)
  end

  test "comment lookup follows pagination before deciding whether to create" do
    body = "Review complete"
    path = "/projects/acme%2Fwidget/merge_requests/17/notes"
    marker = comment_marker(body)

    {:ok, transport} =
      ScriptTransport.start_link([
        get(path, 200, [], %{"x-next-page" => "2"}),
        get(path, 200, [
          %{
            "id" => 903,
            "body" => AdapterSupport.append_marker(body, marker.exact),
            "author" => %{"id" => String.to_integer(@bot_actor_id)}
          }
        ])
      ])

    assert {:ok, %{action: :already_applied, external_id: "903"}} =
             SourceControl.close_or_comment(
               config(transport),
               change_request(),
               comment_opts(body)
             )

    assert [%{query: %{"page" => 1}}, %{query: %{"page" => 2}}] =
             Enum.map(ScriptTransport.requests(transport), &Map.take(&1, [:query]))
  end

  test "comment marker replay ignores copied or malformed GitLab actor provenance" do
    body = "Review complete"
    path = "/projects/acme%2Fwidget/merge_requests/17/notes"
    marker = comment_marker(body)

    forged_notes = [
      %{"id" => 903, "body" => marker.exact, "author" => %{"id" => "attacker-user"}},
      %{"id" => 904, "body" => marker.exact},
      %{"id" => 905, "body" => marker.exact, "author" => %{"id" => nil}}
    ]

    {:ok, transport} =
      ScriptTransport.start_link([
        get(path, 200, forged_notes),
        post(path, 201, %{"id" => 906, "body" => body})
      ])

    assert {:ok, %{action: :commented, external_id: "906"}} =
             SourceControl.close_or_comment(
               config(transport),
               change_request(),
               comment_opts(body)
             )

    assert [] = ScriptTransport.remaining(transport)
  end

  test "ambiguous comment creation reconciles before retry" do
    body = "Review complete"
    path = "/projects/acme%2Fwidget/merge_requests/17/notes"
    marker = comment_marker(body)

    {:ok, conflict_then_found} =
      ScriptTransport.start_link([
        get(path, 200, []),
        post(path, 409, %{}),
        get(path, 200, [
          %{
            "id" => 904,
            "body" => AdapterSupport.append_marker(body, marker.exact),
            "author" => %{"id" => String.to_integer(@bot_actor_id)}
          }
        ])
      ])

    assert {:ok, %{action: :already_applied, external_id: "904"}} =
             SourceControl.close_or_comment(
               config(conflict_then_found),
               change_request(),
               comment_opts(body)
             )

    {:ok, timeout_then_absent} =
      ScriptTransport.start_link([
        get(path, 200, []),
        {:post, path, {:error, :timeout}},
        get(path, 200, [])
      ])

    assert {:error, :unknown_outcome} =
             SourceControl.close_or_comment(
               config(timeout_then_absent),
               change_request(),
               comment_opts(body)
             )

    {:ok, failed_reconciliation} =
      ScriptTransport.start_link([
        get(path, 200, []),
        {:post, path, {:error, :timeout}},
        {:get, path, {:error, :timeout}}
      ])

    assert {:error, :transport_failure} =
             SourceControl.close_or_comment(
               config(failed_reconciliation),
               change_request(),
               comment_opts(body)
             )
  end

  test "comment endpoints fail closed on rejected or malformed provider responses" do
    body = "Review complete"
    path = "/projects/acme%2Fwidget/merge_requests/17/notes"

    {:ok, rejected_create} =
      ScriptTransport.start_link([
        get(path, 200, []),
        post(path, 401, %{})
      ])

    assert {:error, :unauthorized} =
             SourceControl.close_or_comment(
               config(rejected_create),
               change_request(),
               comment_opts(body)
             )

    {:ok, missing_list} = ScriptTransport.start_link([get(path, 404, %{})])

    assert {:error, :not_found} =
             SourceControl.close_or_comment(
               config(missing_list),
               change_request(),
               comment_opts(body)
             )

    {:ok, malformed_list} = ScriptTransport.start_link([get(path, 200, %{})])

    assert {:error, :provider_failure} =
             SourceControl.close_or_comment(
               config(malformed_list),
               change_request(),
               comment_opts(body)
             )
  end

  test "comment pagination has a bounded provider-failure limit" do
    body = "Review complete"
    path = "/projects/acme%2Fwidget/merge_requests/17/notes"

    pages =
      Enum.map(1..20, fn page ->
        get(path, 200, [], %{"x-next-page" => Integer.to_string(page + 1)})
      end)

    {:ok, transport} = ScriptTransport.start_link(pages)

    assert {:error, :provider_failure} =
             SourceControl.close_or_comment(
               config(transport),
               change_request(),
               comment_opts(body)
             )

    assert 20 = length(ScriptTransport.requests(transport))
  end

  defp assert_result({:ok, expected}, {:ok, actual}, _requests) do
    assert Map.take(actual, Map.keys(expected)) == expected
  end

  defp assert_result(expected, actual, requests), do: assert(expected == actual, inspect(requests))

  defp config(transport) do
    %{
      provider: :gitlab,
      credential_ref: "00000000-0000-0000-0000-000000000002",
      credential: "gitlab-secret-value",
      settings: %{
        repository: "acme/widget",
        base_branch: "main",
        api_base_url: "https://gitlab.test/api/v4",
        max_read_attempts: 1,
        project_id: 101,
        bot_actor_id: @bot_actor_id
      },
      transport: {ScriptTransport, transport}
    }
  end

  defp operation_opts do
    [operation_id: @operation_id, dedupe_key: @dedupe_key]
  end

  defp change_request(overrides \\ []) do
    struct!(
      ChangeRequest,
      Keyword.merge(
        [
          provider: :gitlab,
          external_id: "501",
          number: 17,
          url: "https://gitlab.test/acme/widget/-/merge_requests/17",
          repository: "acme/widget",
          head_branch: "topic",
          base_branch: "main",
          title: "Improve coverage",
          draft?: true,
          disposition: :reconciled
        ],
        overrides
      )
    )
  end

  defp change_request_attrs(config) do
    %{
      repo: config,
      head: "topic",
      base: "main",
      title: "Improve coverage",
      body: "Coverage body",
      draft: true
    }
  end

  defp comment_opts(body) do
    operation_opts()
    |> Keyword.put(:action, :comment)
    |> Keyword.put(:body, body)
  end

  defp comment_marker(body) do
    Transport.with_credential("gitlab-secret-value", fn ->
      {:ok, marker} =
        AdapterSupport.operation_marker(
          :gitlab,
          "acme/widget",
          :comment,
          @operation_id,
          @dedupe_key,
          ["501", AdapterSupport.body_digest(body)]
        )

      marker
    end)
  end

  defp merge_request(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 501,
        "iid" => 17,
        "web_url" => "https://gitlab.test/acme/widget/-/merge_requests/17",
        "title" => "Draft: Improve coverage",
        "description" => "Coverage body",
        "draft" => true,
        "source_branch" => "topic",
        "target_branch" => "main",
        "source_project_id" => 101,
        "target_project_id" => 101,
        "sha" => @sha,
        "author" => %{"id" => String.to_integer(@bot_actor_id)}
      },
      overrides
    )
  end

  defp state_responses(
         merge_request_overrides,
         project_overrides,
         pipelines,
         status_checks_status \\ 200,
         status_checks_body \\ []
       ) do
    number = 17
    project_path = "/projects/acme%2Fwidget"
    merge_request_path = "#{project_path}/merge_requests/#{number}"

    merge_request =
      merge_request(
        Map.merge(
          %{
            "state" => "opened",
            "draft" => false,
            "detailed_merge_status" => "checking",
            "diff_refs" => %{"base_sha" => @other_sha},
            "merge_commit_sha" => nil,
            "merged_at" => nil
          },
          merge_request_overrides
        )
      )

    project =
      Map.merge(
        %{
          "only_allow_merge_if_pipeline_succeeds" => false,
          "allow_merge_on_skipped_pipeline" => false,
          "only_allow_merge_if_all_status_checks_passed" => false
        },
        project_overrides
      )

    [
      get(merge_request_path, 200, merge_request),
      get(project_path, 200, project),
      get("#{merge_request_path}/pipelines", 200, pipelines),
      get(merge_request_path <> "/status_checks", status_checks_status, status_checks_body)
    ]
  end

  defp project(overrides \\ %{}) do
    Map.merge(
      %{
        "path_with_namespace" => "acme/widget",
        "default_branch" => "main",
        "permissions" => %{"project_access" => %{"access_level" => 40}}
      },
      overrides
    )
  end

  defp branch(sha), do: %{"name" => "topic", "can_push" => true, "commit" => %{"id" => sha}}
  defp gitlab_user(id \\ String.to_integer(@bot_actor_id)), do: %{"id" => id, "username" => "symphony-bot"}

  defp canonical_project(overrides \\ %{}),
    do: get("/projects/acme%2Fwidget", 200, Map.merge(%{"id" => 101}, overrides))

  defp get(path, status, body, headers \\ %{}), do: {:get, path, ok(status, body, headers)}
  defp post(path, status, body, headers \\ %{}), do: {:post, path, ok(status, body, headers)}
  defp put(path, status, body, headers \\ %{}), do: {:put, path, ok(status, body, headers)}

  defp ok(status, body, headers \\ %{}) do
    {:ok, %{status: status, headers: headers, body: body}}
  end
end
