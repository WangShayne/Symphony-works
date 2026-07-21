defmodule SymphonyElixir.SourceControlFakeCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SourceControl.{AdapterSupport, ChangeRequest, Fake, Transport}

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @sha_c String.duplicate("c", 40)

  test "adapter support reads atom and string configuration keys" do
    assert AdapterSupport.value(%{repository: "atom/repository"}, :repository) ==
             "atom/repository"

    assert AdapterSupport.value(%{"repository" => "string/repository"}, :repository) ==
             "string/repository"

    assert is_nil(AdapterSupport.value(%{}, :repository))
  end

  test "adapter support distinguishes marker replay, ambiguity, and identity conflicts" do
    first = marker("operation-1", "delivery-1", ["head", "main", "intent"])
    replay = marker("operation-2", "delivery-1", ["head", "main", "intent"])
    changed_intent = marker("operation-3", "delivery-1", ["head", "main", "changed"])
    reused_operation = marker("operation-1", "delivery-2", ["head", "main", "intent"])

    item = %{"body" => AdapterSupport.append_marker("body", first.exact), "id" => 1}

    assert {:ok, {:found, ^item}} = marker_decision([item], first)
    assert {:ok, {:found, ^item}} = marker_decision([item], replay)

    assert {:error, :idempotency_conflict} = marker_decision([item], changed_intent)

    assert {:error, :idempotency_conflict} = marker_decision([item], reused_operation)

    assert {:error, :ambiguous_external_state} =
             marker_decision([item, %{item | "id" => 2}], first)

    assert {:ok, :create} = marker_decision([], first)

    digest = AdapterSupport.body_digest("body")
    assert byte_size(digest) == 64
    assert digest == AdapterSupport.body_digest("body")
    refute digest == AdapterSupport.body_digest("changed body")
  end

  test "adapter support only matches canonical marker lines" do
    marker = marker("operation-1", "delivery-1", ["head", "main", "intent"])

    canonical = %{"body" => "#{marker.exact}\r\n\nbody", "id" => 1}

    copied = [
      %{"body" => "body\n\n#{marker.exact}", "id" => 8},
      %{"body" => "#{marker.exact}\nbody without blank separator", "id" => 9},
      %{"body" => "> #{marker.exact}", "id" => 2},
      %{"body" => "prefix #{marker.exact}", "id" => 3},
      %{"body" => "#{marker.exact} suffix", "id" => 4},
      %{"body" => "<p>#{marker.exact}</p>", "id" => 5},
      %{"body" => "```\n#{marker.exact}\n```", "id" => 10},
      %{"body" => "<div>\n#{marker.exact}\n</div>", "id" => 11}
    ]

    assert {:ok, {:found, ^canonical}} = marker_decision([canonical | copied], marker)

    assert {:ok, :create} = marker_decision(copied, marker)

    changed_intent = marker("operation-2", "delivery-1", ["head", "main", "changed"])

    embedded_conflict = %{"body" => "prefix #{changed_intent.exact}", "id" => 6}
    assert {:ok, :create} = marker_decision([embedded_conflict], marker)

    legal_conflict = %{"body" => AdapterSupport.append_marker("body", changed_intent.exact), "id" => 7}

    assert {:error, :idempotency_conflict} = marker_decision([legal_conflict], marker)
  end

  test "adapter support prefixes comments with a parent-bound marker before fenced bodies" do
    marker =
      Transport.with_credential("marker-secret", fn ->
        {:ok, marker} =
          AdapterSupport.comment_marker(
            :github,
            "coverage/markers",
            "parent-1",
            "operation-1",
            "delivery-1",
            "```text\nunclosed fence"
          )

        marker
      end)

    body = AdapterSupport.append_marker("```text\nunclosed fence", marker.exact)

    assert body == marker.exact <> "\n\n```text\nunclosed fence"
    assert {:ok, {:found, %{"id" => 1}}} = marker_decision([%{"body" => body, "id" => 1}], marker)

    copied_inside_fence = %{
      "body" => "```text\n#{marker.exact}\nunclosed fence",
      "id" => 2
    }

    assert {:ok, :create} = marker_decision([copied_inside_fence], marker)
  end

  test "adapter support comment markers bind signatures to the parent external id" do
    parent_marker =
      comment_marker("parent-1", "operation-1", "delivery-1", "same body")

    other_parent_marker =
      comment_marker("parent-2", "operation-1", "delivery-1", "same body")

    assert parent_marker.exact != other_parent_marker.exact

    existing = %{"body" => AdapterSupport.append_marker("same body", other_parent_marker.exact), "id" => 1}

    assert {:error, :idempotency_conflict} = marker_decision([existing], parent_marker)
  end

  test "adapter support ignores unsigned and incorrectly signed marker lines" do
    marker = marker("operation-1", "delivery-1", ["head", "main", "intent"])
    unsigned = Regex.replace(~r/ signature-sha256=[0-9a-f]+\s/, marker.exact, " ")

    bad_signature =
      Regex.replace(
        ~r/signature-sha256=[0-9a-f]+/,
        marker.exact,
        "signature-sha256=#{String.duplicate("0", 64)}"
      )

    wrong_key_marker =
      Transport.with_credential("wrong-key", fn ->
        {:ok, marker} =
          AdapterSupport.operation_marker(
            :github,
            "coverage/markers",
            :ensure_change_request,
            "operation-1",
            "delivery-1",
            ["head", "main", "intent"]
          )

        marker
      end)

    items = [
      %{"body" => AdapterSupport.append_marker("body", unsigned), "id" => 1},
      %{"body" => AdapterSupport.append_marker("body", bad_signature), "id" => 2},
      %{"body" => AdapterSupport.append_marker("body", wrong_key_marker.exact), "id" => 3}
    ]

    assert {:ok, :create} = marker_decision(items, marker)
  end

  test "adapter support fails closed when marker signing has no runtime credential" do
    Process.delete({Transport, :credential})

    assert {:error, :invalid_configuration} =
             AdapterSupport.operation_marker(
               :github,
               "coverage/markers",
               :ensure_change_request,
               "operation-1",
               "delivery-1",
               ["head", "main", "intent"]
             )
  end

  test "health reports unavailable scenarios and rejects normalized write permissions" do
    assert {:error, :not_found} =
             Fake.health_check(config("missing", %{scenario: "missing"}))

    permissions = %{
      "repository_read" => "allowed",
      "branch_write" => "denied",
      "change_request_write" => "unknown"
    }

    assert {:error, :forbidden} =
             Fake.health_check(config("forbidden", %{permissions: permissions}))

    for repository_read <- [:denied, :unknown] do
      assert {:error, :forbidden} =
               Fake.health_check(
                 config("repository-read-#{repository_read}", %{
                   permissions: %{repository_read: repository_read}
                 })
               )
    end

    allowed = Map.new(permissions, fn {key, _value} -> {key, "allowed"} end)

    assert {:ok, health} = Fake.health_check(config("allowed", %{permissions: allowed}))
    assert health.permissions == %{repository_read: :allowed, branch_write: :allowed, change_request_write: :allowed}
  end

  test "mutations reject invalid inputs after accepting an operation identity" do
    identity = operation("invalid")

    assert {:error, :invalid_configuration} =
             Fake.ensure_remote_branch(%{}, %{name: "coverage/invalid", commit_sha: @sha_a}, identity)

    assert {:error, :invalid_configuration} =
             Fake.push_branch(config("invalid-push"), "coverage/invalid", @sha_b, identity)

    assert {:error, :invalid_configuration} =
             Fake.ensure_change_request(
               %{
                 repo: config("invalid-cr"),
                 head: "coverage/invalid",
                 base: "main",
                 body: "missing title",
                 draft: true
               },
               identity
             )

    assert {:error, :invalid_configuration} =
             Fake.set_draft(config("invalid-draft"), change_request("invalid-draft"), identity)
  end

  test "branch reconciliation conflicts and compare-and-set reads configured remote state" do
    branch_config = config("branch-conflict")
    branch = %{name: "coverage/conflict", commit_sha: @sha_a}

    assert {:ok, created} = Fake.ensure_remote_branch(branch_config, branch, operation("branch-a"))
    assert created.disposition == :reconciled

    assert {:error, :conflict} =
             Fake.ensure_remote_branch(
               branch_config,
               %{branch | commit_sha: @sha_b},
               operation("branch-b")
             )

    remote_config =
      config("configured-remote", %{remote_branches: %{"coverage/remote" => @sha_a}})

    push = operation("push", expected_remote_sha: @sha_a)

    assert {:ok, updated} = Fake.push_branch(remote_config, "coverage/remote", @sha_b, push)
    assert updated.disposition == :updated

    assert {:ok, replayed} = Fake.push_branch(remote_config, "coverage/remote", @sha_b, push)
    assert replayed.disposition == :reconciled

    assert {:error, :not_found} =
             Fake.push_branch(
               config("missing-remote"),
               "coverage/missing",
               @sha_b,
               operation("missing-remote", expected_remote_sha: @sha_a)
             )
  end

  test "concurrent compare-and-set permits exactly one remote branch update" do
    branch = "coverage/concurrent-cas"
    config = config("concurrent-cas", %{remote_branches: %{branch => @sha_a}})

    results =
      run_concurrently([
        fn ->
          Fake.push_branch(
            config,
            branch,
            @sha_b,
            operation("concurrent-push-b", expected_remote_sha: @sha_a)
          )
        end,
        fn ->
          Fake.push_branch(
            config,
            branch,
            @sha_c,
            operation("concurrent-push-c", expected_remote_sha: @sha_a)
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, %{disposition: :updated}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 1
  end

  test "change request identity supports stable replay and rejects another dedupe key" do
    attrs = %{
      repo: config("change-request"),
      head: "coverage/change-request",
      base: "main",
      title: "Coverage change request",
      body: "Stable intent",
      draft: true
    }

    assert {:ok, first} = Fake.ensure_change_request(attrs, operation("cr-first", "stable-dedupe"))
    assert {:ok, replay} = Fake.ensure_change_request(attrs, operation("cr-replay", "stable-dedupe"))
    assert replay.external_id == first.external_id

    assert {:error, :conflict} =
             Fake.ensure_change_request(attrs, operation("cr-conflict", "different-dedupe"))
  end

  test "concurrent callers cannot reuse one operation id with another dedupe key" do
    attrs = %{
      repo: config("concurrent-operation"),
      head: "coverage/concurrent-operation",
      base: "main",
      title: "Concurrent operation",
      body: "Stable intent",
      draft: true
    }

    results =
      run_concurrently([
        fn ->
          Fake.ensure_change_request(attrs,
            operation_id: "coverage-shared-operation",
            dedupe_key: "coverage-first-dedupe"
          )
        end,
        fn ->
          Fake.ensure_change_request(attrs,
            operation_id: "coverage-shared-operation",
            dedupe_key: "coverage-second-dedupe"
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, %ChangeRequest{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :idempotency_conflict}, &1)) == 1
  end

  test "close and invalid terminal inputs remain merge-free without consuming identity" do
    change_request = change_request("terminal")

    assert {:ok, %{action: :closed, external_id: external_id}} =
             Fake.close_or_comment(
               config("terminal"),
               change_request,
               operation("close", action: :close)
             )

    assert external_id == change_request.external_id

    comment = operation("comment", action: :comment, body: "Stable comment")

    assert {:ok, first_comment} =
             Fake.close_or_comment(config("terminal"), change_request, comment)

    assert {:ok, replayed_comment} =
             Fake.close_or_comment(config("terminal"), change_request, comment)

    assert replayed_comment == first_comment

    assert {:error, :idempotency_conflict} =
             Fake.close_or_comment(
               config("terminal"),
               change_request,
               operation("changed-comment", "coverage-dedupe-comment") ++
                 [action: :comment, body: "Changed comment"]
             )

    empty_comment = operation("empty-comment")

    assert {:error, :invalid_configuration} =
             Fake.close_or_comment(
               config("terminal"),
               change_request,
               empty_comment ++ [action: :comment, body: ""]
             )

    assert {:ok, %{action: :commented}} =
             Fake.close_or_comment(
               config("terminal"),
               change_request,
               empty_comment ++ [action: :comment, body: "Corrected comment"]
             )

    unsupported = operation("unsupported")

    assert {:error, :invalid_configuration} =
             Fake.close_or_comment(
               config("terminal"),
               change_request,
               unsupported ++ [action: :merge]
             )

    assert {:ok, %{action: :closed}} =
             Fake.close_or_comment(
               config("terminal"),
               change_request,
               unsupported ++ [action: :close]
             )
  end

  test "state normalizes all required-check outcomes and terminal observations" do
    change_request = change_request("state", false)

    assert {:ok, open_state} = Fake.state(config("state-open"), change_request)
    assert open_state.status == :open
    assert open_state.required_checks == []
    assert open_state.checks_status == :passed
    assert open_state.mergeability == :unknown

    checks = [
      %{"name" => "success", "status" => "success", "url" => "https://checks.test/success"},
      %{"name" => "running", "status" => "running"},
      %{"name" => "failure", "status" => "failure"},
      %{"name" => "other", "status" => "provider-specific"},
      %{ignored: true}
    ]

    assert {:ok, failed_state} =
             Fake.state(
               config("state-checks", %{
                 observed_state: %{required_checks: checks, mergeability: :conflicting}
               }),
               change_request
             )

    assert Enum.map(failed_state.required_checks, &{&1.name, &1.status}) == [
             {"failure", :failed},
             {"other", :unknown},
             {"running", :pending},
             {"success", :passed}
           ]

    assert failed_state.checks_status == :failed

    assert {:ok, passed_state} =
             Fake.state(
               config("state-passed", %{
                 observed_state: %{required_checks: [%{"name" => "success", "status" => "passed"}]}
               }),
               change_request
             )

    assert passed_state.checks_status == :passed

    assert {:ok, closed_state} =
             Fake.state(
               config("state-closed", %{observed_state: %{closed?: true}}),
               change_request
             )

    assert closed_state.status == :closed
  end

  defp config(suffix, settings \\ %{}) do
    %{
      provider: :fixture,
      settings:
        Map.merge(
          %{
            repository: "coverage/#{suffix}",
            base_branch: "main",
            scenario: "healthy"
          },
          settings
        )
    }
  end

  defp operation(suffix, extra \\ [])

  defp operation(suffix, dedupe_key) when is_binary(dedupe_key) do
    [operation_id: "coverage-operation-#{suffix}", dedupe_key: dedupe_key]
  end

  defp operation(suffix, extra) when is_list(extra) do
    [operation_id: "coverage-operation-#{suffix}", dedupe_key: "coverage-dedupe-#{suffix}"] ++
      extra
  end

  defp marker(operation_id, dedupe_key, intent_parts) do
    Transport.with_credential("marker-secret", fn ->
      {:ok, marker} =
        AdapterSupport.operation_marker(
          :github,
          "coverage/markers",
          :ensure_change_request,
          operation_id,
          dedupe_key,
          intent_parts
        )

      marker
    end)
  end

  defp comment_marker(parent_external_id, operation_id, dedupe_key, body) do
    Transport.with_credential("marker-secret", fn ->
      {:ok, marker} =
        AdapterSupport.comment_marker(
          :github,
          "coverage/markers",
          parent_external_id,
          operation_id,
          dedupe_key,
          body
        )

      marker
    end)
  end

  defp marker_decision(items, marker) do
    Transport.with_credential("marker-secret", fn ->
      AdapterSupport.marker_decision(items, "body", marker)
    end)
  end

  defp run_concurrently(functions) do
    caller = self()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            :run -> function.()
          end
        end)
      end)

    Enum.each(tasks, fn task ->
      pid = task.pid
      assert_receive {:ready, ^pid}
    end)

    Enum.each(tasks, &send(&1.pid, :run))
    Enum.map(tasks, &Task.await/1)
  end

  defp change_request(suffix, draft? \\ true) do
    %ChangeRequest{
      provider: :fixture,
      external_id: "coverage-change-request-#{suffix}",
      number: 1,
      url: "https://fixture.invalid/coverage/#{suffix}",
      repository: "coverage/#{suffix}",
      head_branch: "coverage/#{suffix}",
      base_branch: "main",
      title: "Coverage #{suffix}",
      draft?: draft?,
      disposition: :reconciled
    }
  end
end
