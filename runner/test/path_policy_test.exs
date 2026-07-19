defmodule SymphonyRunner.PathPolicyTest do
  use ExUnit.Case, async: false

  alias SymphonyRunner.PathPolicy

  test "mount sources are scoped to the simulated safe root without traversal" do
    assert PathPolicy.safe_mount_source?("/safe")
    assert PathPolicy.safe_mount_source?("/safe/task")
    refute PathPolicy.safe_mount_source?("/")
    refute PathPolicy.safe_mount_source?("/safeevil/task")
    refute PathPolicy.safe_mount_source?("/safe/../host")
    refute PathPolicy.safe_mount_source?("/safe//task")
    refute PathPolicy.safe_mount_source?("/var/run/docker.sock")
    refute PathPolicy.safe_mount_source?(nil)
  end

  test "workspace paths reject traversal-like segments" do
    assert PathPolicy.workspace_path?("/workspace")
    assert PathPolicy.workspace_path?("/workspace/app")
    refute PathPolicy.workspace_path?("/workspace/../../host")
    refute PathPolicy.workspace_path?("/workspace//app")
    refute PathPolicy.workspace_path?("/tmp")
    refute PathPolicy.workspace_path?(nil)
    refute PathPolicy.writable_workspace_path?("/workspace")
    assert PathPolicy.writable_workspace_path?("/workspace/writable/cache")
    refute PathPolicy.writable_workspace_path?(nil)
  end

  test "mount source root is runner-owned and rejects symlink escape" do
    previous = Application.get_env(:symphony_runner, :safe_mount_source_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-safe-root-#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "symphony-runner-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "escape"))

    Application.put_env(:symphony_runner, :safe_mount_source_root, root)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_runner, :safe_mount_source_root)
      else
        Application.put_env(:symphony_runner, :safe_mount_source_root, previous)
      end

      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    assert PathPolicy.safe_mount_source?(Path.join(root, "task"))
    refute PathPolicy.safe_mount_source?(Path.join(root, "escape/task"))
  end
end
