defmodule SymphonyElixir.Tracker.Adapter do
  @moduledoc false

  alias SymphonyElixir.Tracker.Issue

  @callback health_check(term(), term()) :: {:ok, map()} | {:error, map()}
  @callback fetch_eligible(term(), term(), term()) :: {:ok, [Issue.t()]} | {:error, map()}
  @callback fetch_by_ids(term(), term(), term()) :: {:ok, [Issue.t()]} | {:error, map()}
  @callback normalize_webhook(term(), term(), term()) :: {:ok, map()} | {:error, map()}
  @callback transition_issue(term(), term(), term(), term()) ::
              {:ok, map()} | {:error, map()}
  @callback upsert_progress(term(), term(), term(), term()) ::
              {:ok, map()} | {:error, map()}
  @callback append_final_summary(term(), term(), term(), term()) ::
              {:ok, map()} | {:error, map()}
end
