defmodule SymphonyRunner.ProtocolTest do
  use ExUnit.Case, async: true

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

  test "create_sandbox is bounded and round-trips without arbitrary host commands" do
    request = Protocol.create_sandbox("op-1", "unit-1", policy())

    assert {:ok, decoded} = request |> Protocol.encode() |> Protocol.decode_request()
    assert decoded.version == 1
    assert decoded.operation == :create_sandbox
    refute Map.has_key?(decoded, :command)
    assert decoded.policy.image_digest == "sha256:abc"
  end

  test "exec_in_sandbox accepts only structured argv and workspace cwd" do
    exec = %Protocol.Exec{
      argv: ["mix", "test"],
      cwd: "/workspace/app",
      env_secret_refs: %{"OPENAI_API_KEY" => "secret:model-key"},
      timeout_ms: 10_000,
      output_limit_bytes: 4096
    }

    request = Protocol.exec_in_sandbox("op-2", "sandbox-1", exec)

    assert {:ok, decoded} = request |> Protocol.encode() |> Protocol.decode_request()
    assert decoded.exec.argv == ["mix", "test"]
    refute Map.has_key?(decoded.exec, :command)
  end

  test "codec normalizes protocol and policy errors" do
    invalid_policy = %{
      policy()
      | mounts: [%{source: "/var/run/docker.sock", target: "/workspace", mode: :rw}]
    }

    request = Protocol.create_sandbox("op-3", "unit-1", invalid_policy)

    assert {:error, %{code: :invalid_mount_source, message: message}} =
             request |> Protocol.encode() |> Protocol.decode_request()

    assert message != ""
    assert {:error, %{code: :invalid_payload}} = Protocol.decode_request("bad")
  end

  test "mutation operation IDs are required and versioned responses round-trip" do
    request = Protocol.stop_sandbox(nil, "sandbox-1")

    assert {:error, %{code: :invalid_operation_id}} =
             request |> Protocol.encode() |> Protocol.decode_request()

    response = Protocol.ok("op-4", %{sandbox_id: "sandbox-1"})
    assert {:ok, decoded} = response |> Protocol.encode() |> Protocol.decode_response()
    assert decoded.ok
    assert decoded.version == 1
    assert decoded.result == %{sandbox_id: "sandbox-1"}

    response = Protocol.error("op-5", :invalid_request, "request frame is invalid")
    assert {:ok, decoded_error} = response |> Protocol.encode() |> Protocol.decode_response()
    refute decoded_error.ok
    assert decoded_error.error == %{code: :invalid_request, message: "request frame is invalid"}
  end

  test "request validator rejects malformed version operation and payload shapes" do
    refute Protocol.mutation?(:inspect_sandbox)
    assert Protocol.mutation?(:stop_sandbox)

    assert {:error, %{code: :invalid_payload}} = Protocol.decode_request(:not_binary)
    assert {:error, %{code: :invalid_payload}} = Protocol.decode_response(:not_binary)

    unsupported_version =
      :erlang.term_to_binary(%{
        "type" => "request",
        "version" => 2,
        "operation" => "ping"
      })

    invalid_request =
      :erlang.term_to_binary(%{
        "type" => "request",
        "version" => 1,
        "operation" => "runner_operation_atom_that_does_not_exist"
      })

    invalid_operation_type =
      :erlang.term_to_binary(%{
        "type" => "request",
        "version" => 1,
        "operation" => 1
      })

    invalid_response =
      :erlang.term_to_binary(%{
        "type" => "response",
        "version" => 1,
        "operation_id" => "op",
        "ok" => false,
        "error" => %{"code" => :bad, "message" => "bad"}
      })

    assert {:error, %{code: :invalid_request}} = Protocol.decode_request(unsupported_version)
    assert {:error, %{code: :unsupported_operation}} = Protocol.decode_request(invalid_request)

    assert {:error, %{code: :unsupported_operation}} =
             Protocol.decode_request(invalid_operation_type)

    assert {:error, %{code: :invalid_response}} = Protocol.decode_response(invalid_response)

    assert {:error, %{code: :unsupported_version_or_operation}} =
             Protocol.validate_request(%Protocol.Request{})

    assert {:error, %{code: :invalid_request}} = Protocol.validate_request(%{})
  end

  test "request validator rejects invalid operation-specific fields" do
    assert {:error, %{code: :invalid_image_digest}} =
             Protocol.inspect_image(nil) |> Protocol.validate_request()

    assert {:error, %{code: :invalid_unit_id}} =
             Protocol.create_sandbox("op", "bad id", policy()) |> Protocol.validate_request()

    assert {:error, %{code: :invalid_sandbox_id}} =
             Protocol.inspect_sandbox("bad id") |> Protocol.validate_request()

    assert {:error, %{code: :invalid_repository}} =
             Protocol.prepare_repository("op", "") |> Protocol.validate_request()

    assert {:error, %{code: :invalid_worktree}} =
             Protocol.merge_branch("op", "", "branch") |> Protocol.validate_request()

    assert {:error, %{code: :invalid_worktree}} =
             Protocol.cleanup_workspace("op", "") |> Protocol.validate_request()
  end

  test "exec validator rejects unsafe secret timeout and output fields" do
    valid_exec = %Protocol.Exec{
      argv: ["mix"],
      cwd: "/workspace",
      env_secret_refs: %{"TOKEN" => "secret:ref"},
      timeout_ms: 1_000,
      output_limit_bytes: 64
    }

    assert {:error, %{code: :invalid_exec}} =
             %Protocol.Request{
               version: 1,
               operation: :exec_in_sandbox,
               operation_id: "op",
               sandbox_id: "sandbox"
             }
             |> Protocol.validate_request()

    assert {:error, %{code: :invalid_env_secret_refs}} =
             Protocol.exec_in_sandbox("op", "sandbox", %{
               valid_exec
               | env_secret_refs: %{"token" => "plain"}
             })
             |> Protocol.validate_request()

    assert {:error, %{code: :invalid_env_secret_refs}} =
             Protocol.exec_in_sandbox("op", "sandbox", %{valid_exec | env_secret_refs: []})
             |> Protocol.validate_request()

    assert {:error, %{code: :invalid_env_secret_refs}} =
             Protocol.exec_in_sandbox("op", "sandbox", %{
               valid_exec
               | env_secret_refs: %{1 => "secret:ref"}
             })
             |> Protocol.validate_request()

    assert {:error, %{code: :invalid_timeout_ms}} =
             Protocol.exec_in_sandbox("op", "sandbox", %{valid_exec | timeout_ms: 0})
             |> Protocol.validate_request()

    assert {:error, %{code: :invalid_output_limit_bytes}} =
             Protocol.exec_in_sandbox("op", "sandbox", %{valid_exec | output_limit_bytes: 0})
             |> Protocol.validate_request()

    assert {:error, %{code: :invalid_cwd}} =
             Protocol.exec_in_sandbox("op", "sandbox", %{
               valid_exec
               | cwd: "/workspace/../../host"
             })
             |> Protocol.validate_request()

    invalid_exec =
      :erlang.term_to_binary(%{
        "type" => "request",
        "version" => 1,
        "operation" => "exec_in_sandbox",
        "operation_id" => "op",
        "sandbox_id" => "sandbox",
        "exec" => %{"argv" => []}
      })

    assert {:error, %{code: :invalid_exec}} = Protocol.decode_request(invalid_exec)
  end

  test "policy validator maps all bounded policy failures into protocol errors" do
    assert {:error, %{code: :invalid_policy}} =
             %Protocol.Request{
               version: 1,
               operation: :create_sandbox,
               operation_id: "op",
               unit_id: "unit"
             }
             |> Protocol.validate_request()

    invalid_cases = [
      {%{policy() | cpu_millis: 99}, :invalid_cpu_millis},
      {%{policy() | memory_bytes: 1}, :invalid_memory_bytes},
      {%{policy() | network: :host}, :invalid_network},
      {%{policy() | mounts: []}, :invalid_mounts},
      {%{policy() | mounts: [%{source: "/safe/task", target: "/host", mode: :rw}]},
       :invalid_mount_target},
      {%{policy() | mounts: [%{source: "/safe/task", target: "/workspace", mode: :exec}]},
       :invalid_mount}
    ]

    assert_invalid_mount_mode_frame()

    for {invalid_policy, code} <- invalid_cases do
      assert {:error, %{code: ^code, message: message}} =
               Protocol.create_sandbox("op", "unit", invalid_policy)
               |> Protocol.validate_request()

      assert message != ""
    end
  end

  defp assert_invalid_mount_mode_frame do
    wire = %{
      "image_digest" => "sha256:abc",
      "cpu_millis" => 500,
      "memory_bytes" => 268_435_456,
      "network" => "disabled",
      "mounts" => [%{"source" => "/safe/task", "target" => "/workspace", "mode" => "exec"}]
    }

    assert {:error, %{code: :invalid_mount_mode, message: message}} =
             :erlang.term_to_binary(%{
               "type" => "request",
               "version" => 1,
               "operation" => "create_sandbox",
               "operation_id" => "op",
               "unit_id" => "unit",
               "policy" => wire
             })
             |> Protocol.decode_request()

    assert message != ""
  end
end
