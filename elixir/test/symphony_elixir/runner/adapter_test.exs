defmodule SymphonyElixir.Runner.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Runner
  alias SymphonyRunner.{Policy, Protocol}

  defp policy do
    %Policy{
      image_digest: "sha256:abc",
      cpu_millis: 500,
      memory_bytes: 268_435_456,
      network: :disabled,
      mounts: [%{source: "/safe/task", target: "/workspace", mode: :ro}]
    }
  end

  test "adapter exposes create inspect execute and stop through operation IDs" do
    assert {:ok, %{ready: true}} = Runner.ping()
    assert {:ok, %{available: true}} = Runner.inspect_image("sha256:abc")
    assert {:ok, created} = Runner.create_sandbox("cp-op-create", "unit-1", policy())
    assert {:ok, %{sandbox_id: sandbox_id, status: "running"}} = Runner.inspect_sandbox(created.sandbox_id)

    exec = %Protocol.Exec{
      argv: ["mix", "test"],
      cwd: "/workspace",
      env_secret_refs: %{"TOKEN" => "secret:test-token"},
      timeout_ms: 1_000,
      output_limit_bytes: 128
    }

    assert {:ok, %{sandbox_id: ^sandbox_id, exit_code: 0}} =
             Runner.exec_in_sandbox("cp-op-exec", sandbox_id, exec)

    assert {:ok, %{sandbox_id: ^sandbox_id, status: "stopped"}} =
             Runner.stop_sandbox("cp-op-stop", sandbox_id)
  end
end
