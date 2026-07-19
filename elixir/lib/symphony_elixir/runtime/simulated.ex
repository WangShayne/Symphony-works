defmodule SymphonyElixir.Runtime.Simulated do
  @moduledoc """
  Deterministic Runtime adapter used as contract evidence.
  """

  @behaviour SymphonyElixir.Runtime

  alias SymphonyElixir.Runtime
  alias SymphonyElixir.Runtime.{Session, TurnResult}

  @impl true
  def start_session(opts) when is_map(opts) do
    seed = Map.get(opts, :seed) || Map.get(opts, "seed") || 0
    session_id = "simulated-" <> deterministic_id(opts, seed)

    {:ok,
     %Session{
       adapter: __MODULE__,
       runtime: :simulated,
       session_id: session_id,
       adapter_state: %{seed: seed},
       metadata: %{
         workspace: Map.get(opts, :workspace) || Map.get(opts, "workspace"),
         model_reference: Map.get(opts, :model_reference) || Map.get(opts, "model_reference")
       }
     }}
  end

  @impl true
  def run_turn(%Session{runtime: :simulated, session_id: session_id} = session, input) do
    output =
      if Map.has_key?(input, :schema) or Map.has_key?(input, "schema") do
        %{"task_type" => "general"}
      else
        %{"message" => "simulated"}
      end

    {:ok,
     %TurnResult{
       runtime: :simulated,
       session_id: session_id,
       output: output,
       events: [
         Runtime.event(:simulated, :session_started, session_id, %{}),
         Runtime.event(:simulated, :turn_completed, session_id, %{output: output})
       ],
       metadata: session.metadata
     }}
  end

  @impl true
  def stop_session(%Session{runtime: :simulated}), do: :ok

  @impl true
  def capabilities(%{"capabilities" => capabilities}) when is_map(capabilities) do
    {:ok, Map.take(capabilities, ["structured_output", "tool_use", "context_window"])}
  end

  def capabilities(_model_reference) do
    {:error, {:runtime_error, :missing_capabilities}}
  end

  @impl true
  def health_check(model_reference, _opts) when is_map(model_reference) do
    with {:ok, capabilities} <- capabilities(model_reference) do
      {:ok,
       %{
         "runtime" => "simulated",
         "status" => "passed",
         "structured_plan_probe" => %{"mode" => "deterministic", "schema" => "passed"},
         "capabilities" => capabilities,
         "prices" => price_snapshot(model_reference)
       }}
    end
  end

  defp deterministic_id(opts, seed) do
    opts
    |> Map.take([:workspace, "workspace", :model_reference, "model_reference"])
    |> :erlang.term_to_binary([:deterministic])
    |> then(fn binary -> :crypto.hash(:sha256, <<:erlang.phash2(seed)::32, binary::binary>>) end)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp price_snapshot(%{"prices" => prices}) when is_map(prices) do
    Map.take(prices, ["input", "cached_input", "output"])
  end

  defp price_snapshot(_model_reference), do: %{}
end
