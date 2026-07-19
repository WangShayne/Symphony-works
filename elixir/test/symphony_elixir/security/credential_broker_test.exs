defmodule SymphonyElixir.Security.CredentialBrokerTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Security.{CredentialBroker, SecretStore}

  test "broker releases plaintext only inside callback and returns redacted adapter result" do
    {:ok, ref} = SecretStore.put("provider-token", "plain-provider-token", actor: "admin-1")
    parent = self()

    assert {:ok, %{status: :ok, credential_ref: ^ref}} =
             CredentialBroker.with_secret(ref, :provider_probe, fn credential ->
               send(parent, {:credential_seen, credential})
               {:ok, %{status: :ok, credential_ref: ref}}
             end)

    assert_receive {:credential_seen, "plain-provider-token"}
    refute inspect(ref) =~ "plain-provider-token"
  end

  test "broker rejects callbacks that try to return plaintext" do
    {:ok, ref} = SecretStore.put("provider-token", "plain-provider-token", actor: "admin-1")

    assert {:error, :plaintext_returned} =
             CredentialBroker.with_secret(ref, :provider_probe, fn credential ->
               {:ok, credential}
             end)
  end

  test "broker normalizes adapter errors and rejects malformed requests" do
    {:ok, ref} = SecretStore.put("provider-token", "plain-provider-token", actor: "admin-1")

    assert {:ok, :pong} = CredentialBroker.with_secret(ref, "probe", fn _credential -> :pong end)

    assert {:error, :adapter_failed} =
             CredentialBroker.with_secret(ref, :probe, fn _credential ->
               {:error, :adapter_failed}
             end)

    assert {:error, :invalid_purpose} = CredentialBroker.with_secret(ref, "", fn _credential -> :ok end)
    assert {:error, :invalid_purpose} = CredentialBroker.with_secret(ref, 123, fn _credential -> :ok end)
    assert {:error, :invalid_callback} = CredentialBroker.with_secret(ref, :probe, :not_a_function)
    assert {:error, :invalid_reference} = CredentialBroker.with_secret(%{}, :probe, fn _credential -> :ok end)

    assert {:error, :plaintext_returned} =
             CredentialBroker.with_secret(ref, :probe, fn credential -> {:ok, [safe: %{value: credential}]} end)

    assert {:error, :plaintext_returned} =
             CredentialBroker.with_secret(ref, :probe, fn credential -> {:ok, "Bearer #{credential}"} end)

    assert {:error, :plaintext_returned} =
             CredentialBroker.with_secret(ref, :probe, fn credential ->
               {:ok, %{headers: ["authorization: Bearer #{credential}"]}}
             end)

    assert {:error, :plaintext_returned} =
             CredentialBroker.with_secret(ref, :probe, fn credential ->
               {:ok, :unsafe, "Bearer #{credential}"}
             end)

    assert {:error, :callback_failed} =
             CredentialBroker.with_secret(ref, :probe, fn credential ->
               raise "failed with #{credential}"
             end)

    assert {:error, :callback_failed} =
             CredentialBroker.with_secret(ref, :probe, fn _credential ->
               throw(:adapter_threw)
             end)
  end
end
