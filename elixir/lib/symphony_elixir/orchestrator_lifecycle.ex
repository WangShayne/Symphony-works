defmodule SymphonyElixir.OrchestratorLifecycle do
  @moduledoc """
  Owns the durable authority required before an orchestrator may start work.
  """

  use GenServer

  alias SymphonyElixir.{Coordination, Effects}
  alias SymphonyElixir.Effects.{OperationId, Record, SimulatedAdapter}
  alias SymphonyElixir.SourceControl.EffectAdapter, as: SourceControlEffectAdapter

  @default_lease_ttl_ms 30_000
  @default_heartbeat_interval_ms 10_000
  @default_recovery_batch_size 100
  @default_startup_heartbeat_stop_timeout_ms 5_000

  defstruct [:lease, :heartbeat_interval_ms, :heartbeat_timer_ref]

  @type state :: %__MODULE__{
          lease: map(),
          heartbeat_interval_ms: pos_integer(),
          heartbeat_timer_ref: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    owner_id = Keyword.get_lazy(opts, :owner_id, &OperationId.generate/0)
    ttl_ms = Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)

    heartbeat_interval_ms =
      Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    recovery_batch_size =
      Keyword.get(opts, :recovery_batch_size, @default_recovery_batch_size)

    effect_adapter_resolver =
      Keyword.get(opts, :effect_adapter_resolver, &default_recovery_adapter/1)

    projection_rebuilder =
      Keyword.get(opts, :projection_rebuilder, &Coordination.rebuild_all_projections/0)

    startup_heartbeat_stop_timeout_ms =
      Keyword.get(
        opts,
        :startup_heartbeat_stop_timeout_ms,
        @default_startup_heartbeat_stop_timeout_ms
      )

    with :ok <-
           validate_options(
             owner_id,
             ttl_ms,
             heartbeat_interval_ms,
             recovery_batch_size,
             effect_adapter_resolver,
             projection_rebuilder,
             startup_heartbeat_stop_timeout_ms
           ),
         {:ok, lease} <- acquire_lease(owner_id, ttl_ms) do
      startup_heartbeat = start_startup_heartbeat(lease, heartbeat_interval_ms)

      case prepare_for_intake(
             owner_id,
             recovery_batch_size,
             effect_adapter_resolver,
             projection_rebuilder,
             opts
           ) do
        :ok ->
          finish_startup(
            startup_heartbeat,
            lease,
            heartbeat_interval_ms,
            startup_heartbeat_stop_timeout_ms
          )

        {:error, reason} ->
          abort_startup(startup_heartbeat, lease, startup_heartbeat_stop_timeout_ms)
          {:error, reason}
      end
    end
  end

  @impl true
  def handle_info(:heartbeat, %__MODULE__{} = state) do
    case Coordination.heartbeat(state.lease) do
      :ok ->
        {:noreply, schedule_heartbeat(clear_heartbeat(state))}

      {:error, reason} ->
        {:stop, {:orchestrator_lease_lost, reason}, clear_heartbeat(state)}
    end
  end

  @impl true
  def terminate(_reason, %__MODULE__{lease: lease} = state) do
    cancel_heartbeat(state)
    _result = Coordination.release_lease(lease)
    :ok
  end

  defp schedule_heartbeat(%__MODULE__{} = state) do
    timer_ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
    %{state | heartbeat_timer_ref: timer_ref}
  end

  defp clear_heartbeat(%__MODULE__{} = state) do
    %{state | heartbeat_timer_ref: nil}
  end

  defp cancel_heartbeat(%__MODULE__{heartbeat_timer_ref: timer_ref})
       when is_reference(timer_ref) do
    _remaining = Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_heartbeat(_state), do: :ok

  defp start_startup_heartbeat(lease, heartbeat_interval_ms) do
    spawn_link(fn -> startup_heartbeat_loop(lease, heartbeat_interval_ms) end)
  end

  defp startup_heartbeat_loop(lease, heartbeat_interval_ms) do
    receive do
      :stop ->
        renew_startup_lease!(lease)
    after
      heartbeat_interval_ms ->
        renew_startup_lease!(lease)
        startup_heartbeat_loop(lease, heartbeat_interval_ms)
    end
  end

  defp renew_startup_lease!(lease) do
    case Coordination.heartbeat(lease) do
      :ok -> :ok
      {:error, reason} -> exit({:orchestrator_startup_failed, :heartbeat, reason})
    end
  end

  defp finish_startup(
         startup_heartbeat,
         lease,
         heartbeat_interval_ms,
         startup_heartbeat_stop_timeout_ms
       ) do
    case stop_startup_heartbeat(startup_heartbeat, startup_heartbeat_stop_timeout_ms) do
      :ok ->
        Process.flag(:trap_exit, true)
        state = %__MODULE__{lease: lease, heartbeat_interval_ms: heartbeat_interval_ms}
        {:ok, schedule_heartbeat(state)}

      {:error, :startup_heartbeat_stop_timeout} ->
        release_startup_lease(lease)
        startup_error(:heartbeat, :startup_heartbeat_stop_timeout)
    end
  end

  defp abort_startup(startup_heartbeat, lease, startup_heartbeat_stop_timeout_ms) do
    _stop_result =
      stop_startup_heartbeat(startup_heartbeat, startup_heartbeat_stop_timeout_ms)

    release_startup_lease(lease)
    :ok
  end

  defp stop_startup_heartbeat(startup_heartbeat, timeout_ms) do
    monitor = Process.monitor(startup_heartbeat)

    if timeout_ms > 0 do
      send(startup_heartbeat, :stop)
    end

    receive do
      {:DOWN, ^monitor, :process, ^startup_heartbeat, _reason} -> :ok
    after
      timeout_ms ->
        force_stop_startup_heartbeat(startup_heartbeat, monitor)
        {:error, :startup_heartbeat_stop_timeout}
    end
  end

  defp force_stop_startup_heartbeat(startup_heartbeat, monitor) do
    Process.unlink(startup_heartbeat)
    Process.exit(startup_heartbeat, :kill)
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp release_startup_lease(lease) do
    _release_result = Coordination.release_lease(lease)
    :ok
  end

  defp acquire_lease(owner_id, ttl_ms) do
    case Coordination.acquire_lease(owner_id, ttl_ms: ttl_ms) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, {:orchestrator_startup_failed, :acquire_lease, reason}}
    end
  end

  defp prepare_for_intake(
         owner_id,
         recovery_batch_size,
         effect_adapter_resolver,
         projection_rebuilder,
         opts
       ) do
    with :ok <- rebuild_projections(projection_rebuilder) do
      recover_effects(owner_id, recovery_batch_size, effect_adapter_resolver, opts)
    end
  end

  defp rebuild_projections(projection_rebuilder) do
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      case projection_rebuilder.() do
        :ok -> :ok
        _result -> projection_rebuild_error()
      end
    catch
      _kind, _reason -> projection_rebuild_error()
    end
  end

  defp projection_rebuild_error,
    do: startup_error(:rebuild_projections, :projection_rebuild_failed)

  defp recover_effects(owner_id, recovery_batch_size, effect_adapter_resolver, opts) do
    recovery_now = Keyword.get(opts, :recovery_now)

    recover_effect_batches(
      owner_id,
      recovery_batch_size,
      recovery_now,
      effect_adapter_resolver
    )
  end

  defp recover_effect_batches(
         owner_id,
         recovery_batch_size,
         recovery_now,
         effect_adapter_resolver
       ) do
    recovery_opts =
      [owner_id: owner_id, limit: recovery_batch_size]
      |> maybe_put_now(recovery_now)

    case Effects.recover_orphans(recovery_opts) do
      {:ok, %{pending: pending, remaining: remaining, next_check_at: next_check_at}} ->
        continue_recovery(
          pending,
          remaining,
          next_check_at,
          owner_id,
          recovery_batch_size,
          recovery_now,
          effect_adapter_resolver
        )

      {:error, reason} ->
        startup_error(:recover_effects, reason)
    end
  end

  defp continue_recovery(
         pending,
         remaining,
         next_check_at,
         owner_id,
         recovery_batch_size,
         recovery_now,
         effect_adapter_resolver
       ) do
    with :ok <- reconcile_pending(pending, owner_id, recovery_now, effect_adapter_resolver) do
      maybe_recover_remaining(
        remaining,
        owner_id,
        recovery_batch_size,
        recovery_now,
        effect_adapter_resolver,
        next_check_at
      )
    end
  end

  defp maybe_recover_remaining(
         0,
         owner_id,
         recovery_batch_size,
         _recovery_now,
         effect_adapter_resolver,
         next_check_at
       ) do
    wait_for_next_recovery(
      next_check_at,
      owner_id,
      recovery_batch_size,
      effect_adapter_resolver
    )
  end

  defp maybe_recover_remaining(
         _remaining,
         owner_id,
         recovery_batch_size,
         recovery_now,
         effect_adapter_resolver,
         _next_check_at
       ) do
    recover_effect_batches(owner_id, recovery_batch_size, recovery_now, effect_adapter_resolver)
  end

  defp wait_for_next_recovery(nil, _owner_id, _recovery_batch_size, _resolver), do: :ok

  defp wait_for_next_recovery(
         %DateTime{} = next_check_at,
         owner_id,
         recovery_batch_size,
         effect_adapter_resolver
       ) do
    Process.sleep(recovery_delay_ms(next_check_at))
    recover_effect_batches(owner_id, recovery_batch_size, nil, effect_adapter_resolver)
  end

  defp recovery_delay_ms(next_check_at) do
    next_check_at
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> Kernel.+(1)
    |> max(0)
  end

  defp reconcile_pending(pending, owner_id, recovery_now, effect_adapter_resolver) do
    Enum.reduce_while(pending, :ok, fn %Record{} = record, :ok ->
      case reconcile_effect(record, owner_id, recovery_now, effect_adapter_resolver) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reconcile_effect(%Record{} = record, owner_id, recovery_now, effect_adapter_resolver) do
    with {:ok, adapter} <- resolve_effect_adapter(record, effect_adapter_resolver),
         {:ok, %Record{status: :succeeded}} <-
           Effects.reconcile(
             record.operation_id,
             adapter,
             [owner_id: owner_id] |> maybe_put_now(recovery_now)
           ) do
      :ok
    else
      {:error, {:orchestrator_startup_failed, _phase, _reason}} = error ->
        error

      {:error, reason} ->
        startup_error(:reconcile_effects, {record.operation_id, reason})
    end
  end

  defp resolve_effect_adapter(%Record{} = record, effect_adapter_resolver) do
    record
    |> effect_adapter_resolver.()
    |> normalize_resolver_result()
  end

  defp normalize_resolver_result({:ok, adapter}) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute, 1) and
         function_exported?(adapter, :reconcile, 1) do
      {:ok, adapter}
    else
      startup_error(:resolve_effect_adapter, :adapter_unavailable)
    end
  end

  defp normalize_resolver_result({:error, _reason}),
    do: startup_error(:resolve_effect_adapter, :unsupported_provider)

  defp normalize_resolver_result(_result),
    do: startup_error(:resolve_effect_adapter, :invalid_resolver_result)

  defp default_recovery_adapter(%Record{provider: "simulated"}), do: {:ok, SimulatedAdapter}

  defp default_recovery_adapter(%Record{provider: provider})
       when provider in ["fixture", "github", "gitlab"],
       do: {:ok, SourceControlEffectAdapter}

  defp default_recovery_adapter(%Record{}), do: {:error, :unsupported_provider}

  defp maybe_put_now(opts, nil), do: opts
  defp maybe_put_now(opts, recovery_now), do: Keyword.put(opts, :now, recovery_now)

  defp startup_error(phase, reason),
    do: {:error, {:orchestrator_startup_failed, phase, reason}}

  defp validate_options(
         owner_id,
         ttl_ms,
         heartbeat_interval_ms,
         recovery_batch_size,
         effect_adapter_resolver,
         projection_rebuilder,
         startup_heartbeat_stop_timeout_ms
       ) do
    valid? =
      valid_owner?(owner_id) and valid_ttl?(ttl_ms) and
        valid_heartbeat_interval?(heartbeat_interval_ms, ttl_ms) and
        valid_recovery_batch_size?(recovery_batch_size) and
        is_function(effect_adapter_resolver, 1) and is_function(projection_rebuilder, 0) and
        valid_startup_heartbeat_stop_timeout?(startup_heartbeat_stop_timeout_ms)

    if valid? do
      :ok
    else
      startup_error(:configuration, :invalid_lease_options)
    end
  end

  defp valid_owner?(owner_id), do: is_binary(owner_id) and byte_size(owner_id) > 0
  defp valid_ttl?(ttl_ms), do: is_integer(ttl_ms) and ttl_ms > 0

  defp valid_heartbeat_interval?(heartbeat_interval_ms, ttl_ms) do
    is_integer(heartbeat_interval_ms) and heartbeat_interval_ms > 0 and heartbeat_interval_ms < ttl_ms
  end

  defp valid_recovery_batch_size?(recovery_batch_size) do
    is_integer(recovery_batch_size) and recovery_batch_size > 0 and recovery_batch_size <= 1_000
  end

  defp valid_startup_heartbeat_stop_timeout?(timeout_ms) do
    is_integer(timeout_ms) and timeout_ms >= 0
  end
end
