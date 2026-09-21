defmodule BfwEngine.Timers.StartEventManager do
  @moduledoc """
  Manages the lifecycle of Timer Start Event schedules.

  This module does NOT scan BPMN models -- it receives pre-extracted
  timer specs from the caller (the deploy path in `core_execution`).
  It does NOT know about FEEL or `core_expressions`. Timer Start Events
  have no PI context, so their specs are always literal ISO 8601.

  ## Responsibilities

  - Persist Timer Start schedules to the database via the Persistence behaviour
  - Register/unregister timer schedules in the Scheduler ETS
  - Enable/disable individual schedules without redeployment
  - Track `last_triggered_at`, `next_fire_at`, and cycle state
  - Provide listing/detail queries for the REST API

  ## Cycle Advance Callback

  The Scheduler invokes `handle_cycle_advance/3` after each cycle fire.
  This updates the persistence record with the new `next_fire_at` and
  decremented `cycle_remaining`.
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
  1. Resolves the ISO 8601 string into a concrete fire-at time
  2. Persists the schedule record (enabled by default)
  3. Registers the timer in the Scheduler

  Called from the deploy path in `core_execution` or the API layer.
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

  Cancels each version's Scheduler entries individually, then deletes
  from persistence.
  """
  @spec unregister_timer_starts(process_version_id :: String.t(), keyword()) :: :ok
  def unregister_timer_starts(process_version_id, opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler

    cancel_scheduler_entries_for_version(process_version_id, scheduler)
    persistence().delete_schedules_for_version(process_version_id)
  end

  defp cancel_scheduler_entries_for_version(process_version_id, scheduler) do
    case persistence().list_all_schedules(process_version_id: process_version_id) do
      {:ok, schedules} ->
        schedules
        |> Enum.filter(& &1.scheduler_ref)
        |> Enum.each(&Scheduler.cancel(&1.scheduler_ref, scheduler))

      _error ->
        :ok
    end
  end

  @doc """
  Enables a previously disabled schedule. Re-evaluates `next_fire_at`
  based on the current time and re-registers in the Scheduler.

  Only meaningful for cycle schedules. Returns `{:error, :not_a_cycle}`
  for date/duration schedules (those are PI-scoped, not deploy-scoped).
  """
  @spec enable_schedule(schedule_id :: String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_schedule(schedule_id, opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler
    now = opts[:reference_time] || DateTime.utc_now()

    with {:ok, schedule} <- persistence().get_schedule(schedule_id),
         :ok <- require_cycle(schedule),
         {:ok, next_fire_at, cycle_info} <- resolve_next_fire(:cycle, schedule.iso_spec, now) do
      changes = build_enable_changes(next_fire_at, cycle_info, schedule)
      {:ok, updated} = persistence().update_schedule(schedule_id, changes)
      store_scheduler_ref(schedule_id, schedule_in_scheduler(updated, scheduler, cycle_info))
      {:ok, updated}
    end
  end

  defp build_enable_changes(next_fire_at, cycle_info, schedule) do
    base = %{enabled: true, next_fire_at: next_fire_at}

    if cycle_info do
      Map.put(base, :cycle_remaining, cycle_remaining_from_info(cycle_info, schedule))
    else
      base
    end
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

    with {:ok, schedule} <- persistence().get_schedule(schedule_id),
         :ok <- require_cycle(schedule) do
      cancel_single_scheduler_entry(schedule.scheduler_ref, scheduler)
      persistence().update_schedule(schedule_id, %{enabled: false, scheduler_ref: nil})
    end
  end

  defp cancel_single_scheduler_entry(nil, _scheduler), do: :ok

  defp cancel_single_scheduler_entry(scheduler_ref, scheduler) do
    _cancel_result = Scheduler.cancel(scheduler_ref, scheduler)
    :ok
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
  Records a successful Timer Start fire. Updates `last_triggered_at`
  and manages cycle state.

  Called by `TimerStartListener` in `core_execution` after creating a PI.
  """
  @spec record_fire(schedule_id :: String.t()) :: :ok | {:error, term()}
  def record_fire(schedule_id) do
    with {:ok, schedule} <- persistence().get_schedule(schedule_id) do
      now = DateTime.utc_now()
      changes = %{last_triggered_at: now}

      changes =
        case schedule.kind do
          "cycle" -> update_cycle_state(changes, schedule)
          _ -> Map.put(changes, :next_fire_at, nil)
        end

      persistence().update_schedule(schedule_id, changes)
      :ok
    end
  end

  @doc """
  Cycle advance callback invoked by the Scheduler after each cycle fire.

  Updates persistence with the new `next_fire_at` and `cycle_remaining`.
  This is the MFA callback passed to the Scheduler as `on_cycle_advance`.
  """
  @spec handle_cycle_advance(map(), DateTime.t() | nil, non_neg_integer() | :infinite) :: :ok
  def handle_cycle_advance(metadata, next_fire_at, remaining) do
    schedule_id = metadata[:schedule_id]

    if schedule_id do
      changes = %{next_fire_at: next_fire_at}

      changes =
        case remaining do
          :infinite -> changes
          count when is_integer(count) -> Map.put(changes, :cycle_remaining, count)
        end

      persistence().update_schedule(schedule_id, changes)
    end

    :ok
  end

  @doc """
  Loads all armed cycle schedules from persistence and registers them
  in the Scheduler. Called during startup / resume.

  Only cycle schedules are re-armed. Date/duration timer starts are
  PI-scoped (their blocking behavior lives inside the PI handler) and
  are never auto-scheduled.
  """
  @spec reload_start_schedules(keyword()) :: :ok
  def reload_start_schedules(opts \\ []) do
    scheduler = opts[:scheduler] || Scheduler

    with {:ok, schedules} <- persistence().list_armed_schedules() do
      cycle_schedules = Enum.filter(schedules, &(&1.kind == "cycle"))
      Enum.each(cycle_schedules, &reload_single_schedule(&1, scheduler))

      Logger.info(
        "StartEventManager: loaded #{length(cycle_schedules)} armed cycle timer start schedule(s)"
      )
    end

    :ok
  end

  defp reload_single_schedule(schedule, scheduler) do
    cycle_info = resolve_cycle_info_for_reload(schedule.iso_spec)
    store_scheduler_ref(schedule.id, schedule_in_scheduler(schedule, scheduler, cycle_info))
  end

  defp resolve_cycle_info_for_reload(iso_spec) do
    case ISO8601.parse_cycle(iso_spec) do
      {:ok, cycle_spec} -> cycle_spec
      {:error, _reason} -> nil
    end
  end

  # --- Private ---

  defp require_cycle(%{kind: "cycle"}), do: :ok
  defp require_cycle(_schedule), do: {:error, :not_a_cycle}

  defp register_single_timer_start(process_version_id, process_model_id, spec, scheduler, now) do
    kind = spec.kind

    case resolve_next_fire(kind, spec.iso_spec, now) do
      {:ok, next_fire_at, cycle_info} ->
        attrs =
          build_schedule_attrs(
            process_version_id,
            process_model_id,
            spec,
            next_fire_at,
            cycle_info
          )

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

  defp persist_and_schedule(attrs, _next_fire_at, cycle_info, scheduler, flow_node_id) do
    case persistence().create_schedule(attrs) do
      {:ok, record} ->
        store_scheduler_ref(record.id, schedule_in_scheduler(record, scheduler, cycle_info))

      {:error, reason} ->
        Logger.error(
          "StartEventManager: failed to persist schedule for #{flow_node_id}: #{inspect(reason)}"
        )
    end
  end

  defp store_scheduler_ref(schedule_id, {:ok, timer_ref}) do
    persistence().update_schedule(schedule_id, %{scheduler_ref: timer_ref})
  end

  defp resolve_next_fire(:date, iso_spec, _now) do
    case ISO8601.resolve_fire_at(:date, iso_spec, DateTime.utc_now()) do
      {:ok, fire_at} -> {:ok, fire_at, nil}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_next_fire(:duration, iso_spec, now) do
    case ISO8601.resolve_fire_at(:duration, iso_spec, now) do
      {:ok, fire_at} -> {:ok, fire_at, nil}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_next_fire(:cycle, iso_spec, now) do
    case ISO8601.resolve_fire_at(:cycle, iso_spec, now) do
      {:ok, {:cycle, cycle_spec}} ->
        first_fire = ISO8601.first_fire_at(cycle_spec, now)
        {:ok, first_fire, cycle_spec}

      {:error, _reason} = error ->
        error
    end
  end

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
          cycle_remaining: cycle_info.repetitions
        })
      else
        request
      end

    Scheduler.schedule(request, scheduler)
  end

  defp extract_cycle_counts(nil), do: {nil, nil}

  defp extract_cycle_counts(%{repetitions: :infinite}), do: {nil, nil}

  defp extract_cycle_counts(%{repetitions: count}) when is_integer(count) do
    {count, count}
  end

  defp cycle_remaining_from_info(%{repetitions: :infinite}, _schedule), do: nil

  defp cycle_remaining_from_info(_cycle_info, schedule) do
    schedule.cycle_remaining
  end

  defp update_cycle_state(changes, schedule) do
    case schedule.cycle_remaining do
      nil ->
        changes

      remaining when remaining > 1 ->
        Map.put(changes, :cycle_remaining, remaining - 1)

      _exhausted ->
        changes
        |> Map.put(:next_fire_at, nil)
        |> Map.put(:cycle_remaining, 0)
    end
  end

  defp timer_start_target do
    Application.get_env(
      :core_timers,
      :timer_start_target,
      BfwEngine.Execution.TimerStartListener
    )
  end

  defp persistence do
    Application.get_env(:core_timers, :persistence_module, BfwEngine.Timers.Persistence.NoOp)
  end
end
