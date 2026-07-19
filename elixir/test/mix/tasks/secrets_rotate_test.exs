defmodule Mix.Tasks.Secrets.RotateTest do
  use SymphonyElixir.DataCase, async: false

  alias Mix.Tasks.Secrets.Rotate
  alias SymphonyElixir.Security.SecretStore

  test "rotates secrets from external key environment only" do
    Mix.Task.reenable("app.start")
    old_shell = Mix.shell()
    previous_old_key = System.get_env("SYMPHONY_MASTER_KEY")
    previous_new_key = System.get_env("SYMPHONY_NEW_MASTER_KEY")
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(old_shell)
      restore_env("SYMPHONY_MASTER_KEY", previous_old_key)
      restore_env("SYMPHONY_NEW_MASTER_KEY", previous_new_key)
    end)

    old_key = SecretStore.current_key!()
    new_key = :crypto.strong_rand_bytes(32)
    {:ok, ref} = SecretStore.put("mix-rotate", "rotated-value", actor: "admin-1")

    System.put_env("SYMPHONY_MASTER_KEY", Base.encode64(old_key))
    System.put_env("SYMPHONY_NEW_MASTER_KEY", Base.encode64(new_key))

    assert :ok = Rotate.run([])
    assert_receive {:mix_shell, :info, ["Secret Store rotation complete"]}
    assert {:ok, "rotated-value"} = SecretStore.fetch(ref, key: new_key)
  end

  test "rejects key command arguments and sanitizes key environment errors" do
    previous_old_key = System.get_env("SYMPHONY_MASTER_KEY")
    previous_new_key = System.get_env("SYMPHONY_NEW_MASTER_KEY")

    on_exit(fn ->
      restore_env("SYMPHONY_MASTER_KEY", previous_old_key)
      restore_env("SYMPHONY_NEW_MASTER_KEY", previous_new_key)
    end)

    assert_raise Mix.Error, ~r/does not accept key arguments/, fn ->
      Rotate.run(["old-key", "new-key"])
    end

    invalid_key = "not-a-valid-master-key"
    System.put_env("SYMPHONY_MASTER_KEY", invalid_key)
    System.put_env("SYMPHONY_NEW_MASTER_KEY", invalid_key)

    error =
      assert_raise Mix.Error, fn ->
        Rotate.run([])
      end

    assert error.message =~ "SYMPHONY_MASTER_KEY"
    refute error.message =~ invalid_key
    refute error.message =~ "SYMPHONY_NEW_MASTER_KEY=#{invalid_key}"
  end

  test "sanitizes rotation failures from the store" do
    Mix.Task.reenable("app.start")
    old_shell = Mix.shell()
    previous_old_key = System.get_env("SYMPHONY_MASTER_KEY")
    previous_new_key = System.get_env("SYMPHONY_NEW_MASTER_KEY")
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(old_shell)
      restore_env("SYMPHONY_MASTER_KEY", previous_old_key)
      restore_env("SYMPHONY_NEW_MASTER_KEY", previous_new_key)
    end)

    {:ok, _ref} = SecretStore.put("mix-rotate-failure", "rotated-value", actor: "admin-1")

    System.put_env("SYMPHONY_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.put_env("SYMPHONY_NEW_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    error =
      assert_raise Mix.Error, fn ->
        Rotate.run([])
      end

    assert error.message =~ "secret rotation failed: decrypt_failed"
    refute error.message =~ "rotated-value"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
