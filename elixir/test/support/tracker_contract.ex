defmodule SymphonyElixir.TrackerContract do
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias SymphonyElixir.Tracker

  using options do
    provider = Keyword.fetch!(options, :provider)
    adapter = Keyword.fetch!(options, :adapter)

    quote bind_quoted: [provider: provider, adapter: adapter] do
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Tracker.Issue
      alias SymphonyElixir.TrackerContract

      @tracker_contract_provider provider
      @tracker_contract_adapter adapter

      test "exports every normalized Tracker callback" do
        assert Code.ensure_loaded?(@tracker_contract_adapter)

        for {callback, arity} <- [
              health_check: 2,
              fetch_eligible: 3,
              fetch_by_ids: 3,
              normalize_webhook: 3,
              transition_issue: 4,
              upsert_progress: 4,
              append_final_summary: 4
            ] do
          assert function_exported?(@tracker_contract_adapter, callback, arity)
        end
      end

      test "health probe proves the configured Tracker capabilities without a mutation" do
        contract = tracker_contract_case(:health_check)

        assert {:ok,
                %{
                  provider: @tracker_contract_provider,
                  status: :healthy,
                  evidence: evidence
                }} = Tracker.health_check(contract.config, contract.opts)

        for capability <- [
              :credentials,
              :scope,
              :issue_read,
              :state_mappings,
              :comment_permissions
            ] do
          assert Map.get(evidence, capability) == :verified
        end

        TrackerContract.assert_tracker_broker_call(contract)
      end

      test "fetch_eligible returns normalized dispatchable Issues" do
        contract = tracker_contract_case(:fetch_eligible)

        assert {:ok, issues} =
                 Tracker.fetch_eligible(contract.config, contract.criteria, contract.opts)

        assert Enum.map(issues, & &1.id) == contract.expected_ids
        assert Enum.all?(issues, &match?(%Issue{dispatchable: true}, &1))
        TrackerContract.assert_tracker_broker_call(contract)
      end

      test "fetch_by_ids preserves requested provider identity order" do
        contract = tracker_contract_case(:fetch_by_ids)

        assert {:ok, issues} =
                 Tracker.fetch_by_ids(contract.config, contract.issue_ids, contract.opts)

        assert Enum.map(issues, & &1.id) == contract.expected_ids
        TrackerContract.assert_tracker_broker_call(contract)
      end

      test "normalize_webhook emits a stable terminal reconciliation signal" do
        contract = tracker_contract_case(:normalize_webhook)

        assert {:ok,
                %{
                  provider: @tracker_contract_provider,
                  kind: :human_terminal,
                  issue_id: issue_id,
                  reconciliation_key: reconciliation_key
                }} = Tracker.normalize_webhook(contract.config, contract.request, contract.opts)

        assert issue_id == contract.expected_issue_id
        assert is_binary(reconciliation_key) and reconciliation_key != ""
        TrackerContract.assert_tracker_broker_call(contract)
      end

      test "transition_issue consumes the normalized fetched identity" do
        contract = tracker_contract_case(:transition_issue)

        assert {:ok,
                %{
                  provider: @tracker_contract_provider,
                  issue_id: issue_id,
                  state: state
                }} =
                 Tracker.transition_issue(
                   contract.config,
                   contract.issue_id,
                   contract.target_state,
                   contract.opts
                 )

        assert issue_id == contract.issue_id
        assert state == contract.expected_state
        TrackerContract.assert_tracker_broker_call(contract)
      end

      test "upsert_progress reuses one provider comment across operation identities" do
        contract = tracker_contract_case(:upsert_progress)
        TrackerContract.assert_stable_comment(@tracker_contract_provider, contract, :upsert_progress)
      end

      test "append_final_summary uses an independent stable provider comment" do
        contract = tracker_contract_case(:append_final_summary)
        TrackerContract.assert_stable_comment(@tracker_contract_provider, contract, :append_final_summary)
      end
    end
  end

  def assert_stable_comment(provider, contract, operation) do
    assert {:ok, first} =
             tracker_comment_operation(
               operation,
               contract,
               contract.first_text,
               "#{operation}-1"
             )

    assert first.provider == provider
    assert first.issue_id == contract.issue_id
    assert first.action == :created
    assert is_binary(first.external_comment_id)

    assert {:ok, second} =
             tracker_comment_operation(
               operation,
               contract,
               contract.second_text,
               "#{operation}-2"
             )

    assert second.action == :updated
    assert second.external_comment_id == first.external_comment_id

    refute second.marker == first.marker and operation == :append_final_summary and
             String.contains?(second.marker, "progress")

    assert_tracker_broker_call(contract, 2)
  end

  def assert_tracker_broker_call(contract, count \\ 1) do
    case Map.take(contract, [:credential_ref, :credential_purpose]) do
      %{credential_ref: reference, credential_purpose: purpose}
      when is_binary(reference) and is_atom(purpose) ->
        for _index <- 1..count do
          assert_receive {:tracker_broker_called, ^reference, ^purpose}
        end

      _other ->
        :ok
    end
  end

  defp tracker_comment_operation(:upsert_progress, contract, text, operation_id) do
    Tracker.upsert_progress(
      contract.config,
      contract.issue_id,
      text,
      Keyword.put(contract.opts, :operation_id, operation_id)
    )
  end

  defp tracker_comment_operation(:append_final_summary, contract, text, operation_id) do
    Tracker.append_final_summary(
      contract.config,
      contract.issue_id,
      text,
      Keyword.put(contract.opts, :operation_id, operation_id)
    )
  end

  defmodule Broker do
    @moduledoc false

    def put_secret(reference, plaintext) do
      Process.put({__MODULE__, reference}, plaintext)
    end

    def with_secret(reference, purpose, callback) when is_function(callback, 1) do
      send(self(), {:tracker_broker_called, reference, purpose})

      case Process.get({__MODULE__, reference}) do
        nil -> {:error, :not_found}
        plaintext -> callback.(plaintext)
      end
    end
  end
end
