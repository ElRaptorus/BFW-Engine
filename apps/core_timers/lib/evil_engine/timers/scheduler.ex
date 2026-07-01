defmodule EvilEngine.Timers.Scheduler do
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
  fire time via `ISO8601.next_cycle_fire/2` and re-inserts into ETS.
  An optional `on_cycle_advance` callback (MFA) is invoked so the
  `StartEventManager` can persist updated `next_fire_at`.
  """

  use GenServer

  require Logger

  alias EvilEngine.Timers.ISO8601

  @type timer_ref :: String.t()
  @type target :: pid() | atom()

  @type cycle_info :: %{
          interval_duration: Duration.t(),
          remaining: pos_integer() | :infinite
        }

  @type schedule_request :: %{
          required(:fire_at) => DateTime.t(),
          required(:target) => target(),
          required(:metadata) => map(),
          optional(:cycle_interval) => Duration.t() | nil,
          optional(:cycle_remaining) => pos_integer() | :infinite | nil
        }

  @default_primary_table :evil_engine_timers_primary
  @default_target_index_table :evil_engine_timers_target_index

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

  Returns the number of timers fired.
  """
  @spec fire_now_for_target(target(), GenServer.server()) :: non_neg_integer()
  def fire_now_for_target(target, server \\ __MODULE__) do
    GenServer.call(server, {:fire_now_for_target, target})
  end

  @doc """
  Resets internal state. Deletes all ETS entries and demonitors all PIDs.
  Intended for test isolation only.
  """
  @spec reset_state(GenServer.server()) :: :ok
  def reset_state(server \\ __MODULE__) do
    GenServer.call(server, :reset_state)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    primary_name = opts[:primary_table] || @default_primary_table
    target_index_name = opts[:target_index_table] || @default_target_index_table

    primary = :ets.new(primary_name, [:ordered_set, :protected, :named_table])
    target_index = :ets.new(target_index_name, [:bag, :protected, :named_table])

    tick_interval_ms =
      opts[:tick_interval_ms] || Application.get_env(:core_timers, :tick_interval_ms, 1000)

    on_cycle_advance = opts[:on_cycle_advance]

    schedule_tick(tick_interval_ms)

    {:ok,
     %{
       primary: primary,
       target_index: target_index,
       tick_interval_ms: tick_interval_ms,
       on_cycle_advance: on_cycle_advance,
       monitored_pids: %{}
     }}
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
    {:reply, count, state}
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
  def handle_call(:reset_state, _from, state) do
    :ets.delete_all_objects(state.primary)
    :ets.delete_all_objects(state.target_index)

    Enum.each(state.monitored_pids, fn {_pid, monitor_ref} ->
      Process.demonitor(monitor_ref, [:flush])
    end)

    {:reply, :ok, %{state | monitored_pids: %{}}}
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

        maybe_rearm_cycle(state, target, metadata, cycle_info, fire_at_ms)

        fire_expired_timers_loop(state, now_ms)

      _future_key ->
        :ok
    end
  end

  defp deliver_fire_message(target, timer_ref, metadata) when is_pid(target) do
    if Process.alive?(target) do
      send(target, {:timer_fired, timer_ref, metadata})
    else
      Logger.debug(
        "Scheduler: target PID #{inspect(target)} is dead, dropping fire for #{timer_ref}"
      )
    end
  end

  defp deliver_fire_message(target, timer_ref, metadata) when is_atom(target) do
    case Process.whereis(target) do
      nil ->
        Logger.warning(
          "Scheduler: registered name #{inspect(target)} not found, dropping fire for #{timer_ref}"
        )

      pid ->
        send(pid, {:timer_fired, timer_ref, metadata})
    end
  end

  defp maybe_rearm_cycle(state, target, metadata, cycle_info, fire_at_ms)
       when is_map(cycle_info) do
    fire_at = DateTime.from_unix!(fire_at_ms, :millisecond)

    cycle_spec = %{
      repetitions: cycle_info.remaining,
      interval_duration: cycle_info.interval_duration,
      start_at: nil
    }

    case ISO8601.next_cycle_fire(cycle_spec, fire_at) do
      {next_fire, updated_cycle_spec} ->
        new_ref = generate_timer_ref()
        next_fire_ms = DateTime.to_unix(next_fire, :millisecond)

        new_cycle_info = %{
          interval_duration: updated_cycle_spec.interval_duration,
          remaining: updated_cycle_spec.repetitions
        }

        :ets.insert(state.primary, {{next_fire_ms, new_ref}, target, metadata, new_cycle_info})
        :ets.insert(state.target_index, {target_key(target), new_ref, next_fire_ms})

        emit_telemetry(:armed, new_ref, %{fire_at: next_fire}, metadata)

        invoke_cycle_advance_callback(state, metadata, next_fire, updated_cycle_spec.repetitions)

      nil ->
        invoke_cycle_advance_callback(state, metadata, nil, 0)
    end
  end

  defp maybe_rearm_cycle(_state, _target, _metadata, nil, _fire_at_ms), do: :ok

  defp invoke_cycle_advance_callback(%{on_cycle_advance: nil}, _metadata, _next_fire, _remaining),
    do: :ok

  defp invoke_cycle_advance_callback(
         %{on_cycle_advance: {module, function, extra_args}},
         metadata,
         next_fire,
         remaining
       ) do
    apply(module, function, [metadata, next_fire, remaining | extra_args])
  rescue
    exception ->
      Logger.error("Scheduler: on_cycle_advance callback failed: #{Exception.message(exception)}")
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

    Enum.each(target_entries, fn {_target_key, timer_ref, fire_at_ms} ->
      case :ets.lookup(state.primary, {fire_at_ms, timer_ref}) do
        [{key, ^target, metadata, cycle_info}] ->
          deliver_fire_message(target, timer_ref, metadata)
          delete_timer(state, key, timer_ref)
          emit_telemetry(:fired, timer_ref, %{}, metadata)
          maybe_rearm_cycle(state, target, metadata, cycle_info, fire_at_ms)

        [] ->
          :ok
      end
    end)

    length(target_entries)
  end

  defp do_cancel_all_for_target(state, target) do
    target_entries = :ets.lookup(state.target_index, target_key(target))

    Enum.each(target_entries, fn {_target_key, timer_ref, fire_at_ms} ->
      :ets.delete(state.primary, {fire_at_ms, timer_ref})
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

  defp target_key(target) when is_pid(target), do: target
  defp target_key(target) when is_atom(target), do: target

  defp generate_timer_ref do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp build_cycle_info(%{cycle_interval: interval, cycle_remaining: remaining})
       when not is_nil(interval) and not is_nil(remaining) do
    %{interval_duration: interval, remaining: remaining}
  end

  defp build_cycle_info(_request), do: nil

  defp emit_telemetry(event_type, timer_ref, measurements, metadata) do
    :telemetry.execute(
      [:evil_engine, :timer, event_type],
      Map.merge(measurements, %{timer_ref: timer_ref}),
      metadata
    )
  end
end
