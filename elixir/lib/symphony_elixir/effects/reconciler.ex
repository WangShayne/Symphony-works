defmodule SymphonyElixir.Effects.Reconciler do
  @moduledoc """
  Safely normalizes adapter reconciliation outcomes before an effect retry.
  """

  alias SymphonyElixir.Effects.Record

  @type outcome ::
          :already_applied
          | :not_applied
          | {:applied, term()}
          | {:unknown, atom()}

  @spec reconcile(module(), Record.t()) :: outcome()
  def reconcile(adapter, %Record{} = record) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :reconcile, 1) do
      adapter
      |> safely_apply(record)
      |> normalize()
    else
      {:unknown, :reconciliation_unavailable}
    end
  end

  defp safely_apply(adapter, record) do
    adapter.reconcile(record)
  rescue
    _exception -> {:unknown, :reconciliation_failed}
  catch
    _kind, _reason -> {:unknown, :reconciliation_failed}
  end

  defp normalize({:ok, :already_applied}), do: :already_applied
  defp normalize(:already_applied), do: :already_applied
  defp normalize({:applied, result}), do: {:applied, result}
  defp normalize({:ok, :not_applied}), do: :not_applied
  defp normalize(:not_applied), do: :not_applied
  defp normalize({:unknown, reason}) when is_atom(reason), do: {:unknown, reason}
  defp normalize({:error, reason}) when is_atom(reason), do: {:unknown, reason}
  defp normalize(_outcome), do: {:unknown, :invalid_reconciliation}
end
