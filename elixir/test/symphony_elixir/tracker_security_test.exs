defmodule SymphonyElixir.TrackerSecurityTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Security.SecretStore
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Transport.Fixture, as: Transport

  test "the real credential broker injects the token but redacts a provider error body" do
    secret = "real-broker-tracker-secret"
    {:ok, reference} = SecretStore.put("tracker-token", secret, actor: "admin-1")
    credential_ref = SecretStore.export_reference(reference)

    handler = fn request ->
      assert request.headers["authorization"] == "Bearer #{secret}"

      {:ok,
       %{
         status: 503,
         headers: %{},
         body: %{"message" => "provider echoed #{secret}"}
       }}
    end

    assert {:error, %{provider: "github", code: :provider_unavailable, retryable: true} = error} =
             Tracker.health_check(
               github_config(credential_ref),
               tracker_opts(transport: {Transport, handler: handler})
             )

    refute inspect(error) =~ secret
    refute inspect(error) =~ credential_ref
  end

  test "transport exceptions containing the token become one generic redacted error" do
    secret = "real-broker-transport-secret"
    {:ok, reference} = SecretStore.put("tracker-token", secret, actor: "admin-1")
    credential_ref = SecretStore.export_reference(reference)
    handler = fn _request -> raise "outbound failure #{secret}" end

    assert {:error, %{provider: "github", code: :transport_failed, retryable: true} = error} =
             Tracker.health_check(
               github_config(credential_ref),
               tracker_opts(transport: {Transport, handler: handler})
             )

    refute inspect(error) =~ secret
    refute inspect(error) =~ credential_ref
  end

  test "every brokered Tracker operation redacts transport failures and webhook secrets" do
    secret = "real-broker-all-operations-secret"
    {:ok, reference} = SecretStore.put("tracker-token", secret, actor: "admin-1")
    credential_ref = SecretStore.export_reference(reference)
    config = github_config(credential_ref)
    handler = fn _request -> raise "provider echoed #{secret}" end
    opts = tracker_opts(transport: {Transport, handler: handler})

    operations = [
      fn -> Tracker.fetch_eligible(config, %{states: ["open"], required_labels: []}, opts) end,
      fn -> Tracker.fetch_by_ids(config, ["1"], opts) end,
      fn -> Tracker.transition_issue(config, "1", :closed, opts) end,
      fn -> Tracker.upsert_progress(config, "1", "running", opts) end,
      fn -> Tracker.append_final_summary(config, "1", "failed", opts) end
    ]

    Enum.each(operations, fn operation ->
      assert {:error, %{provider: "github", code: :transport_failed, retryable: true} = error} =
               operation.()

      refute inspect(error) =~ secret
      refute inspect(error) =~ credential_ref
    end)

    webhook_secret = "real-broker-webhook-secret"
    {:ok, webhook_reference} = SecretStore.put("tracker-webhook", webhook_secret, actor: "admin-1")
    webhook_secret_ref = SecretStore.export_reference(webhook_reference)
    webhook_config = put_in(config, [:settings, :webhook_secret_ref], webhook_secret_ref)

    assert {:error, %{provider: "github", code: :invalid_signature, retryable: false} = error} =
             Tracker.normalize_webhook(
               webhook_config,
               %{
                 headers: %{
                   "x-github-event" => "issues",
                   "x-github-delivery" => "delivery-1",
                   "x-hub-signature-256" => "sha256=invalid"
                 },
                 body: Jason.encode!(%{"action" => "edited", "issue" => %{"number" => 1}})
               },
               tracker_opts()
             )

    refute inspect(error) =~ webhook_secret
    refute inspect(error) =~ webhook_secret_ref
  end

  defp github_config(credential_ref) do
    %{
      provider: "github",
      credential_ref: credential_ref,
      settings: %{
        endpoint: "https://github.test",
        bot_actor_id: "42",
        owner: "acme",
        repository: "symphony"
      }
    }
  end

  defp tracker_opts(opts \\ []) do
    Keyword.merge(
      [
        endpoint_trusted_origins: ["https://github.test"],
        endpoint_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
      ],
      opts
    )
  end
end
