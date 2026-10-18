defmodule BfwEngine.Timers.Scheduler do
  @moduledoc """
  Metadata-opaque timer scheduler backed by ETS.

  The Scheduler accepts timer registrations with a concrete `fire_at`
  DateTime, a `target` (PID or registered atom name), and an opaque
  `metadata` map. On expiry it delivers `{:timer_fired, timer_ref, metadata}`
  to the target via `send/2`.

  ## ETS Layout

  Two tables provide efficient scheduling and cancellation:

  1. **Primary** (`:ordered_set`): `{{fire_at_unix_ms, timer_ref}, target, metadata, cycle_info}`
     Ordered by fire time for efficient earliest-timer lookup via `:ets.first/1`.

  2. **Target index** (`:bag`): `{target_key, timer_ref, fire_at_unix_ms}`
     Enables O(n) `cancel_all_for_target/1` without scanning the primary table.

  ## PID Monitoring

  When a target is a PID, the Scheduler monitors it. On `:DOWN`, all
  timers for that PID are cancelled automatically (no stale timers
  accumulate for terminated process instances).

  ## Tick Mechanism

  Uses `Process.send_after(self(), :tick, tick_interval_ms)`. Each tick
  pops all expired entries and delivers fire messages. The tick interval
  is configurable via `:core_timers, :tick_interval_ms` (default 1000ms,
  one-second precision).

  ## Cycle Timers

  For timers with `cycle_interval` set, the Scheduler computes the next
  fire time via `ISO8601.next_future_cycle_fire/3` and re-inserts into ETS
  under the same timer ref, so the ref returned by `schedule/2` cancels the
  whole cycle. Occurrences already due when the cycle re-arms are skipped
  (each uses up one repetition), so a late tick never fires a burst.
  An optional `on_cycle_advance` callback (MFA) receives
  `(metadata, next_fire_at | nil, remaining)`, with the cycle's `timer_ref`
  added to `metadata`, so the `StartEventManager` can persist the cycle state. It runs in a linked worker process, in fire
  order, so a slow callback never delays a tick.

  ## Restart

  The ETS tables are owned by the Scheduler and die with it. When the
  Scheduler restarts after a crash (any exit other than `:normal` or
  `:shutdown`), the optional `on_restart` callback (MFA) runs in a separate
  process so the owner of persisted schedules can re-arm them. A callback
  that raises, exits, throws, or returns `{:error, reason}` is retried with
  backoff (three attempts in total) before the failure is logged.
  """

  use GenServer

  require Logger

  alias BfwEngine.Timers.ISO8601

  @type timer_ref :: String.t()
  @type target :: pid() | atom()

  @type cycle_info :: %{
          interval_duration: Duration.t(),
          remaining: pos_integer() | :infinite,
          anchor: DateTime.t(),
          occurrence: non_neg_integer()
        }

  @type schedule_request :: %{
          required(:fire_at) => DateTime.t(),
          required(:target) => target(),
          required(:metadata) => map(),
          optional(:cycle_interval) => Duration.t() | nil,
          optional(:cycle_remaining) => pos_integer() | :infinite | nil,
          optional(:cycle_anchor) => DateTime.t() | nil,
          optional(:cycle_occurrence) => non_neg_integer() | nil
        }

  @default_primary_table :bfw_engine_timers_primary
  @default_target_index_table :bfw_engine_timers_target_index
  @restore_attempts 3
  @restore_initial_backoff_ms 500
  @restart_wait_initial_ms 50
  @restart_wait_max_ms 1_000

  # --- Client API ---

  @doc "Starts the Scheduler as a named GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Schedules a timer. Returns `{:ok, timer_ref}` on success.

  ## Required fields

  - `fire_at` — when the timer should fire (UTC DateTime)
  - `target` — PID or registered atom to receive the fire message
  - `metadata` — opaque map returned verbatim on fire

  ## Optional fields

  - `cycle_interval` — `Duration.t()` for repeating timers
  - `cycle_remaining` — number of remaining repetitions (`:infinite` or positive integer)
  - `cycle_anchor` / `cycle_occurrence` — the occurrence a calendar interval
    counts from and the index of `fire_at` after it; default `fire_at` and 0
  """
  @spec schedule(schedule_request(), GenServer.server()) :: {:ok, timer_ref()}
  def schedule(request, server \\ __MODULE__) do
    GenServer.call(server, {:schedule, request})
  end

  @doc "Cancels a timer by ref. Returns `:ok` or `{:error, :not_found}`."
  @spec cancel(timer_ref(), GenServer.server()) :: :ok | {:error, :not_found}
  def cancel(timer_ref, server \\ __MODULE__) do
    GenServer.call(server, {:cancel, timer_ref})
  end

  @doc """
  Cancels all timers for a given target (PID or atom).
  Returns the number of timers cancelled.
  """
  @spec cancel_all_for_target(target(), GenServer.server()) :: non_neg_integer()
  def cancel_all_for_target(target, server \\ __MODULE__) do
    GenServer.call(server, {:cancel_all_for_target, target})
  end

  @doc "Returns the number of currently armed timers."
  @spec armed_count(GenServer.server()) :: non_neg_integer()
  def armed_count(server \\ __MODULE__) do
    GenServer.call(server, :armed_count)
  end

  @doc """
  Immediately fires all pending timers for a given target PID.

  Delivers `{:timer_fired, timer_ref, metadata}` to the target for each
  matching timer, then removes them from ETS. Cycle timers are re-armed
  naturally by the fire logic (same as tick-based expiry).

  Returns the number of fires delivered to a live target; an entry whose
  target is gone is removed without being counted.
  """
  @spec fire_now_for_target(target(), GenServer.server()) :: non_neg_integer()
  def fire_now_for_target(target, server \\ __MODULE__) do
    GenServer.call(server, {:fire_now_for_target, target})
  end

  @doc """
  Blocks the calling process until `{:timer_fired, timer_ref, metadata}`
  arrives and returns the ref that fired.

  The Scheduler's ETS tables die with it, so the caller monitors it while
  waiting. When it goes down, the caller waits for the restarted Scheduler
  (backoff from #{@restart_wait_initial_ms} ms, doubling up to
  #{@restart_wait_max_ms} ms) and calls `reschedule`, which schedules the
  same fire time again and returns `{:ok, new_timer_ref}`; then it waits for
  the new ref. A fire sent before the Scheduler went down is still received.
  """
  @spec await_fire(timer_ref(), (-> {:ok, timer_ref()}), atom()) :: timer_ref()
  def await_fire(timer_ref, reschedule, server \\ __MODULE__) when is_atom(server) do
    monitor_reference = Process.monitor(server)

    receive do
      {:timer_fired, ^timer_ref, _metadata} ->
        Process.demonitor(monitor_reference, [:flush])
        timer_ref

      {:DOWN, ^monitor_reference, :process, _object, _reason} ->
        timer_ref = reschedule_after_restart(reschedule, server, @restart_wait_initial_ms)
        await_fire(timer_ref, reschedule, server)
    end
  end

  defp reschedule_after_restart(reschedule, server, wait_ms) do
    Process.sleep(wait_ms)

    with pid when is_pid(pid) <- Process.whereis(server),
         {:ok, timer_ref} <- try_reschedule(reschedule) do
      timer_ref
    else
      _not_restarted ->
        reschedule_after_restart(reschedule, server, min(wait_ms * 2, @restart_wait_max_ms))
    end
  end

  defp try_reschedule(reschedule) do
    reschedule.()
  catch
    :exit, _reason -> :scheduler_unavailable
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    primary_name = opts[:primary_table] || @default_primary_table
    target_index_name = opts[:target_index_table] || @default_target_index_table

    primary = :ets.new(primary_name, [:ordered_set, :protected, :named_table])
    target_index = :ets.new(target_index_name, [:bag, :protected, :named_table])

    tick_interval_ms =
      opts[:tick_interval_ms] || Application.get_env(:core_timers, :tick_interval_ms, 1000)

    running_marker = {__MODULE__, :running, opts[:name] || __MODULE__}
    maybe_restore_after_crash(running_marker, opts[:on_restart])
    :persistent_term.put(running_marker, true)

    schedule_tick(tick_interval_ms)

    {:ok,
     %{
       primary: primary,
       target_index: target_index,
       tick_interval_ms: tick_interval_ms,
       on_cycle_advance: opts[:on_cycle_advance],
       cycle_advance_worker: start_cycle_advance_worker(opts[:on_cycle_advance]),
       running_marker: running_marker,
       monitored_pids: %{}
     }}
  end

  @impl true
  def terminate(reason, state) do
    if clean_shutdown?(reason), do: :persistent_term.erase(state.running_marker)
    :ok
  end

  defp clean_shutdown?(reason),
    do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  # The ETS tables died with the previous Scheduler; schedules owned elsewhere are re-armed.
  defp maybe_restore_after_crash(running_marker, on_restart) do
    case {:persistent_term.get(running_marker, false), on_restart} do
      {true, {module, function, arguments}} ->
        Logger.warning("Scheduler: restarted after a crash; restoring persisted schedules")

        {:ok, _restore_pid} =
          Task.start(fn -> restore_schedules(module, function, arguments, 1) end)

        :ok

      _no_restore ->
        :ok
    end
  end

  defp restore_schedules(module, function, arguments, attempt) do
    case attempt_restore(module, function, arguments) do
      :ok ->
        :ok

      {:failed, description} when attempt < @restore_attempts ->
        Logger.warning(
          "Scheduler: restoring persisted schedules failed (attempt #{attempt}/#{@restore_attempts}), " <>
            "retrying: #{description}"
        )

        Process.sleep(@restore_initial_backoff_ms * Integer.pow(2, attempt - 1))
        restore_schedules(module, function, arguments, attempt + 1)

      {:failed, description} ->
        Logger.error(
          "Scheduler: restoring persisted schedules after a crash failed #{attempt} times; cycle " <>
            "start schedules stay unarmed until the next engine boot: #{description}"
        )
    end
  end

  defp attempt_restore(module, function, arguments) do
    case apply(module, function, arguments) do
      {:error, reason} -> {:failed, inspect(reason)}
      _restored -> :ok
    end
  catch
    kind, reason -> {:failed, Exception.format(kind, reason, __STACKTRACE__)}
  end

  @impl true
  def handle_call({:schedule, request}, _from, state) do
    timer_ref = generate_timer_ref()
    fire_at_ms = DateTime.to_unix(request.fire_at, :millisecond)
    target = request.target
    metadata = request.metadata

    cycle_info = build_cycle_info(request)

    :ets.insert(state.primary, {{fire_at_ms, timer_ref}, target, metadata, cycle_info})
    :ets.insert(state.target_index, {target_key(target), timer_ref, fire_at_ms})

    state = maybe_monitor_pid(state, target)

    emit_telemetry(:armed, timer_ref, %{fire_at: request.fire_at}, metadata)

    {:reply, {:ok, timer_ref}, state}
  end

  @impl true
  def handle_call({:cancel, timer_ref}, _from, state) do
    case find_by_ref(state.primary, timer_ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {key, _target, _metadata, _cycle_info} ->
        delete_timer(state, key, timer_ref)
        emit_telemetry(:cancelled, timer_ref, %{}, %{})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:cancel_all_for_target, target}, _from, state) do
    count = do_cancel_all_for_target(state, target)
    {:reply, count, demonitor_target(state, target)}
  end

  @impl true
  def handle_call(:armed_count, _from, state) do
    count = :ets.info(state.primary, :size)
    {:reply, count, state}
  end

  @impl true
  def handle_call({:fire_now_for_target, target}, _from, state) do
    count = do_fire_now_for_target(state, target)
    {:reply, count, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now_ms = System.os_time(:millisecond)
    fire_expired_timers(state, now_ms)
    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _monitor_ref, :process, pid, _reason}, state) do
    count = do_cancel_all_for_target(state, pid)

    if count > 0 do
      Logger.debug("Scheduler: cancelled #{count} timer(s) for terminated PID #{inspect(pid)}")
    end

    updated_pids = Map.delete(state.monitored_pids, pid)
    {:noreply, %{state | monitored_pids: updated_pids}}
  end

  @impl true
  def handle_info({:EXIT, worker, reason}, %{cycle_advance_worker: worker} = state) do
    Logger.error(
      "Scheduler: cycle advance worker exited (#{inspect(reason)}); starting a new one. " <>
        "Cycle advances queued in the old worker were not persisted."
    )

    {:noreply,
     %{state | cycle_advance_worker: start_cycle_advance_worker(state.on_cycle_advance)}}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  # --- Internals ---

  defp fire_expired_timers(state, now_ms) do
    fire_expired_timers_loop(state, now_ms)
  end

  defp fire_expired_timers_loop(state, now_ms) do
    case :ets.first(state.primary) do
      :"$end_of_table" ->
        :ok

      {fire_at_ms, _timer_ref} = key when fire_at_ms <= now_ms ->
        [{^key, target, metadata, cycle_info}] = :ets.lookup(state.primary, key)
        timer_ref = elem(key, 1)

        deliver_fire_message(target, timer_ref, metadata)
        delete_timer(state, key, timer_ref)

        emit_telemetry(:fired, timer_ref, %{}, metadata)

        maybe_rearm_cycle(state, {target, timer_ref}, metadata, cycle_info, fire_at_ms)

        fire_expired_timers_loop(state, now_ms)

      _future_key ->
        :ok
    end
  end

  defp deliver_fire_message(target, timer_ref, metadata) when is_pid(target) do
    if Process.alive?(target) do
      send(target, {:timer_fired, timer_ref, metadata})
      true
    else
      Logger.debug(
        "Scheduler: target PID #{inspect(target)} is dead, dropping fire for #{timer_ref}"
      )

      false
    end
  end

  defp deliver_fire_message(target, timer_ref, metadata) when is_atom(target) do
    case Process.whereis(target) do
      nil ->
        Logger.warning(
          "Scheduler: registered name #{inspect(target)} not found, dropping fire for #{timer_ref}"
        )

        false

      pid ->
        send(pid, {:timer_fired, timer_ref, metadata})
        true
    end
  end

  defp maybe_rearm_cycle(state, {target, timer_ref}, metadata, cycle_info, fire_at_ms)
       when is_map(cycle_info) do
    fire_at = DateTime.from_unix!(fire_at_ms, :millisecond)

    cycle_spec = %{
      repetitions: cycle_info.remaining,
      interval_duration: cycle_info.interval_duration,
      start_at: nil,
      anchor: cycle_info.anchor,
      occurrence: cycle_info.occurrence
    }

    case ISO8601.next_future_cycle_fire(cycle_spec, fire_at, DateTime.utc_now()) do
      {next_fire, updated_cycle_spec} ->
        next_fire_ms = DateTime.to_unix(next_fire, :millisecond)

        new_cycle_info = %{
          interval_duration: updated_cycle_spec.interval_duration,
          remaining: updated_cycle_spec.repetitions,
          anchor: updated_cycle_spec.anchor,
          occurrence: updated_cycle_spec.occurrence
        }

        :ets.insert(state.primary, {{next_fire_ms, timer_ref}, target, metadata, new_cycle_info})
        :ets.insert(state.target_index, {target_key(target), timer_ref, next_fire_ms})

        emit_telemetry(:armed, timer_ref, %{fire_at: next_fire}, metadata)

        invoke_cycle_advance_callback(
          state,
          Map.put(metadata, :timer_ref, timer_ref),
          next_fire,
          updated_cycle_spec.repetitions
        )

      nil ->
        invoke_cycle_advance_callback(state, Map.put(metadata, :timer_ref, timer_ref), nil, 0)
    end
  end

  defp maybe_rearm_cycle(_state, _target, _metadata, nil, _fire_at_ms), do: :ok

  defp invoke_cycle_advance_callback(
         %{cycle_advance_worker: nil},
         _metadata,
         _next_fire,
         _remaining
       ),
       do: :ok

  defp invoke_cycle_advance_callback(state, metadata, next_fire, remaining) do
    send(state.cycle_advance_worker, {:cycle_advance, metadata, next_fire, remaining})
  end

  defp start_cycle_advance_worker(nil), do: nil

  defp start_cycle_advance_worker(on_cycle_advance) do
    spawn_link(fn -> run_cycle_advance_worker(on_cycle_advance) end)
  end

  defp run_cycle_advance_worker({module, function, extra_args} = on_cycle_advance) do
    receive do
      {:cycle_advance, metadata, next_fire, remaining} ->
        apply_cycle_advance_callback(module, function, [
          metadata,
          next_fire,
          remaining | extra_args
        ])

        run_cycle_advance_worker(on_cycle_advance)
    end
  end

  defp apply_cycle_advance_callback(module, function, arguments) do
    apply(module, function, arguments)
  catch
    kind, reason ->
      Logger.error(
        "Scheduler: on_cycle_advance callback failed: #{Exception.format(kind, reason, __STACKTRACE__)}"
      )
  end

  defp find_by_ref(primary_table, timer_ref) do
    match_pattern = {{:"$5", :"$1"}, :"$2", :"$3", :"$4"}
    guards = [{:==, :"$1", timer_ref}]
    result = [{{{{:"$5", :"$1"}}, :"$2", :"$3", :"$4"}}]

    case :ets.select(primary_table, [{match_pattern, guards, result}]) do
      [{key, target, metadata, cycle_info}] -> {key, target, metadata, cycle_info}
      [] -> nil
    end
  end

  defp delete_timer(state, {fire_at_ms, timer_ref} = key, _timer_ref) do
    [{^key, target, _metadata, _cycle_info}] = :ets.lookup(state.primary, key)
    :ets.delete(state.primary, key)
    :ets.match_delete(state.target_index, {target_key(target), timer_ref, fire_at_ms})
  end

  defp do_fire_now_for_target(state, target) do
    target_entries = :ets.lookup(state.target_index, target_key(target))

    Enum.count(target_entries, fn {_target_key, timer_ref, fire_at_ms} ->
      case :ets.lookup(state.primary, {fire_at_ms, timer_ref}) do
        [{key, ^target, metadata, cycle_info}] ->
          delivered? = deliver_fire_message(target, timer_ref, metadata)
          delete_timer(state, key, timer_ref)
          emit_telemetry(:fired, timer_ref, %{}, metadata)
          maybe_rearm_cycle(state, {target, timer_ref}, metadata, cycle_info, fire_at_ms)
          delivered?

        [] ->
          false
      end
    end)
  end

  defp do_cancel_all_for_target(state, target) do
    target_entries = :ets.lookup(state.target_index, target_key(target))

    Enum.each(target_entries, fn {_target_key, timer_ref, fire_at_ms} ->
      :ets.delete(state.primary, {fire_at_ms, timer_ref})
      emit_telemetry(:cancelled, timer_ref, %{}, %{})
    end)

    :ets.match_delete(state.target_index, {target_key(target), :_, :_})

    length(target_entries)
  end

  defp maybe_monitor_pid(state, target) when is_pid(target) do
    if Map.has_key?(state.monitored_pids, target) do
      state
    else
      monitor_ref = Process.monitor(target)
      %{state | monitored_pids: Map.put(state.monitored_pids, target, monitor_ref)}
    end
  end

  defp maybe_monitor_pid(state, _atom_target), do: state

  defp demonitor_target(state, target) do
    case Map.pop(state.monitored_pids, target) do
      {nil, _monitored_pids} ->
        state

      {monitor_ref, monitored_pids} ->
        Process.demonitor(monitor_ref, [:flush])
        %{state | monitored_pids: monitored_pids}
    end
  end

  defp target_key(target) when is_pid(target), do: target
  defp target_key(target) when is_atom(target), do: target

  defp generate_timer_ref do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  # Without an explicit anchor the first scheduled fire is occurrence 0.
  defp build_cycle_info(%{cycle_interval: interval, cycle_remaining: remaining} = request)
       when not is_nil(interval) and not is_nil(remaining) do
    %{
      interval_duration: interval,
      remaining: remaining,
      anchor: Map.get(request, :cycle_anchor) || request.fire_at,
      occurrence: Map.get(request, :cycle_occurrence) || 0
    }
  end

  defp build_cycle_info(_request), do: nil

  defp emit_telemetry(event_type, timer_ref, measurements, metadata) do
    :telemetry.execute(
      [:bfw_engine, :timer, event_type],
      Map.merge(measurements, %{timer_ref: timer_ref}),
      metadata
    )
  end
end
