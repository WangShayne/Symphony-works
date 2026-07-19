defmodule SymphonyRunner.PolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyRunner.Policy

  defp policy(overrides) do
    struct!(
      Policy,
      Map.merge(
        %{
          image_digest: "sha256:abc",
          cpu_millis: 500,
          memory_bytes: 268_435_456,
          network: :disabled,
          mounts: [%{source: "/safe/task", target: "/workspace", mode: :ro}]
        },
        Map.new(overrides)
      )
    )
  end

  test "policy validates bounded resource network and mount fields" do
    assert :ok =
             Policy.validate(
               policy(mounts: [%{source: "/safe/task", target: "/workspace/app", mode: :ro}])
             )

    assert :ok =
             Policy.validate(
               policy(
                 mounts: [%{source: "/safe/task", target: "/workspace/writable/cache", mode: :rw}]
               )
             )

    assert {:error, :invalid_policy} = Policy.validate(%{})
    assert {:error, :invalid_image_digest} = Policy.validate(policy(image_digest: "latest"))
    assert {:error, :invalid_cpu_millis} = Policy.validate(policy(cpu_millis: 99))
    assert {:error, :invalid_memory_bytes} = Policy.validate(policy(memory_bytes: 1))
    assert {:error, :invalid_network} = Policy.validate(policy(network: :host))
    assert {:error, :invalid_mounts} = Policy.validate(policy(mounts: []))

    assert {:error, :invalid_mount_source} =
             Policy.validate(
               policy(mounts: [%{source: "relative", target: "/workspace", mode: :rw}])
             )

    assert {:error, :invalid_mount_source} =
             Policy.validate(policy(mounts: [%{source: "/", target: "/workspace", mode: :rw}]))

    assert {:error, :invalid_mount_target} =
             Policy.validate(
               policy(mounts: [%{source: "/safe/task", target: "/host", mode: :rw}])
             )

    assert {:error, :invalid_mount_target} =
             Policy.validate(
               policy(
                 mounts: [%{source: "/safe/task", target: "/workspace/../../host", mode: :rw}]
               )
             )

    assert {:error, :invalid_mount_mode} =
             Policy.validate(
               policy(mounts: [%{source: "/safe/task", target: "/workspace", mode: :rw}])
             )

    assert {:error, :invalid_mount} =
             Policy.validate(
               policy(mounts: [%{source: "/safe/task", target: "/workspace", mode: :exec}])
             )
  end

  test "wire decoder accepts safe values and rejects malformed policy maps" do
    wire = %{
      "image_digest" => "sha256:abc",
      "cpu_millis" => 500,
      "memory_bytes" => 268_435_456,
      "network" => "egress",
      "mounts" => [%{"source" => "/safe/task", "target" => "/workspace", "mode" => "ro"}]
    }

    assert {:ok, decoded} = Policy.from_wire(wire)
    assert decoded.network == :egress
    assert decoded.mounts == [%{source: "/safe/task", target: "/workspace", mode: :ro}]

    assert {:error, :invalid_policy} = Policy.from_wire(%{})
    assert {:error, :invalid_network} = Policy.from_wire(%{wire | "network" => "host"})
    assert {:error, :invalid_mounts} = Policy.from_wire(%{wire | "mounts" => []})

    assert {:error, :invalid_mount} =
             Policy.from_wire(%{wire | "mounts" => [%{"source" => "/safe/task"}]})

    assert {:error, :invalid_mount_mode} =
             Policy.from_wire(%{
               wire
               | "mounts" => [
                   %{"source" => "/safe/task", "target" => "/workspace", "mode" => "exec"}
                 ]
             })
  end
end
