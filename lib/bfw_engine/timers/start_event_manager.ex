defmodule BfwEngine.Timers.StartEventManager do
  @moduledoc """
  Manages the lifecycle of Timer Start Event schedules.

  This module does NOT scan BPMN models -- it receives pre-extracted
  timer specs from the caller (the deploy path in `BfwEngine.Execution`).
  It does NOT know about FEEL or `BfwEngine.Expressions`. Timer Start Events
  have no PI context, so their specs are always literal ISO 8601.

  ## Responsibilities

  - Persist Timer Start schedules to the database via the Persistence behaviour
  - Register/unregister timer schedules in the Scheduler ETS
  - Enable/disable individual schedules without redeployment
  - Track `last_triggered_at`, `next_fire_at`, and cycle state
  - Provide listing/detail queries for the REST API

  ## Cycle Advance Callback

  The Scheduler invokes `handle_cycle_advance/3` after each cycle fire,
  from its callback worker rather than its tick. This updates the
  persistence record with the new `next_fire_at` and decremented
  `cycle_remaining`; it is the only writer of that cycle state while the
  schedule is armed.
  """

  require Logger

  alias BfwEngine.Timers.ISO8601
  alias BfwEngine.Timers.Scheduler

  @type timer_start_spec :: %{
          flow_node_id: String.t(),
          kind: :date | :duration | :cycle,
          iso_spec: String.t()
        }

  @doc """
  Registers Timer Start Events for a deployed process version.

  For each spec:
  1. Resolves the ISO 8601 string into a concrete fire-at time; a cycle whose
     start lies in the past skips its due occurrences, each using up one
     repetition
  2. Persists the schedule record (enabled by default; exhausted when a
     finite cycle has no occurrence left)
  3. Registers the timer in the Scheduler, unless the cycle is exhausted

  Called from the deploy path in `BfwEngine.Execution` or the API layer.
  """
  @spec register_timer_starts(
          process_version_id :: String.t(),
          process_model_id :: String.t(),
          timer_start_specs :: [timer_start_spec()],
          keyword()
        ) :: :ok
  def register_timer_starts(process_version_id, process_model_id, timer_start_specs, opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler
    now = opts[:reference_time] || DateTime.utc_now()

    Enum.each(timer_start_specs, fn spec ->
      register_single_timer_start(process_version_id, process_model_id, spec, scheduler, now)
    end)

    :ok
  end

  @doc """
  Unregisters all Timer Start Events for a given process version.

  Holding the lock of each of the version's schedules, cancels their
  Scheduler entries individually, then deletes them from persistence.
  When the schedules cannot be listed, nothing is cancelled or deleted
  and `{:error, reason}` is returned.
  """
  @spec unregister_timer_starts(process_version_id :: String.t(), keyword()) ::
          :ok | {:error, term()}
  def unregister_timer_starts(process_version_id, opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler

    with {:ok, schedules} <- list_version_schedules(process_version_id) do
      schedules
      |> Enum.map(& &1.id)
      |> Enum.sort()
      |> with_schedule_locks(fn ->
        cancel_and_delete_version_schedules(process_version_id, scheduler)
      end)
    end
  end

  # Re-lists under the locks: an enable may have replaced a scheduler_ref meanwhile.
  defp cancel_and_delete_version_schedules(process_version_id, scheduler) do
    with {:ok, schedules} <- list_version_schedules(process_version_id) do
      Enum.each(schedules, &cancel_single_scheduler_entry(&1.scheduler_ref, scheduler))
      persistence().delete_schedules_for_version(process_version_id)
    end
  end

  defp list_version_schedules(process_version_id) do
    case persistence().list_all_schedules(process_version_id: process_version_id) do
      {:ok, schedules} ->
        {:ok, schedules}

      {:error, reason} = error ->
        Logger.error(
          "StartEventManager: cannot list the schedules of version #{process_version_id}; " <>
            "they stay registered: #{inspect(reason)}"
        )

        error
    end
  end

  # Ids are taken in sorted order so that two callers cannot deadlock.
  defp with_schedule_locks([], fun), do: fun.()

  defp with_schedule_locks([schedule_id | remaining_ids], fun),
    do: with_schedule_lock(schedule_id, fn -> with_schedule_locks(remaining_ids, fun) end)

  # ponytail: node-local lock; a multi-node deployment needs a database lock per schedule.
  defp with_schedule_lock(schedule_id, fun),
    do: :global.trans({{:bfw_timer_schedule, schedule_id}, self()}, fun, [node()])

  @doc """
  Enables a previously disabled schedule. Re-evaluates `next_fire_at`
  based on the current time and re-registers in the Scheduler, replacing
  any entry it still has, so enabling an enabled schedule arms it once.

  Only meaningful for cycle schedules. Returns `{:error, :not_a_cycle}`
  for date/duration schedules (those are PI-scoped, not deploy-scoped).
  A finite cycle keeps its persisted `cycle_remaining`; an exhausted one
  (`cycle_remaining` 0) is enabled but not re-armed. A start-anchored cycle
  continues from its persisted `next_fire_at`; a cycle without a start fires
  one interval after the enable. Occurrences that are already due are
  skipped, each using up one repetition; when none is left the schedule is
  persisted exhausted.
  """
  @spec enable_schedule(schedule_id :: String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_schedule(schedule_id, opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler
    now = opts[:reference_time] || DateTime.utc_now()

    with_schedule_lock(schedule_id, fn ->
      with {:ok, schedule} <- persistence().get_schedule(schedule_id),
           :ok <- require_cycle(schedule) do
        enable_cycle_schedule(schedule, scheduler, now)
      end
    end)
  end

  defp enable_cycle_schedule(%{cycle_remaining: 0} = schedule, _scheduler, _now),
    do: persistence().update_schedule(schedule.id, %{enabled: true})

  defp enable_cycle_schedule(schedule, scheduler, now),
    do: arm_enabled_schedule(schedule, scheduler, now)

  defp arm_enabled_schedule(schedule, scheduler, now) do
    with {:ok, {:cycle, cycle_spec}} <- ISO8601.resolve_fire_at(:cycle, schedule.iso_spec, now) do
      pending_spec = %{cycle_spec | repetitions: schedule.cycle_remaining || :infinite}
      pending_occurrence = enabled_pending_occurrence(pending_spec, schedule, now)

      pending_spec
      |> anchor_at_start(pending_occurrence)
      |> ISO8601.skip_missed_occurrences(pending_occurrence, now)
      |> arm_enabled_occurrence(schedule, scheduler)
    end
  end

  # A start-anchored cycle keeps its schedule: the persisted next occurrence is the
  # one `cycle_remaining` counts from, so occurrences fired before the disable are
  # not counted again. A cycle without a start is re-anchored at the enable.
  defp enabled_pending_occurrence(
         %{start_at: %DateTime{}},
         %{next_fire_at: %DateTime{} = next_fire_at},
         _now
       ),
       do: next_fire_at

  defp enabled_pending_occurrence(cycle_spec, _schedule, now),
    do: ISO8601.first_fire_at(cycle_spec, now)

  # The new state is persisted before the old entry is cancelled: a failed write
  # leaves the schedule as it was.
  defp arm_enabled_occurrence({next_fire_at, cycle_spec}, schedule, scheduler) do
    changes = Map.put(cycle_state_changes(next_fire_at, cycle_spec.repetitions), :enabled, true)

    with {:ok, updated} <- persistence().update_schedule(schedule.id, changes) do
      cancel_single_scheduler_entry(schedule.scheduler_ref, scheduler)

      store_scheduler_ref(
        updated,
        schedule_in_scheduler(updated, scheduler, cycle_spec),
        scheduler
      )
    end
  end

  defp arm_enabled_occurrence(nil, schedule, scheduler) do
    changes = Map.merge(cycle_state_changes(nil, 0), %{enabled: true, scheduler_ref: nil})

    with {:ok, updated} <- persistence().update_schedule(schedule.id, changes) do
      cancel_single_scheduler_entry(schedule.scheduler_ref, scheduler)
      {:ok, updated}
    end
  end

  # Decision D-2: due occurrences are skipped, each using up one repetition.
  defp first_future_occurrence(cycle_spec, now) do
    ISO8601.skip_missed_occurrences(cycle_spec, ISO8601.first_fire_at(cycle_spec, now), now)
  end

  @doc """
  Disables a schedule. Cancels the Scheduler entry but preserves the
  persistence record.

  Only meaningful for cycle schedules. Returns `{:error, :not_a_cycle}`
  for date/duration schedules (those are PI-scoped, not deploy-scoped).
  """
  @spec disable_schedule(schedule_id :: String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_schedule(schedule_id, opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler

    with_schedule_lock(schedule_id, fn ->
      with {:ok, schedule} <- persistence().get_schedule(schedule_id),
           :ok <- require_cycle(schedule) do
        cancel_single_scheduler_entry(schedule.scheduler_ref, scheduler)
        persistence().update_schedule(schedule_id, %{enabled: false, scheduler_ref: nil})
      end
    end)
  end

  defp cancel_single_scheduler_entry(nil, _scheduler), do: :ok

  defp cancel_single_scheduler_entry(scheduler_ref, scheduler) do
    _cancel_result = Scheduler.cancel(scheduler_ref, scheduler)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "Lists all Timer Start schedules, optionally filtered."
  @spec list_schedules(keyword()) :: {:ok, [map()]}
  def list_schedules(opts \\ []) do
    persistence().list_all_schedules(opts)
  end

  @doc "Retrieves a single schedule by ID."
  @spec get_schedule(schedule_id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_schedule(schedule_id) do
    persistence().get_schedule(schedule_id)
  end

  @doc """
  Records a successful Timer Start fire by updating `last_triggered_at`.

  Called by `TimerStartListener` in `BfwEngine.Execution` after creating a PI.
  Cycle state (`next_fire_at`, `cycle_remaining`) is owned by
  `handle_cycle_advance/3`, which the Scheduler calls on every fire,
  including fires the listener skips.
  """
  @spec record_fire(schedule_id :: String.t()) :: :ok | {:error, term()}
  def record_fire(schedule_id) do
    with {:ok, _schedule} <- persistence().get_schedule(schedule_id) do
      persistence().update_schedule(schedule_id, %{last_triggered_at: DateTime.utc_now()})
      :ok
    end
  end

  @doc """
  Cycle advance callback invoked by the Scheduler after each cycle fire.

  Updates persistence with the new `next_fire_at` and `cycle_remaining`.
  This is the MFA callback passed to the Scheduler as `on_cycle_advance`.

  Runs under the schedule's lock and writes only while the schedule is
  enabled and its `scheduler_ref` is the `timer_ref` in `metadata`: an
  advance queued before a disable, re-enable, or reload is dropped.
  """
  @spec handle_cycle_advance(map(), DateTime.t() | nil, non_neg_integer() | :infinite) :: :ok
  def handle_cycle_advance(
        %{schedule_id: schedule_id, timer_ref: timer_ref},
        next_fire_at,
        remaining
      )
      when is_binary(schedule_id) do
    with_schedule_lock(schedule_id, fn ->
      case persistence().get_schedule(schedule_id) do
        {:ok, %{enabled: true, scheduler_ref: ^timer_ref}} ->
          persistence().update_schedule(schedule_id, cycle_state_changes(next_fire_at, remaining))

        _stale_or_missing ->
          :ok
      end
    end)

    :ok
  end

  def handle_cycle_advance(_metadata, _next_fire_at, _remaining), do: :ok

  @doc """
  Loads all armed cycle schedules from persistence and registers them
  in the Scheduler. Called at engine boot and by the Scheduler after it
  restarted from a crash (its `on_restart` callback).

  Only cycle schedules are re-armed. Date/duration timer starts are
  PI-scoped (their blocking behavior lives inside the PI handler) and
  are never auto-scheduled. A finite cycle resumes with its persisted
  `cycle_remaining`, not the repetition count of its spec; an exhausted
  schedule has no `next_fire_at` and is not listed as armed. Occurrences
  whose time passed while the schedule was not armed are skipped, each
  using up one repetition, and the next future occurrence is persisted and
  armed. A Scheduler entry still holding the persisted `scheduler_ref` is
  replaced, so reloading twice arms each schedule once.

  Returns `{:error, reason}` when the armed schedules cannot be listed.
  """
  @spec reload_start_schedules(keyword()) :: :ok | {:error, term()}
  def reload_start_schedules(opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler
    now = DateTime.utc_now()

    with {:ok, schedules} <- persistence().list_armed_schedules() do
      cycle_schedules = Enum.filter(schedules, &(&1.kind == "cycle"))
      Enum.each(cycle_schedules, &reload_locked_schedule(&1.id, scheduler, now))

      Logger.info(
        "StartEventManager: loaded #{length(cycle_schedules)} armed cycle timer start schedule(s)"
      )
    end
  end

  # Re-read under the lock: an enable, disable or unregister may have run since the listing.
  defp reload_locked_schedule(schedule_id, scheduler, now) do
    with_schedule_lock(schedule_id, fn ->
      case persistence().get_schedule(schedule_id) do
        {:ok, %{enabled: true, next_fire_at: %DateTime{}} = schedule} ->
          reload_single_schedule(schedule, scheduler, now)

        _not_armed ->
          :ok
      end
    end)
  end

  defp reload_single_schedule(schedule, scheduler, now) do
    case ISO8601.parse_cycle(schedule.iso_spec) do
      {:ok, cycle_spec} ->
        pending_spec = %{cycle_spec | repetitions: schedule.cycle_remaining || :infinite}

        pending_spec
        |> anchor_at_start(schedule.next_fire_at)
        |> ISO8601.skip_missed_occurrences(schedule.next_fire_at, now)
        |> rearm_reloaded_schedule(schedule, scheduler)

      {:error, reason} ->
        Logger.error(
          "StartEventManager: cannot reload schedule #{schedule.id} (#{schedule.iso_spec}): " <>
            inspect(reason)
        )
    end
  end

  defp rearm_reloaded_schedule({next_fire_at, cycle_spec}, schedule, scheduler) do
    changes = cycle_state_changes(next_fire_at, cycle_spec.repetitions)

    with {:ok, updated} <- persistence().update_schedule(schedule.id, changes) do
      cancel_single_scheduler_entry(schedule.scheduler_ref, scheduler)

      store_scheduler_ref(
        updated,
        schedule_in_scheduler(updated, scheduler, cycle_spec),
        scheduler
      )
    end
  end

  defp rearm_reloaded_schedule(nil, schedule, scheduler) do
    cancel_single_scheduler_entry(schedule.scheduler_ref, scheduler)
    persistence().update_schedule(schedule.id, cycle_state_changes(nil, 0))
  end

  # A calendar interval counts from the spec's explicit start, the occurrence
  # the persisted one is found from. Without a start, or when the start does
  # not lead to it, the persisted occurrence becomes the anchor.
  defp anchor_at_start(
         %{start_at: %DateTime{} = start_at, interval_duration: interval} = cycle_spec,
         %DateTime{} = pending_occurrence
       )
       when interval.year != 0 or interval.month != 0 do
    case occurrence_index(interval, start_at, pending_occurrence, 0) do
      nil -> cycle_spec
      index -> Map.merge(cycle_spec, %{anchor: start_at, occurrence: index})
    end
  end

  defp anchor_at_start(cycle_spec, _pending_occurrence), do: cycle_spec

  defp occurrence_index(interval, start_at, pending_occurrence, index) do
    occurrence = DateTime.shift(start_at, Duration.multiply(interval, index))

    cond do
      DateTime.compare(occurrence, pending_occurrence) == :eq ->
        index

      DateTime.before?(occurrence, pending_occurrence) ->
        occurrence_index(interval, start_at, pending_occurrence, index + 1)

      true ->
        nil
    end
  end

  defp cycle_state_changes(next_fire_at, :infinite), do: %{next_fire_at: next_fire_at}

  defp cycle_state_changes(next_fire_at, remaining),
    do: %{next_fire_at: next_fire_at, cycle_remaining: remaining}

  # --- Private ---

  defp require_cycle(%{kind: "cycle"}), do: :ok
  defp require_cycle(_schedule), do: {:error, :not_a_cycle}

  defp register_single_timer_start(process_version_id, process_model_id, spec, scheduler, now) do
    kind = spec.kind

    case resolve_next_fire(kind, spec.iso_spec, now) do
      {:ok, next_fire_at, cycle_info, cycle_remaining} ->
        attrs =
          process_version_id
          |> build_schedule_attrs(process_model_id, spec, next_fire_at, cycle_info)
          |> Map.put(:cycle_remaining, cycle_remaining)

        persist_and_schedule(attrs, next_fire_at, cycle_info, scheduler, spec.flow_node_id)

      {:error, reason} ->
        Logger.error(
          "StartEventManager: failed to resolve timer for #{spec.flow_node_id}: #{inspect(reason)}"
        )
    end
  end

  defp build_schedule_attrs(process_version_id, process_model_id, spec, next_fire_at, cycle_info) do
    {cycle_total, cycle_remaining} = extract_cycle_counts(cycle_info)

    %{
      process_version_id: process_version_id,
      process_model_id: process_model_id,
      flow_node_id: spec.flow_node_id,
      kind: Atom.to_string(spec.kind),
      iso_spec: spec.iso_spec,
      enabled: true,
      next_fire_at: next_fire_at,
      last_triggered_at: nil,
      cycle_total: cycle_total,
      cycle_remaining: cycle_remaining
    }
  end

  defp persist_and_schedule(attrs, next_fire_at, cycle_info, scheduler, flow_node_id) do
    case persistence().create_schedule(attrs) do
      {:ok, _record} when is_nil(next_fire_at) ->
        Logger.info(
          "StartEventManager: cycle timer start #{flow_node_id} has no occurrence left; not armed"
        )

      {:ok, record} ->
        with_schedule_lock(record.id, fn ->
          store_scheduler_ref(
            record,
            schedule_in_scheduler(record, scheduler, cycle_info),
            scheduler
          )
        end)

      {:error, reason} ->
        Logger.error(
          "StartEventManager: failed to persist schedule for #{flow_node_id}: #{inspect(reason)}"
        )
    end
  end

  # An entry whose ref was not persisted could never be cancelled.
  defp store_scheduler_ref(schedule, {:ok, timer_ref}, scheduler) do
    case persistence().update_schedule(schedule.id, %{scheduler_ref: timer_ref}) do
      {:error, _reason} = error ->
        cancel_single_scheduler_entry(timer_ref, scheduler)
        error

      stored ->
        stored
    end
  end

  defp store_scheduler_ref(schedule, {:error, reason} = error, _scheduler) do
    Logger.error("StartEventManager: cannot arm schedule #{schedule.id}: #{inspect(reason)}")

    if schedule.scheduler_ref do
      _cleared = persistence().update_schedule(schedule.id, %{scheduler_ref: nil})
    end

    error
  end

  defp resolve_next_fire(:date, iso_spec, _now) do
    case ISO8601.resolve_fire_at(:date, iso_spec, DateTime.utc_now()) do
      {:ok, fire_at} -> {:ok, fire_at, nil, nil}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_next_fire(:duration, iso_spec, now) do
    case ISO8601.resolve_fire_at(:duration, iso_spec, now) do
      {:ok, fire_at} -> {:ok, fire_at, nil, nil}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_next_fire(:cycle, iso_spec, now) do
    case ISO8601.resolve_fire_at(:cycle, iso_spec, now) do
      {:ok, {:cycle, cycle_spec}} ->
        case first_future_occurrence(cycle_spec, now) do
          {first_fire, %{repetitions: :infinite} = pending_spec} ->
            {:ok, first_fire, with_anchor_of(cycle_spec, pending_spec), nil}

          {first_fire, pending_spec} ->
            {:ok, first_fire, with_anchor_of(cycle_spec, pending_spec), pending_spec.repetitions}

          nil ->
            {:ok, nil, cycle_spec, 0}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp with_anchor_of(cycle_spec, pending_spec),
    do: Map.merge(cycle_spec, Map.take(pending_spec, [:anchor, :occurrence]))

  defp schedule_in_scheduler(schedule_record, scheduler, cycle_info) do
    request = %{
      fire_at: schedule_record.next_fire_at,
      target: timer_start_target(),
      metadata: %{
        schedule_id: schedule_record.id,
        process_version_id: schedule_record.process_version_id,
        process_model_id: schedule_record.process_model_id,
        flow_node_id: schedule_record.flow_node_id
      }
    }

    request =
      if cycle_info do
        Map.merge(request, %{
          cycle_interval: cycle_info.interval_duration,
          cycle_remaining: schedule_record.cycle_remaining || :infinite,
          cycle_anchor: Map.get(cycle_info, :anchor),
          cycle_occurrence: Map.get(cycle_info, :occurrence)
        })
      else
        request
      end

    Scheduler.schedule(request, scheduler)
  catch
    :exit, reason -> {:error, {:scheduler_unavailable, reason}}
  end

  defp extract_cycle_counts(nil), do: {nil, nil}

  defp extract_cycle_counts(%{repetitions: :infinite}), do: {nil, nil}

  defp extract_cycle_counts(%{repetitions: count}) when is_integer(count) do
    {count, count}
  end

  defp timer_start_target do
    Application.get_env(
      :bfw_engine,
      :timer_start_target,
      BfwEngine.Execution.TimerStartListener
    )
  end

  defp persistence do
    Application.get_env(:bfw_engine, :persistence_module, BfwEngine.Timers.Persistence.NoOp)
  end
end
