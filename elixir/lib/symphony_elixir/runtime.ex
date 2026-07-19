defmodule SymphonyElixir.Runtime do
  @moduledoc """
  Public contract for Agent Runtime adapters.
  """

  defmodule Session do
    @moduledoc "Normalized runtime session."
    @enforce_keys [:adapter, :runtime, :session_id, :metadata]
    defstruct [:adapter, :runtime, :session_id, :adapter_state, metadata: %{}]

    @type t :: %__MODULE__{
            adapter: module(),
            runtime: atom(),
            session_id: String.t(),
            adapter_state: term(),
            metadata: map()
          }
  end

  defmodule Event do
    @moduledoc "Normalized runtime event."
    @enforce_keys [:type, :runtime, :session_id, :occurred_at]
    defstruct [:type, :runtime, :session_id, :payload, :occurred_at]

    @type t :: %__MODULE__{
            type: atom(),
            runtime: atom(),
            session_id: String.t(),
            payload: map() | nil,
            occurred_at: DateTime.t()
          }
  end

  defmodule TurnResult do
    @moduledoc "Normalized runtime turn result."
    @enforce_keys [:runtime, :session_id, :output, :events]
    defstruct [:runtime, :session_id, :output, events: [], metadata: %{}]

    @type t :: %__MODULE__{
            runtime: atom(),
            session_id: String.t(),
            output: term(),
            events: [Event.t()],
            metadata: map()
          }
  end

  @type start_opts :: map()
  @type turn_input :: map()
  @type health_opts :: keyword()

  @callback start_session(start_opts()) :: {:ok, Session.t()} | {:error, term()}
  @callback run_turn(Session.t(), turn_input()) :: {:ok, TurnResult.t()} | {:error, term()}
  @callback stop_session(Session.t()) :: :ok | {:error, term()}
  @callback capabilities(map()) :: {:ok, map()} | {:error, term()}
  @callback health_check(map(), health_opts()) :: {:ok, map()} | {:error, term()}

  @spec start_session(module(), start_opts()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(adapter, opts) when is_atom(adapter) and is_map(opts) do
    safe_boundary(fn -> adapter.start_session(opts) end, :start_session_failed)
  end

  @spec run_turn(Session.t(), turn_input()) :: {:ok, TurnResult.t()} | {:error, term()}
  def run_turn(%Session{adapter: adapter} = session, input) when is_map(input) do
    safe_boundary(fn -> adapter.run_turn(session, input) end, :run_turn_failed)
  end

  @spec stop_session(Session.t()) :: :ok | {:error, term()}
  def stop_session(%Session{adapter: adapter} = session) do
    safe_boundary(fn -> adapter.stop_session(session) end, :stop_session_failed)
  end

  @spec capabilities(module(), map()) :: {:ok, map()} | {:error, term()}
  def capabilities(adapter, model_reference) when is_atom(adapter) and is_map(model_reference) do
    safe_boundary(fn -> adapter.capabilities(model_reference) end, :capabilities_failed)
  end

  @spec health_check(module(), map(), health_opts()) :: {:ok, map()} | {:error, term()}
  def health_check(adapter, model_reference, opts \\ []) when is_atom(adapter) and is_map(model_reference) do
    safe_boundary(fn -> adapter.health_check(model_reference, opts) end, :health_check_failed)
  end

  @spec event(atom(), atom(), String.t(), map()) :: Event.t()
  def event(runtime, type, session_id, payload \\ %{}) do
    %Event{
      runtime: runtime,
      type: type,
      session_id: session_id,
      payload: payload,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp safe_boundary(fun, error) do
    fun.()
  rescue
    _exception -> {:error, {:runtime_error, error}}
  catch
    _kind, _reason -> {:error, {:runtime_error, error}}
  end
end
