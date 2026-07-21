defmodule SymphonyElixir.SourceControlFacadeCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.ChangeRequest
  alias SymphonyElixir.SourceControl.Transport

  @credential_ref "00000000-0000-0000-0000-000000000008"
  @credential "facade-only-secret"
  @operation [operation_id: "task-8:facade", dedupe_key: "issue-8:facade"]

  defmodule CaptureTransport do
    @moduledoc false

    def request(request, {owner, response}) do
      credential =
        Process.get({SymphonyElixir.SourceControl.Transport, :credential})

      send(owner, {:source_control_request, request, credential})
      {:ok, response}
    end
  end

  defmodule RaisingTransport do
    @moduledoc false

    def request(_request, _state), do: raise("facade-only-secret")
  end

  defmodule ThrowingTransport do
    @moduledoc false

    def request(_request, _state), do: throw({:secret, "facade-only-secret"})
  end

  defmodule RateLimitedTransport do
    @moduledoc false

    def request(_request, _state) do
      {:ok, %{status: 429, headers: %{"retry-after" => "2"}, body: %{}}}
    end
  end

  test "exports exactly the eight provider-neutral callbacks and no merge callback" do
    assert SourceControl.behaviour_info(:callbacks) |> Enum.sort() ==
             [
               close_or_comment: 3,
               ensure_change_request: 2,
               ensure_remote_branch: 3,
               health_check: 1,
               push_branch: 4,
               resolve_baseline: 2,
               set_draft: 3,
               state: 2
             ]
             |> Enum.sort()

    refute function_exported?(SourceControl, :merge_change_request, 3)
  end

  test "accepts only the provider allowlist including a string GitLab provider" do
    assert {:error, :invalid_configuration} = SourceControl.health_check(%{"provider" => "gitlab"})
    assert {:error, :unsupported_provider} = SourceControl.health_check(%{provider: __MODULE__})
  end

  test "validates mutation identity and operation-specific configuration before dispatch" do
    assert {:error, :missing_operation_identity} =
             SourceControl.push_branch(
               fixture_config(),
               "symphony/issue-8",
               String.duplicate("b", 40),
               expected_remote_sha: String.duplicate("a", 40)
             )

    assert {:error, :invalid_configuration} =
             SourceControl.push_branch(
               fixture_config(),
               "symphony/issue-8",
               String.duplicate("b", 40),
               @operation ++ [expected_remote_sha: " "]
             )

    assert {:error, :invalid_configuration} =
             SourceControl.ensure_change_request(%{repo: :invalid}, @operation)

    assert {:error, :missing_operation_identity} =
             SourceControl.set_draft(fixture_config(), change_request(), [])

    assert {:error, :invalid_configuration} =
             SourceControl.set_draft(fixture_config(), change_request(), @operation)

    assert {:error, :invalid_configuration} =
             SourceControl.close_or_comment(
               fixture_config(),
               change_request(),
               @operation ++ [action: :merge]
             )
  end

  test "keeps credentials process-local while recursively stripping runtime copies" do
    response = %{
      status: 200,
      headers: %{},
      body: %{"commit" => %{"sha" => String.duplicate("c", 40)}}
    }

    config =
      github_config({CaptureTransport, {self(), response}})
      |> put_in([:settings, :credential], "nested-atom-secret")
      |> put_in([:settings, "credential"], "nested-string-secret")
      |> put_in([:settings, :nested], [%{credential: "nested-list-secret"}])

    assert {:ok, baseline} = SourceControl.resolve_baseline(config, "main")
    assert baseline.commit_sha == String.duplicate("c", 40)

    assert_receive {:source_control_request, request, @credential}
    assert get_in(request, [:headers, "authorization"]) == "Bearer #{@credential}"
    refute inspect(request) =~ "nested-atom-secret"
    refute inspect(request) =~ "nested-string-secret"
    refute inspect(request) =~ "nested-list-secret"
    assert Process.get({Transport, :credential}) == nil
  end

  test "restores a prior process-local credential after adapter dispatch" do
    key = {Transport, :credential}
    Process.put(key, "outer-secret")

    response = %{
      status: 200,
      headers: %{},
      body: %{"commit" => %{"sha" => String.duplicate("d", 40)}}
    }

    assert {:ok, _baseline} =
             SourceControl.resolve_baseline(
               github_config({CaptureTransport, {self(), response}}),
               "main"
             )

    assert_receive {:source_control_request, _request, @credential}
    assert Process.get(key) == "outer-secret"
  end

  test "preserves a bounded rate-limit result from an allowlisted provider" do
    config =
      github_config({RateLimitedTransport, :unused})
      |> put_in([:settings, :max_read_attempts], 1)

    assert {:error, {:rate_limited, 2}} = SourceControl.health_check(config)
  end

  test "sanitizes raised and thrown provider transport failures" do
    for transport <- [RaisingTransport, ThrowingTransport] do
      assert {:error, :health_check_failed} =
               SourceControl.health_check(github_config({transport, :unused}))

      assert Process.get({Transport, :credential}) == nil
    end
  end

  test "public guards reject malformed calls rather than dispatching them" do
    source_control = Process.get(:source_control_facade_for_guard_test, SourceControl)

    assert_raise FunctionClauseError, fn -> source_control.health_check([]) end
    assert_raise FunctionClauseError, fn -> source_control.resolve_baseline(%{}, :main) end

    assert_raise FunctionClauseError, fn ->
      source_control.ensure_remote_branch(%{}, %{}, %{})
    end

    assert_raise FunctionClauseError, fn ->
      source_control.push_branch(%{}, "main", "sha", %{})
    end

    assert_raise FunctionClauseError, fn ->
      source_control.ensure_change_request(%{}, %{})
    end

    assert_raise FunctionClauseError, fn -> source_control.state(%{}, %{}) end

    assert_raise FunctionClauseError, fn ->
      source_control.set_draft(%{}, %{}, [])
    end

    assert_raise FunctionClauseError, fn ->
      source_control.close_or_comment(%{}, %{}, [])
    end
  end

  defp fixture_config do
    %{
      provider: :fixture,
      settings: %{repository: "symphony/fixture", base_branch: "main", scenario: "healthy"}
    }
  end

  defp github_config(transport) do
    %{
      provider: :github,
      credential_ref: @credential_ref,
      credential: @credential,
      settings: %{
        repository: "acme/widget",
        base_branch: "main",
        api_base_url: "https://api.github.test",
        bot_actor_id: "424242"
      },
      transport: transport
    }
  end

  defp change_request do
    %ChangeRequest{
      provider: :fixture,
      external_id: "issue-8",
      number: 8,
      repository: "symphony/fixture",
      head_branch: "symphony/issue-8",
      base_branch: "main",
      title: "Issue 8",
      draft?: true,
      disposition: :reconciled
    }
  end
end
