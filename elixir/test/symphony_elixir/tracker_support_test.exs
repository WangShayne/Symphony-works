defmodule SymphonyElixir.TrackerSupportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.Adapters.Support
  alias SymphonyElixir.Tracker.Issue

  test "successful malformed responses are invalid rather than provider rejections" do
    assert {:error,
            %{
              provider: "github",
              code: :invalid_response,
              retryable: false,
              message: "tracker provider returned an invalid response"
            }} = Support.http_error("github", %{status: 200, headers: %{}, body: %{}})

    assert {:error, %{code: :invalid_response}} =
             Support.http_error("gitlab", %{status: 204, headers: []})
  end

  test "http errors preserve only normalized retry semantics" do
    assert {:error, %{code: :authentication_failed, retryable: false}} =
             Support.http_error("github", %{status: 401})

    assert {:error, %{code: :forbidden, retryable: false}} =
             Support.http_error("github", %{status: 403, headers: %{}})

    assert {:error, %{code: :not_found, retryable: false}} =
             Support.http_error("github", %{status: 404})

    assert {:error, %{code: :provider_unavailable, retryable: true}} =
             Support.http_error("github", %{status: 503})

    assert {:error, %{code: :provider_error, retryable: false}} =
             Support.http_error("github", %{status: 422})

    assert {:error, %{code: :invalid_response, retryable: false}} =
             Support.http_error("github", %{})
  end

  test "rate limits accept map and list header shapes with bounded retry hints" do
    assert {:error, %{code: :rate_limited, retryable: true, retry_after_ms: 7_000}} =
             Support.http_error("github", %{
               status: 429,
               headers: %{"Retry-After" => ["7"]}
             })

    assert {:error, %{code: :rate_limited, retryable: true, retry_after_ms: nil}} =
             Support.http_error("github", %{
               status: 403,
               headers: [{"X-RateLimit-Remaining", "0"}, {"retry-after", "invalid"}]
             })

    assert Support.header(%{headers: :invalid}, "retry-after") == nil
    assert Support.header(%{headers: %{retry_after: 12}}, "retry_after") == "12"
  end

  test "eligibility requires a schedulable issue and every requested criterion" do
    issue = %Issue{
      id: "1",
      state: "Open",
      labels: ["Ready-For-Agent", "Backend"],
      assignee_id: "42",
      dispatchable: true
    }

    assert Support.eligible?(issue, %{
             states: ["open"],
             required_labels: ["ready-for-agent", "backend"],
             assignee_id: 42
           })

    refute Support.eligible?(%{issue | dispatchable: false}, %{
             states: ["open"],
             required_labels: []
           })

    refute Support.eligible?(issue, %{states: ["closed"], required_labels: []})
    refute Support.eligible?(issue, %{states: ["open"], required_labels: ["frontend"]})

    assert Support.eligible?(%{issue | labels: [123]}, %{
             states: [:open],
             required_labels: [123]
           })

    refute Support.eligible?(issue, %{states: :open, required_labels: :none})
  end

  test "secure comparison and transport errors expose no provider payload" do
    assert Support.secure_compare("same", "same")
    refute Support.secure_compare("same", "different")
    refute Support.secure_compare(:same, :same)

    assert {:error,
            %{
              provider: "linear",
              code: :transport_failed,
              retryable: true,
              message: "tracker provider could not be reached"
            }} = Support.transport_error("linear")
  end
end
