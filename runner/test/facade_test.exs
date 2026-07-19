defmodule SymphonyRunnerFacadeTest do
  use ExUnit.Case, async: false

  alias SymphonyRunner.{Policy, Protocol, Server}

  defp policy do
    %Policy{
      image_digest: "sha256:abc",
      cpu_millis: 500,
      memory_bytes: 268_435_456,
      network: :disabled,
      mounts: [%{source: "/safe/task", target: "/workspace", mode: :ro}]
    }
  end

  test "facade default server supports the sandbox lifecycle" do
    start_supervised!({Server, backend: SymphonyRunner.Backend.Fake})

    assert {:ok, %{ready: true}} = SymphonyRunner.ping()
    assert {:ok, %{available: true}} = SymphonyRunner.inspect_image("sha256:abc")
    assert {:ok, created} = SymphonyRunner.create_sandbox("default-create", "unit-1", policy())
    assert {:ok, %{status: "running"}} = SymphonyRunner.inspect_sandbox(created.sandbox_id)

    exec = %Protocol.Exec{
      argv: ["echo", "ok"],
      cwd: "/workspace",
      env_secret_refs: %{"TOKEN" => "secret:test-token"},
      timeout_ms: 1_000,
      output_limit_bytes: 64
    }

    assert {:ok, %{exit_code: 0}} =
             SymphonyRunner.exec_in_sandbox("default-exec", created.sandbox_id, exec)

    assert {:ok, %{status: "stopped"}} =
             SymphonyRunner.stop_sandbox("default-stop", created.sandbox_id)
  end
end
