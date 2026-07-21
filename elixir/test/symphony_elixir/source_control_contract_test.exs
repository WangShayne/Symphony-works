defmodule SymphonyElixir.SourceControlFakeSharedContractTest do
  use SymphonyElixir.SourceControlContract, adapter: SymphonyElixir.SourceControl.Fake
end

defmodule SymphonyElixir.SourceControlGitHubSharedContractTest do
  use SymphonyElixir.SourceControlContract, adapter: SymphonyElixir.SourceControl.GitHub
end

defmodule SymphonyElixir.SourceControlGitLabSharedContractTest do
  use SymphonyElixir.SourceControlContract, adapter: SymphonyElixir.SourceControl.GitLab
end

defmodule SymphonyElixir.SourceControlContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControlContract.{ExplodingTransport, FixtureTransport}

  test "fixture transport records unmatched requests as deterministic failures" do
    path = Path.join(System.tmp_dir!(), "symphony-source-control-empty-fixture.json")
    File.write!(path, "[]")

    assert {:ok, transport} = FixtureTransport.start_link(path)

    request = %{method: :get, path: "/missing", headers: %{}}
    assert {:error, :no_fixture_response} = FixtureTransport.request(request, transport)
    assert FixtureTransport.requests(transport) == [request]
  after
    File.rm(Path.join(System.tmp_dir!(), "symphony-source-control-empty-fixture.json"))
  end

  test "fixture provider dispatches to the deterministic Source Control adapter" do
    config = %{
      provider: "fixture",
      settings: %{
        "repository" => "symphony/fixture",
        "base_branch" => "main",
        "scenario" => "healthy"
      }
    }

    assert {:ok, health} = SourceControl.health_check(config)
    assert health.provider == :fixture
    assert health.repository == "symphony/fixture"
    assert health.base_branch == "main"
    assert byte_size(health.base_commit_sha) == 40

    assert health.permissions == %{
             repository_read: :allowed,
             branch_write: :allowed,
             change_request_write: :allowed
           }
  end

  test "one operation identity cannot create duplicate change requests" do
    attrs = %{
      repo: fixture_config(),
      head: "symphony/ABC-1",
      base: "main",
      title: "ABC-1",
      body: "First accepted result",
      draft: true
    }

    operation = [operation_id: "task-1:create-cr", dedupe_key: "ABC-1:delivery"]

    assert {:ok, first} = SourceControl.ensure_change_request(attrs, operation)
    assert {:ok, second} = SourceControl.ensure_change_request(attrs, operation)
    assert first.external_id == second.external_id
    assert first.disposition == :reconciled
    assert second.disposition == :reconciled
    assert first.draft?
  end

  test "a mutation requires both operation identity and caller dedupe key" do
    attrs = %{
      repo: fixture_config(),
      head: "symphony/ABC-2",
      base: "main",
      draft: true
    }

    assert {:error, :missing_operation_identity} =
             SourceControl.ensure_change_request(attrs, operation_id: "task-2:create-cr")

    assert {:error, :missing_operation_identity} =
             SourceControl.ensure_change_request(attrs, dedupe_key: "ABC-2:delivery")
  end

  test "resolves a normalized immutable task baseline" do
    assert {:ok, baseline} = SourceControl.resolve_baseline(fixture_config(), "main")

    assert baseline.provider == :fixture
    assert baseline.repository == "symphony/fixture"
    assert baseline.branch == "main"
    assert byte_size(baseline.commit_sha) == 40
  end

  test "branch mutations are replay-safe and expose the observed remote commit" do
    repo = fixture_config()
    branch = %{name: "symphony/ABC-3", commit_sha: String.duplicate("a", 40)}
    create_op = [operation_id: "task-3:create-branch", dedupe_key: "ABC-3:branch"]

    assert {:ok, created} = SourceControl.ensure_remote_branch(repo, branch, create_op)
    assert {:ok, reconciled} = SourceControl.ensure_remote_branch(repo, branch, create_op)
    assert created.name == "symphony/ABC-3"
    assert created.commit_sha == String.duplicate("a", 40)
    assert created.disposition == :reconciled
    assert reconciled.disposition == :reconciled

    push_op = [
      operation_id: "task-3:push-branch",
      dedupe_key: "ABC-3:push:1",
      expected_remote_sha: branch.commit_sha
    ]

    commit_sha = String.duplicate("b", 40)

    assert {:ok, pushed} = SourceControl.push_branch(repo, branch.name, commit_sha, push_op)
    assert pushed.commit_sha == commit_sha
    assert pushed.name == branch.name
  end

  test "normalizes base branch, readiness, required checks, mergeability, and human merge observation" do
    attrs = %{
      repo: fixture_config(),
      head: "symphony/ABC-4",
      base: "release/v1",
      title: "ABC-4",
      draft: false
    }

    assert {:ok, change_request} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-4:create-cr",
               dedupe_key: "ABC-4:delivery"
             )

    repo =
      put_in(fixture_config(), [:settings, :observed_state], %{
        required_checks: [
          %{name: "test", status: :passed},
          %{name: "security", status: :pending}
        ],
        mergeability: :mergeable,
        merged?: true,
        closed?: true
      })

    assert {:ok, state} = SourceControl.state(repo, change_request)
    assert state.base_branch == "release/v1"
    assert state.head_branch == "symphony/ABC-4"
    assert state.draft? == false
    assert state.ready? == true

    assert state.required_checks == [
             %{name: "security", status: :pending, url: nil},
             %{name: "test", status: :passed, url: nil}
           ]

    assert state.checks_status == :pending
    assert state.mergeability == :mergeable
    assert state.merged? == true
    assert state.closed? == true
  end

  test "GitHub health is read-only and credential material reaches only the outbound transport" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "health.json"))

    config = %{
      provider: "github",
      credential_ref: "00000000-0000-0000-0000-000000000001",
      credential: "github-secret-value",
      settings: %{
        "repository" => "acme/widget",
        "base_branch" => "main",
        "api_base_url" => "https://api.github.test"
      },
      transport: {FixtureTransport, transport}
    }

    assert {:ok, health} = SourceControl.health_check(config)
    assert health.provider == :github
    assert health.repository == "acme/widget"
    assert health.base_branch == "main"
    assert health.base_commit_sha == "1111111111111111111111111111111111111111"

    assert health.permissions == %{
             repository_read: :allowed,
             branch_write: :allowed,
             change_request_write: :allowed
           }

    requests = FixtureTransport.requests(transport)
    assert Enum.map(requests, & &1.method) == [:get, :get, :get]
    assert Enum.all?(requests, &(get_in(&1, [:headers, "authorization"]) == "Bearer github-secret-value"))

    evidence = inspect(health)
    refute evidence =~ "github-secret-value"
    refute evidence =~ config.credential_ref
  end

  test "GitHub resolves the requested branch to an immutable commit" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "baseline.json"))

    config = github_config(transport)

    assert {:ok, baseline} = SourceControl.resolve_baseline(config, "release/v1")
    assert baseline.provider == :github
    assert baseline.repository == "acme/widget"
    assert baseline.branch == "release/v1"
    assert baseline.commit_sha == "2222222222222222222222222222222222222222"

    [request] = FixtureTransport.requests(transport)
    assert request.path == "/repos/acme/widget/branches/release%2Fv1"
  end

  test "GitLab health is read-only and normalizes project permissions" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "health.json"))

    config = gitlab_config(transport)

    assert {:ok, health} = SourceControl.health_check(config)
    assert health.provider == :gitlab
    assert health.repository == "acme/widget"
    assert health.base_branch == "main"
    assert health.base_commit_sha == "3333333333333333333333333333333333333333"

    assert health.permissions == %{
             repository_read: :allowed,
             branch_write: :allowed,
             change_request_write: :allowed
           }

    requests = FixtureTransport.requests(transport)
    assert Enum.map(requests, & &1.method) == [:get, :get, :get]
    assert Enum.all?(requests, &(get_in(&1, [:headers, "private-token"]) == "gitlab-secret-value"))
    refute inspect(health) =~ "gitlab-secret-value"
  end

  test "GitLab resolves the requested branch to an immutable commit" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "baseline.json"))

    assert {:ok, baseline} =
             SourceControl.resolve_baseline(gitlab_config(transport), "release/v1")

    assert baseline.provider == :gitlab
    assert baseline.repository == "acme/widget"
    assert baseline.branch == "release/v1"
    assert baseline.commit_sha == "4444444444444444444444444444444444444444"
  end

  test "GitHub reconciles branch creation before replaying a mutation" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "ensure_branch.json"))

    branch = %{name: "symphony/ABC-5", commit_sha: String.duplicate("5", 40)}
    operation = [operation_id: "task-5:create-branch", dedupe_key: "ABC-5:branch"]
    config = github_config(transport)

    assert {:ok, created} = SourceControl.ensure_remote_branch(config, branch, operation)
    assert created.disposition == :created
    assert {:ok, replayed} = SourceControl.ensure_remote_branch(config, branch, operation)
    assert replayed.disposition == :reconciled

    assert Enum.map(FixtureTransport.requests(transport), & &1.method) == [:get, :post, :get]
  end

  test "GitLab reconciles branch creation before replaying a mutation" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "ensure_branch.json"))

    branch = %{name: "symphony/ABC-6", commit_sha: String.duplicate("6", 40)}
    operation = [operation_id: "task-6:create-branch", dedupe_key: "ABC-6:branch"]
    config = gitlab_config(transport)

    assert {:ok, created} = SourceControl.ensure_remote_branch(config, branch, operation)
    assert created.disposition == :created
    assert {:ok, replayed} = SourceControl.ensure_remote_branch(config, branch, operation)
    assert replayed.disposition == :reconciled
  end

  test "GitHub pushes with compare-and-set and verifies the remote SHA" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "push_branch.json"))

    expected_sha = String.duplicate("7", 40)
    desired_sha = String.duplicate("8", 40)

    assert {:ok, branch} =
             SourceControl.push_branch(
               github_config(transport),
               "symphony/ABC-7",
               desired_sha,
               operation_id: "task-7:push",
               dedupe_key: "ABC-7:push:1",
               expected_remote_sha: expected_sha
             )

    assert branch.commit_sha == desired_sha
    assert branch.disposition == :updated

    [push, read] = FixtureTransport.requests(transport)
    assert push.method == :git_push
    assert push.expected_remote_sha == expected_sha
    assert push.desired_commit_sha == desired_sha
    assert read.method == :get
  end

  test "push rejects blind remote updates without an expected SHA" do
    assert {:error, :invalid_configuration} =
             SourceControl.push_branch(
               fixture_config(),
               "symphony/ABC-8",
               String.duplicate("8", 40),
               operation_id: "task-8:push",
               dedupe_key: "ABC-8:push:1"
             )
  end

  test "GitHub creates one draft pull request with a hidden reconciliation marker" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "create_change_request.json"))

    attrs = %{
      repo: github_config(transport),
      head: "symphony/ABC-9",
      base: "main",
      title: "ABC-9",
      body: "Accepted implementation",
      draft: true
    }

    assert {:ok, change_request} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-9:create-cr",
               dedupe_key: "ABC-9:delivery"
             )

    assert change_request.provider == :github
    assert change_request.external_id == "9009"
    assert change_request.number == 9
    assert change_request.draft?
    assert change_request.disposition == :created

    [_list, create] = FixtureTransport.requests(transport)
    assert create.method == :post
    assert create.json["draft"] == true
    assert create.json["body"] =~ "Accepted implementation"

    assert create.json["body"] =~
             ~r/<!-- symphony:dedupe-sha256=[0-9a-f]{64} intent-sha256=[0-9a-f]{64} operation-sha256=[0-9a-f]{64} -->/
  end

  test "GitLab creates one draft merge request with a hidden reconciliation marker" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "create_change_request.json"))

    attrs = %{
      repo: gitlab_config(transport),
      head: "symphony/ABC-10",
      base: "main",
      title: "ABC-10",
      body: "Accepted implementation",
      draft: true
    }

    assert {:ok, change_request} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-10:create-cr",
               dedupe_key: "ABC-10:delivery"
             )

    assert change_request.provider == :gitlab
    assert change_request.external_id == "1010"
    assert change_request.number == 10
    assert change_request.draft?
    assert change_request.disposition == :created

    [_list, create] = FixtureTransport.requests(transport)
    assert create.method == :post
    assert create.json["title"] == "Draft: ABC-10"
    assert create.json["description"] =~ "Accepted implementation"
    assert create.json["description"] =~ "<!-- symphony:dedupe-sha256="
  end

  test "GitHub state separates required checks, mergeability, and observed human merge" do
    {:ok, transport} = FixtureTransport.start_link(fixture_path("github", "state.json"))

    change_request = %SourceControl.ChangeRequest{
      provider: :github,
      external_id: "11011",
      number: 11,
      url: "https://github.test/acme/widget/pull/11",
      repository: "acme/widget",
      head_branch: "symphony/ABC-11",
      base_branch: "main",
      draft?: false,
      disposition: :reconciled
    }

    assert {:ok, state} = SourceControl.state(github_config(transport), change_request)
    assert state.status == :merged
    assert state.draft? == false
    assert state.ready? == true
    assert state.merged? == true
    assert state.mergeability == :mergeable
    assert state.head_sha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    assert state.base_sha == "1111111111111111111111111111111111111111"
    assert state.merge_sha == "cccccccccccccccccccccccccccccccccccccccc"

    assert state.required_checks == [
             %{name: "ci/test", status: :passed, url: "https://checks.test/ci"},
             %{name: "security", status: :pending, url: "https://status.test/security"}
           ]

    assert state.checks_status == :pending
  end

  test "GitLab state preserves asynchronous mergeability and pipeline gates" do
    {:ok, transport} = FixtureTransport.start_link(fixture_path("gitlab", "state.json"))

    change_request = %SourceControl.ChangeRequest{
      provider: :gitlab,
      external_id: "12012",
      number: 12,
      url: "https://gitlab.test/acme/widget/-/merge_requests/12",
      repository: "acme/widget",
      head_branch: "symphony/ABC-12",
      base_branch: "main",
      draft?: false,
      disposition: :reconciled
    }

    assert {:ok, state} = SourceControl.state(gitlab_config(transport), change_request)
    assert state.status == :open
    assert state.merged? == false
    assert state.mergeability == :checking
    assert state.checks_status == :pending
    assert state.required_checks == [%{name: "pipeline", status: :pending, url: "https://gitlab.test/pipelines/88"}]
  end

  test "fixture supports draft readiness and replay-safe close or comment without merge authority" do
    attrs = %{
      repo: fixture_config(),
      head: "symphony/ABC-13",
      base: "main",
      title: "ABC-13",
      draft: true
    }

    assert {:ok, change_request} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-13:create-cr",
               dedupe_key: "ABC-13:delivery"
             )

    assert {:ok, ready} =
             SourceControl.set_draft(fixture_config(), change_request,
               operation_id: "task-13:ready",
               dedupe_key: "ABC-13:ready",
               draft: false
             )

    assert ready.draft? == false
    assert ready.disposition == :updated

    assert {:ok, comment} =
             SourceControl.close_or_comment(fixture_config(), ready,
               operation_id: "task-13:comment",
               dedupe_key: "ABC-13:comment:1",
               action: :comment,
               body: "Task acceptance passed"
             )

    assert comment.action == :commented
    assert is_binary(comment.external_id)
    refute function_exported?(SourceControl, :merge_change_request, 3)
  end

  test "GitHub uses provider-private GraphQL then REST reconciliation to mark ready" do
    {:ok, transport} = FixtureTransport.start_link(fixture_path("github", "set_ready.json"))
    change_request = change_request(:github, 14, true)

    assert {:ok, ready} =
             SourceControl.set_draft(github_config(transport), change_request,
               operation_id: "task-14:ready",
               dedupe_key: "ABC-14:ready",
               draft: false
             )

    assert ready.draft? == false
    assert ready.disposition == :updated

    [before_read, mutation, after_read] = FixtureTransport.requests(transport)
    assert before_read.method == :get
    assert mutation.method == :post
    assert mutation.path == "/graphql"
    assert mutation.json["query"] =~ "markPullRequestReadyForReview"
    assert get_in(mutation.json, ["variables", "input", "clientMutationId"]) == "task-14:ready"
    assert after_read.method == :get
  end

  test "GitLab uses a quick action then reconciles the draft field" do
    {:ok, transport} = FixtureTransport.start_link(fixture_path("gitlab", "set_ready.json"))
    change_request = change_request(:gitlab, 15, true)

    assert {:ok, ready} =
             SourceControl.set_draft(gitlab_config(transport), change_request,
               operation_id: "task-15:ready",
               dedupe_key: "ABC-15:ready",
               draft: false
             )

    assert ready.draft? == false
    assert ready.disposition == :updated

    [_before_read, quick_action, _after_read] = FixtureTransport.requests(transport)
    assert quick_action.json == %{"body" => "/ready"}
  end

  test "GitHub comments carry a stable marker for unknown-outcome reconciliation" do
    {:ok, transport} = FixtureTransport.start_link(fixture_path("github", "comment.json"))

    assert {:ok, result} =
             SourceControl.close_or_comment(
               github_config(transport),
               change_request(:github, 16, false),
               operation_id: "task-16:comment",
               dedupe_key: "ABC-16:comment:1",
               action: :comment,
               body: "Acceptance evidence attached"
             )

    assert result == %{action: :commented, external_id: "1616"}
    [_list, create] = FixtureTransport.requests(transport)
    assert create.json["body"] =~ "Acceptance evidence attached"
    assert create.json["body"] =~ "<!-- symphony:dedupe-sha256="
  end

  test "GitLab closes without invoking any merge endpoint and verifies terminal state" do
    {:ok, transport} = FixtureTransport.start_link(fixture_path("gitlab", "close.json"))

    assert {:ok, result} =
             SourceControl.close_or_comment(
               gitlab_config(transport),
               change_request(:gitlab, 17, false),
               operation_id: "task-17:close",
               dedupe_key: "ABC-17:close",
               action: :close
             )

    assert result == %{action: :closed, external_id: "17017"}
    requests = FixtureTransport.requests(transport)
    assert Enum.map(requests, & &1.method) == [:get, :put, :get]
    refute Enum.any?(requests, &String.ends_with?(&1.path, "/merge"))
  end

  test "GitHub follows pagination and reconciles the same Change Request on replay" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "replay_change_request.json"))

    attrs = %{
      repo: github_config(transport),
      head: "symphony/ABC-18",
      base: "main",
      title: "ABC-18",
      body: "Accepted implementation",
      draft: true
    }

    operation = [operation_id: "task-18:create-cr", dedupe_key: "ABC-18:delivery"]
    assert {:ok, created} = SourceControl.ensure_change_request(attrs, operation)
    assert created.disposition == :created
    assert {:ok, replayed} = SourceControl.ensure_change_request(attrs, operation)
    assert replayed.external_id == created.external_id
    assert replayed.disposition == :reconciled

    requests = FixtureTransport.requests(transport)
    assert Enum.count(requests, &(&1.method == :post)) == 1

    assert requests
           |> Enum.filter(&(&1.method == :get))
           |> Enum.map(&get_in(&1, [:query, "page"])) == [1, 2, 1, 2]
  end

  test "GitLab reconciles an unknown create outcome before returning" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "unknown_change_request.json"))

    attrs = %{
      repo: gitlab_config(transport),
      head: "symphony/ABC-19",
      base: "main",
      title: "ABC-19",
      body: "Accepted implementation",
      draft: true
    }

    assert {:ok, reconciled} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-19:create-cr",
               dedupe_key: "ABC-19:delivery"
             )

    assert reconciled.external_id == "19019"
    assert reconciled.disposition == :reconciled
    assert Enum.map(FixtureTransport.requests(transport), & &1.method) == [:get, :post, :get]
  end

  test "safe reads retry rate limits without leaking provider response bodies" do
    {:ok, transport} = FixtureTransport.start_link(fixture_path("github", "rate_limit.json"))
    test_pid = self()

    config =
      github_config(transport)
      |> Map.put(:retry_sleep, fn delay -> send(test_pid, {:retry_delay, delay}) end)

    assert {:ok, baseline} = SourceControl.resolve_baseline(config, "main")
    assert baseline.commit_sha == "2020202020202020202020202020202020202020"
    assert_receive {:retry_delay, 0}
    assert length(FixtureTransport.requests(transport)) == 2
  end

  test "facade redacts transport exceptions and rejects arbitrary adapter modules" do
    config =
      github_config(:unused)
      |> Map.put(:transport, {ExplodingTransport, :unused})

    assert {:error, reason} = SourceControl.health_check(config)
    refute inspect(reason) =~ "github-secret-value"
    refute inspect(reason) =~ "00000000-secret"

    assert {:error, :unsupported_provider} =
             SourceControl.health_check(%{provider: ExplodingTransport, settings: %{}})
  end

  test "same dedupe key with changed intent fails instead of taking over the existing PR" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "idempotency_conflict.json"))

    attrs = %{
      repo: github_config(transport),
      head: "symphony/ABC-21",
      base: "main",
      title: "ABC-21",
      body: "Original intent",
      draft: true
    }

    operation = [operation_id: "task-21:create-cr", dedupe_key: "ABC-21:delivery"]
    assert {:ok, _created} = SourceControl.ensure_change_request(attrs, operation)

    changed = %{attrs | body: "Changed intent"}

    assert {:error, :idempotency_conflict} =
             SourceControl.ensure_change_request(changed, operation)

    assert Enum.count(FixtureTransport.requests(transport), &(&1.method == :post)) == 1
  end

  test "one GitHub operation id cannot be reused with another dedupe key" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "idempotency_conflict.json"))

    attrs = %{
      repo: github_config(transport),
      head: "symphony/ABC-21",
      base: "main",
      title: "ABC-21",
      body: "Original intent",
      draft: true
    }

    assert {:ok, _created} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-21:create-cr",
               dedupe_key: "ABC-21:delivery"
             )

    assert {:error, :idempotency_conflict} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-21:create-cr",
               dedupe_key: "ABC-21:other-delivery"
             )

    requests = FixtureTransport.requests(transport)
    assert Enum.count(requests, &(&1.method == :post)) == 1
    assert Enum.all?(Enum.filter(requests, &(&1.method == :get)), &is_nil(&1.query["head"]))
    assert Enum.all?(Enum.filter(requests, &(&1.method == :get)), &is_nil(&1.query["base"]))
  end

  test "a stable GitHub dedupe key reconciles across a new operation id" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "idempotency_conflict.json"))

    attrs = %{
      repo: github_config(transport),
      head: "symphony/ABC-21",
      base: "main",
      title: "ABC-21",
      body: "Original intent",
      draft: true
    }

    assert {:ok, created} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-21:create-cr:first",
               dedupe_key: "ABC-21:delivery"
             )

    assert {:ok, replayed} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-21:create-cr:recovery",
               dedupe_key: "ABC-21:delivery"
             )

    assert replayed.external_id == created.external_id
    assert replayed.disposition == :reconciled
  end

  test "GitHub marker lookup detects changed branch intent without head/base filtering" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "idempotency_conflict.json"))

    attrs = %{
      repo: github_config(transport),
      head: "symphony/ABC-21",
      base: "main",
      title: "ABC-21",
      body: "Original intent",
      draft: true
    }

    operation = [operation_id: "task-21:create-cr", dedupe_key: "ABC-21:delivery"]
    assert {:ok, _created} = SourceControl.ensure_change_request(attrs, operation)

    assert {:error, :idempotency_conflict} =
             SourceControl.ensure_change_request(%{attrs | head: "symphony/ABC-21-replanned"}, operation)

    assert Enum.count(FixtureTransport.requests(transport), &(&1.method == :post)) == 1
  end

  test "one GitLab operation id cannot be reused with another dedupe key" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "idempotency_conflict.json"))

    attrs = %{
      repo: gitlab_config(transport),
      head: "symphony/ABC-23",
      base: "main",
      title: "ABC-23",
      body: "Original intent",
      draft: true
    }

    assert {:ok, _created} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-23:create-cr",
               dedupe_key: "ABC-23:delivery"
             )

    assert {:error, :idempotency_conflict} =
             SourceControl.ensure_change_request(attrs,
               operation_id: "task-23:create-cr",
               dedupe_key: "ABC-23:other-delivery"
             )

    requests = FixtureTransport.requests(transport)
    assert Enum.count(requests, &(&1.method == :post)) == 1

    assert Enum.all?(Enum.filter(requests, &(&1.method == :get)), fn request ->
             is_nil(request.query["source_branch"]) and is_nil(request.query["target_branch"])
           end)
  end

  test "Fake enforces changed-intent conflicts and remote SHA compare-and-set" do
    attrs = %{
      repo: fixture_config(),
      head: "symphony/ABC-24",
      base: "main",
      title: "ABC-24",
      body: "Original intent",
      draft: true
    }

    operation = [operation_id: "task-24:create-cr", dedupe_key: "ABC-24:delivery"]
    assert {:ok, _created} = SourceControl.ensure_change_request(attrs, operation)

    assert {:error, :idempotency_conflict} =
             SourceControl.ensure_change_request(%{attrs | body: "Changed intent"}, operation)

    original_sha = String.duplicate("a", 40)
    desired_sha = String.duplicate("b", 40)
    stale_sha = String.duplicate("c", 40)
    branch = %{name: "symphony/ABC-24", commit_sha: original_sha}

    assert {:ok, _branch} =
             SourceControl.ensure_remote_branch(fixture_config(), branch,
               operation_id: "task-24:branch",
               dedupe_key: "ABC-24:branch"
             )

    assert {:error, :conflict} =
             SourceControl.push_branch(fixture_config(), branch.name, desired_sha,
               operation_id: "task-24:push:stale",
               dedupe_key: "ABC-24:push:stale",
               expected_remote_sha: stale_sha
             )

    push = [
      operation_id: "task-24:push",
      dedupe_key: "ABC-24:push",
      expected_remote_sha: original_sha
    ]

    assert {:ok, updated} =
             SourceControl.push_branch(fixture_config(), branch.name, desired_sha, push)

    assert updated.disposition == :updated

    assert {:ok, replayed} =
             SourceControl.push_branch(fixture_config(), branch.name, desired_sha, push)

    assert replayed.disposition == :reconciled
  end

  test "health checks fail when write permissions are denied or unknown" do
    {:ok, github_transport} =
      FixtureTransport.start_link(fixture_path("github", "health_denied.json"))

    {:ok, gitlab_transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "health_unknown.json"))

    assert {:error, :forbidden} = SourceControl.health_check(github_config(github_transport))
    assert {:error, :forbidden} = SourceControl.health_check(gitlab_config(gitlab_transport))

    denied_fixture =
      put_in(fixture_config(), [:settings, :permissions], %{branch_write: :denied})

    assert {:error, :forbidden} = SourceControl.health_check(denied_fixture)
  end

  test "GitHub falls back from empty rulesets and keeps newest app-bound check evidence" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("github", "state_protection_fallback.json"))

    assert {:ok, state} =
             SourceControl.state(github_config(transport), change_request(:github, 22, false))

    assert state.required_checks == [
             %{name: "app-check", status: :failed, url: "https://checks.test/right-app"},
             %{name: "legacy", status: :passed, url: "https://status.test/latest"}
           ]

    assert state.checks_status == :failed
  end

  test "GitLab does not treat a required external-check error as no checks" do
    {:ok, transport} =
      FixtureTransport.start_link(fixture_path("gitlab", "state_required_external_error.json"))

    assert {:error, :provider_failure} =
             SourceControl.state(gitlab_config(transport), change_request(:gitlab, 12, false))
  end

  defp fixture_config do
    %{
      provider: :fixture,
      settings: %{repository: "symphony/fixture", base_branch: "main", scenario: "healthy"}
    }
  end

  defp fixture_path(provider, name) do
    Path.expand("../fixtures/source_control/#{provider}/#{name}", __DIR__)
  end

  defp github_config(transport) do
    %{
      provider: :github,
      credential_ref: "00000000-0000-0000-0000-000000000001",
      credential: "github-secret-value",
      settings: %{
        repository: "acme/widget",
        base_branch: "main",
        api_base_url: "https://api.github.test"
      },
      transport: {FixtureTransport, transport}
    }
  end

  defp gitlab_config(transport) do
    %{
      provider: :gitlab,
      credential_ref: "00000000-0000-0000-0000-000000000002",
      credential: "gitlab-secret-value",
      settings: %{
        repository: "acme/widget",
        base_branch: "main",
        api_base_url: "https://gitlab.test/api/v4"
      },
      transport: {FixtureTransport, transport}
    }
  end

  defp change_request(provider, number, draft?) do
    %SourceControl.ChangeRequest{
      provider: provider,
      external_id: Integer.to_string(number * 1_001),
      number: number,
      url: "https://provider.test/change/#{number}",
      repository: "acme/widget",
      head_branch: "symphony/ABC-#{number}",
      base_branch: "main",
      title: "ABC-#{number}",
      draft?: draft?,
      disposition: :reconciled
    }
  end
end
