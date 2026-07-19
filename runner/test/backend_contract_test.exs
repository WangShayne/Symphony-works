defmodule SymphonyRunner.BackendContractTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyRunner.{Policy, Protocol, Server}

  defp start_runner!(context) do
    name = :"#{context.test}"
    start_supervised!({Server, name: name, backend: SymphonyRunner.Backend.Fake})
  end

  defp policy do
    %Policy{
      image_digest: "sha256:abc",
      cpu_millis: 500,
      memory_bytes: 268_435_456,
      network: :egress,
      mounts: [%{source: "/safe/task", target: "/workspace", mode: :ro}]
    }
  end

  defp exec do
    %Protocol.Exec{
      argv: ["echo", "ok"],
      cwd: "/workspace",
      env_secret_refs: %{"TOKEN" => "secret:test-token"},
      timeout_ms: 1_000,
      output_limit_bytes: 64
    }
  end

  test "fake backend supports sandbox create inspect execute and stop through the server",
       context do
    runner = start_runner!(context)

    assert {:ok, %{ready: true, backend: "fake", protocol_version: 1}} =
             Server.call(runner, Protocol.ping())

    assert {:ok, %{available: true}} = Server.call(runner, Protocol.inspect_image("sha256:abc"))

    assert {:error, %{code: :image_not_found}} =
             Server.call(runner, Protocol.inspect_image("sha256:def"))

    assert {:ok, created} =
             Server.call(runner, Protocol.create_sandbox("op-create", "unit-1", policy()))

    assert %{sandbox_id: sandbox_id, status: "running"} = created

    assert {:ok, %{sandbox_id: ^sandbox_id, status: "running"}} =
             Server.call(runner, Protocol.inspect_sandbox(sandbox_id))

    assert {:ok, %{exit_code: 0, stdout: "simulated:echo ok"}} =
             Server.call(runner, Protocol.exec_in_sandbox("op-exec", sandbox_id, exec()))

    assert {:ok, %{sandbox_id: ^sandbox_id, status: "stopped"}} =
             Server.call(runner, Protocol.stop_sandbox("op-stop", sandbox_id))

    assert {:ok, %{sandbox_id: ^sandbox_id, status: "stopped"}} =
             Server.call(runner, Protocol.inspect_sandbox(sandbox_id))

    assert {:error, %{code: :sandbox_not_found}} =
             Server.call(runner, Protocol.inspect_sandbox("sandbox-missing"))

    assert {:error, %{code: :sandbox_stopped}} =
             Server.call(runner, Protocol.exec_in_sandbox("op-exec-stopped", sandbox_id, exec()))
  end

  test "operation IDs replay deterministically and reject conflicting reuse", context do
    runner = start_runner!(context)
    request = Protocol.create_sandbox("op-replay", "unit-1", policy())

    assert {:ok, first} = Server.call(runner, request)
    assert {:ok, ^first} = Server.call(runner, request)

    conflict = Protocol.create_sandbox("op-replay", "unit-2", policy())
    assert {:error, %{code: :operation_conflict}} = Server.call(runner, conflict)
  end

  test "concurrent creates keep isolated fake backend state", context do
    runner = start_runner!(context)

    results =
      1..20
      |> Task.async_stream(
        fn index ->
          Server.call(
            runner,
            Protocol.create_sandbox("op-concurrent-#{index}", "unit-#{index}", policy())
          )
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{status: "running"}}, &1))
    sandbox_ids = Enum.map(results, fn {:ok, result} -> result.sandbox_id end)
    assert length(Enum.uniq(sandbox_ids)) == 20
  end

  test "server rejects raw command-shaped exec and host cwd before backend dispatch", context do
    runner = start_runner!(context)
    {:ok, created} = Server.call(runner, Protocol.create_sandbox("op-safe", "unit-1", policy()))

    raw_command = %Protocol.Exec{
      argv: [],
      cwd: "/workspace",
      env_secret_refs: %{},
      timeout_ms: 1_000,
      output_limit_bytes: 64
    }

    host_cwd = %{exec() | cwd: "/tmp"}

    assert {:error, %{code: :invalid_argv}} =
             Server.call(
               runner,
               Protocol.exec_in_sandbox("op-raw", created.sandbox_id, raw_command)
             )

    assert {:error, %{code: :invalid_cwd}} =
             Server.call(
               runner,
               Protocol.exec_in_sandbox("op-host", created.sandbox_id, host_cwd)
             )

    assert {:error, %{code: :sandbox_not_found}} =
             Server.call(
               runner,
               Protocol.exec_in_sandbox("op-missing-exec", "sandbox-missing", exec())
             )

    assert {:error, %{code: :sandbox_not_found}} =
             Server.call(runner, Protocol.stop_sandbox("op-missing-stop", "sandbox-missing"))
  end

  test "repository and worktree operations are idempotent operation contracts", context do
    runner = start_runner!(context)

    assert {:ok, repository} =
             Server.call(
               runner,
               Protocol.prepare_repository("op-repo", "git@example.test/repo.git")
             )

    assert {:ok, ^repository} =
             Server.call(
               runner,
               Protocol.prepare_repository("op-repo", "git@example.test/repo.git")
             )

    assert {:ok, worktree} =
             Server.call(
               runner,
               Protocol.create_worktree("op-worktree", repository.repository, "feature")
             )

    assert {:ok, %{merged: true}} =
             Server.call(
               runner,
               Protocol.merge_branch("op-merge", worktree.worktree_id, "feature")
             )

    assert {:ok, %{status: "removed"}} =
             Server.call(runner, Protocol.cleanup_workspace("op-cleanup", worktree.worktree_id))
  end

  test "top-level facade delegates to the configured server and output limits are bounded",
       context do
    runner = start_runner!(context)

    assert {:ok, %{ready: true}} = SymphonyRunner.ping(runner)
    assert {:ok, %{available: true}} = SymphonyRunner.inspect_image(runner, "sha256:abc")

    assert {:ok, created} =
             SymphonyRunner.create_sandbox(runner, "op-facade-create", "unit-1", policy())

    assert {:ok, %{status: "running"}} =
             SymphonyRunner.inspect_sandbox(runner, created.sandbox_id)

    truncated = %{exec() | argv: ["printf", "123456789"], output_limit_bytes: 12}

    assert {:ok, %{stdout: "simulated:pr"}} =
             SymphonyRunner.exec_in_sandbox(
               runner,
               "op-facade-exec",
               created.sandbox_id,
               truncated
             )

    assert {:ok, %{status: "stopped"}} =
             SymphonyRunner.stop_sandbox(runner, "op-facade-stop", created.sandbox_id)
  end

  test "server emits structured operation logs without payload contents", context do
    runner = start_runner!(context)

    log =
      capture_log(fn ->
        assert {:ok, _created} =
                 Server.call(runner, Protocol.create_sandbox("op-log-create", "unit-1", policy()))

        assert {:error, %{code: :invalid_sandbox_id}} =
                 Server.call(runner, Protocol.inspect_sandbox("bad id"))
      end)

    assert log =~ "runner operation completed"
    assert log =~ "runner operation failed"
    refute log =~ "/safe/task"
    refute log =~ "secret:"
  end
end
