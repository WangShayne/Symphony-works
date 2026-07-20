defmodule SymphonyElixir.Effects.SimulatedAdapter do
  @moduledoc """
  Deterministic, mutation-free adapter for contract and walking-skeleton tests.
  """

  alias SymphonyElixir.Effects.Record

  @spec execute(Record.t()) :: {:ok, map()} | {:error, atom()} | {:unknown, atom()}
  def execute(%Record{} = record) do
    case Map.get(record.intent, "simulate", "success") do
      "unknown" -> {:unknown, :interrupted}
      "failure" -> {:error, :simulated_failure}
      _other -> {:ok, success_result(record)}
    end
  end

  @spec reconcile(Record.t()) ::
          {:ok, :already_applied | :not_applied} | {:unknown, :not_observed}
  def reconcile(%Record{} = record) do
    case Map.get(record.intent, "reconcile", "not_observed") do
      "already_applied" -> {:ok, :already_applied}
      "not_applied" -> {:ok, :not_applied}
      _other -> {:unknown, :not_observed}
    end
  end

  defp success_result(record) do
    %{
      "operation_id" => record.operation_id,
      "provider" => record.provider,
      "status" => "simulated",
      "target" => record.target
    }
  end
end
