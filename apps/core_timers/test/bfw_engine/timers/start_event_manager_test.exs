defmodule BfwEngine.Timers.StartEventManagerTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Timers.Persistence.NoOp, as: PersistenceNoOp
  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Timers.ServiceReset
  alias BfwEngine.Timers.StartEventManager

  setup do
    ServiceReset.scheduler()
    ServiceReset.timer_persistence()
    :ok
  end

  # Wall-clock future so the 50ms test Scheduler tick cannot treat the armed
  # entry as due. A stale `~U[2026-06-01 ...]` is in the past: the first
  # occurrence fires on the next tick and the cycle state changes under the test.
  defp future_reference_time do
    DateTime.utc_now()
    |> DateTime.add(30 * 24 * 3600, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp far_future_iso, do: "2099-12-25T08:00:00Z"

  defp past_cycle_spec(repetitions, start_at) do
    "R#{repetitions}/#{DateTime.to_iso8601(DateTime.truncate(start_at, :second))}/PT1H"
  end

  defp far_future_datetime, do: ~U[2099-12-25 08:00:00Z]

  # -------------------------------------------------------------------------
  # register_timer_starts/4
  # -------------------------------------------------------------------------

  describe "register_timer_starts/4" do
    test "registers a duration-based timer start event" do
      specs = [
        %{flow_node_id: "TimerStart_1", kind: :duration, iso_spec: "PT1H"}
      ]

      reference_time = future_reference_time()

      assert :ok =
               StartEventManager.register_timer_starts(
                 "pv-1",
                 "order-process",
                 specs,
                 reference_time: reference_time
               )

      {:ok, schedules} = PersistenceNoOp.list_all_schedules()
      assert length(schedules) == 1

      schedule = hd(schedules)
      assert schedule.process_version_id == "pv-1"
      assert schedule.process_model_id == "order-process"
      assert schedule.flow_node_id == "TimerStart_1"
      assert schedule.kind == "duration"
      assert schedule.enabled == true
      assert schedule.next_fire_at == DateTime.add(reference_time, 3600, :second)

      assert Scheduler.armed_count() == 1
    end

    test "registers a date-based timer start event" do
      specs = [
        %{flow_node_id: "TimerStart_date", kind: :date, iso_spec: far_future_iso()}
      ]

      assert :ok =
               StartEventManager.register_timer_starts(
                 "pv-2",
                 "holiday-process",
                 specs,
                 reference_time: future_reference_time()
               )

      {:ok, schedules} = PersistenceNoOp.list_all_schedules()
      schedule = hd(schedules)
      assert schedule.next_fire_at == far_future_datetime()
      assert schedule.cycle_total == nil
    end

    test "registers a cycle-based timer start event" do
      specs = [
        %{flow_node_id: "TimerStart_cycle", kind: :cycle, iso_spec: "R3/PT30M"}
      ]

      reference_time = future_reference_time()

      assert :ok =
               StartEventManager.register_timer_starts(
                 "pv-3",
                 "cycle-process",
                 specs,
                 reference_time: reference_time
               )

      {:ok, schedules} = PersistenceNoOp.list_all_schedules()
      schedule = hd(schedules)
      assert schedule.kind == "cycle"
      assert schedule.cycle_total == 3
      assert schedule.cycle_remaining == 3
      assert schedule.next_fire_at == DateTime.add(reference_time, 1800, :second)
    end

    test "a start-anchored cycle fires its first occurrence at the start" do
      start_at = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)

      specs = [
        %{flow_node_id: "Timer_future", kind: :cycle, iso_spec: past_cycle_spec(3, start_at)}
      ]

      assert :ok = StartEventManager.register_timer_starts("pv-future", "future-process", specs)

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert schedule.cycle_remaining == 3
      assert DateTime.compare(schedule.next_fire_at, DateTime.truncate(start_at, :second)) == :eq
    end

    test "a cycle anchored in the past skips its due occurrences" do
      start_at = DateTime.add(DateTime.utc_now(), -(2 * 3600 + 30 * 60), :second)

      specs = [
        %{flow_node_id: "Timer_past", kind: :cycle, iso_spec: past_cycle_spec(4, start_at)}
      ]

      assert :ok = StartEventManager.register_timer_starts("pv-past", "past-process", specs)

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert schedule.cycle_total == 4
      assert schedule.cycle_remaining == 1

      assert DateTime.compare(
               schedule.next_fire_at,
               DateTime.add(DateTime.truncate(start_at, :second), 3 * 3600, :second)
             ) == :eq

      assert Scheduler.armed_count() == 1
    end

    test "a cycle anchored in the past with no occurrence left is registered exhausted" do
      start_at = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)

      specs = [
        %{flow_node_id: "Timer_over", kind: :cycle, iso_spec: past_cycle_spec(2, start_at)}
      ]

      assert :ok = StartEventManager.register_timer_starts("pv-over", "over-process", specs)

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert schedule.next_fire_at == nil
      assert schedule.cycle_remaining == 0
      assert Scheduler.armed_count() == 0
    end

    test "registers an infinite cycle" do
      specs = [
        %{flow_node_id: "TimerStart_inf", kind: :cycle, iso_spec: "R/PT1H"}
      ]

      assert :ok =
               StartEventManager.register_timer_starts(
                 "pv-4",
                 "inf-process",
                 specs,
                 reference_time: future_reference_time()
               )

      {:ok, schedules} = PersistenceNoOp.list_all_schedules()
      schedule = hd(schedules)
      assert schedule.cycle_total == nil
      assert schedule.cycle_remaining == nil
    end

    test "registers multiple specs in one call" do
      specs = [
        %{flow_node_id: "Timer_1", kind: :duration, iso_spec: "PT1H"},
        %{flow_node_id: "Timer_2", kind: :date, iso_spec: far_future_iso()}
      ]

      assert :ok =
               StartEventManager.register_timer_starts(
                 "pv-5",
                 "multi-process",
                 specs,
                 reference_time: future_reference_time()
               )

      {:ok, schedules} = PersistenceNoOp.list_all_schedules()
      assert length(schedules) == 2
      assert Scheduler.armed_count() == 2
    end

    test "stores scheduler_ref in persistence after registration" do
      specs = [%{flow_node_id: "Timer_ref", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-ref", "ref-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert is_binary(schedule.scheduler_ref)
    end

    test "handles invalid ISO spec gracefully (logs, does not crash)" do
      specs = [
        %{flow_node_id: "Timer_bad", kind: :duration, iso_spec: "not-iso-at-all"}
      ]

      assert :ok =
               StartEventManager.register_timer_starts(
                 "pv-6",
                 "bad-process",
                 specs,
                 reference_time: future_reference_time()
               )

      {:ok, schedules} = PersistenceNoOp.list_all_schedules()
      assert schedules == []
      assert Scheduler.armed_count() == 0
    end
  end

  # -------------------------------------------------------------------------
  # unregister_timer_starts/2
  # -------------------------------------------------------------------------

  describe "unregister_timer_starts/2" do
    test "removes schedules from persistence and cancels from scheduler" do
      specs = [%{flow_node_id: "Timer_1", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-1", "process", specs,
        reference_time: future_reference_time()
      )

      assert Scheduler.armed_count() == 1

      StartEventManager.unregister_timer_starts("pv-1")

      {:ok, schedules} = PersistenceNoOp.list_all_schedules()
      assert schedules == []
    end

    test "is a no-op for nonexistent version" do
      assert :ok = StartEventManager.unregister_timer_starts("nonexistent")
    end

    test "does not cancel scheduler entries for other versions" do
      specs_a = [%{flow_node_id: "Timer_A", kind: :duration, iso_spec: "PT1H"}]
      specs_b = [%{flow_node_id: "Timer_B", kind: :duration, iso_spec: "PT2H"}]

      StartEventManager.register_timer_starts("pv-a", "process-a", specs_a,
        reference_time: future_reference_time()
      )

      StartEventManager.register_timer_starts("pv-b", "process-b", specs_b,
        reference_time: future_reference_time()
      )

      assert Scheduler.armed_count() == 2

      StartEventManager.unregister_timer_starts("pv-a")

      assert Scheduler.armed_count() == 1

      {:ok, remaining} = PersistenceNoOp.list_all_schedules()
      assert length(remaining) == 1
      assert hd(remaining).process_version_id == "pv-b"
    end
  end

  # -------------------------------------------------------------------------
  # enable_schedule / disable_schedule
  # -------------------------------------------------------------------------

  describe "enable_schedule/2 and disable_schedule/2" do
    setup do
      specs = [%{flow_node_id: "Timer_toggle", kind: :cycle, iso_spec: "R3/PT2H"}]

      StartEventManager.register_timer_starts("pv-toggle", "toggle-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      {:ok, schedule_id: schedule.id}
    end

    test "disable_schedule sets enabled to false", %{schedule_id: schedule_id} do
      {:ok, updated} = StartEventManager.disable_schedule(schedule_id)
      assert updated.enabled == false
    end

    test "enable_schedule re-enables a disabled schedule", %{schedule_id: schedule_id} do
      StartEventManager.disable_schedule(schedule_id)

      {:ok, updated} =
        StartEventManager.enable_schedule(schedule_id, reference_time: future_reference_time())

      assert updated.enabled == true
      assert updated.next_fire_at != nil
    end

    test "enabling an enabled schedule keeps a single scheduler entry", %{
      schedule_id: schedule_id
    } do
      assert Scheduler.armed_count() == 1

      for _attempt <- 1..2 do
        {:ok, _enabled} =
          StartEventManager.enable_schedule(schedule_id, reference_time: future_reference_time())
      end

      assert Scheduler.armed_count() == 1
    end

    test "enable_schedule returns error for nonexistent ID" do
      assert {:error, :not_found} = StartEventManager.enable_schedule("nonexistent")
    end

    test "disable_schedule returns error for nonexistent ID" do
      assert {:error, :not_found} = StartEventManager.disable_schedule("nonexistent")
    end

    test "enable_schedule returns :not_a_cycle for duration schedule" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()

      specs = [%{flow_node_id: "Timer_dur", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-dur", "dur-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert {:error, :not_a_cycle} = StartEventManager.enable_schedule(schedule.id)
    end

    test "disable_schedule returns :not_a_cycle for duration schedule" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()

      specs = [%{flow_node_id: "Timer_dur", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-dur", "dur-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert {:error, :not_a_cycle} = StartEventManager.disable_schedule(schedule.id)
    end

    test "disable_schedule does not cancel other schedules' timers" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()

      specs = [
        %{flow_node_id: "Timer_1", kind: :cycle, iso_spec: "R3/PT1H"},
        %{flow_node_id: "Timer_2", kind: :cycle, iso_spec: "R3/PT2H"}
      ]

      StartEventManager.register_timer_starts("pv-iso", "iso-process", specs,
        reference_time: future_reference_time()
      )

      assert Scheduler.armed_count() == 2

      {:ok, all} = PersistenceNoOp.list_all_schedules()
      first_schedule = hd(all)

      {:ok, _updated} = StartEventManager.disable_schedule(first_schedule.id)
      assert Scheduler.armed_count() == 1
    end

    test "disable then enable restores scheduler entry" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()

      specs = [%{flow_node_id: "Timer_re", kind: :cycle, iso_spec: "R3/PT1H"}]

      StartEventManager.register_timer_starts("pv-re", "re-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert Scheduler.armed_count() == 1

      StartEventManager.disable_schedule(schedule.id)
      assert Scheduler.armed_count() == 0

      StartEventManager.enable_schedule(schedule.id, reference_time: future_reference_time())
      assert Scheduler.armed_count() == 1
    end

    test "enable_schedule skips occurrences that came due while disabled, from the persisted remaining" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()

      start_at =
        DateTime.truncate(
          DateTime.add(DateTime.utc_now(), -(2 * 3600 + 30 * 60), :second),
          :second
        )

      PersistenceNoOp.create_schedule(%{
        id: "past-anchored-cycle",
        process_version_id: "pv-past-enable",
        process_model_id: "past-enable-model",
        flow_node_id: "Timer_past_enable",
        kind: "cycle",
        iso_spec: past_cycle_spec(10, start_at),
        enabled: false,
        next_fire_at: DateTime.add(start_at, 3600, :second),
        cycle_total: 10,
        cycle_remaining: 9
      })

      {:ok, updated} = StartEventManager.enable_schedule("past-anchored-cycle")

      assert updated.enabled == true
      assert updated.cycle_remaining == 7

      assert DateTime.compare(updated.next_fire_at, DateTime.add(start_at, 3 * 3600, :second)) ==
               :eq

      assert Scheduler.armed_count() == 1
    end

    test "enable_schedule does not count occurrences that fired before the disable again" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()

      start_at =
        DateTime.truncate(
          DateTime.add(DateTime.utc_now(), -(2 * 3600 + 30 * 60), :second),
          :second
        )

      pending_occurrence = DateTime.add(start_at, 3 * 3600, :second)

      PersistenceNoOp.create_schedule(%{
        id: "anchored-cycle-fired-before-disable",
        process_version_id: "pv-fired-enable",
        process_model_id: "fired-enable-model",
        flow_node_id: "Timer_fired_enable",
        kind: "cycle",
        iso_spec: past_cycle_spec(10, start_at),
        enabled: false,
        next_fire_at: pending_occurrence,
        cycle_total: 10,
        cycle_remaining: 7
      })

      {:ok, updated} = StartEventManager.enable_schedule("anchored-cycle-fired-before-disable")

      assert updated.cycle_remaining == 7
      assert DateTime.compare(updated.next_fire_at, pending_occurrence) == :eq
      assert Scheduler.armed_count() == 1
    end

    test "enable_schedule persists a past-anchored cycle without occurrences left as exhausted" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()
      start_at = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)

      PersistenceNoOp.create_schedule(%{
        id: "past-anchored-exhausted",
        process_version_id: "pv-past-exhausted",
        process_model_id: "past-exhausted-model",
        flow_node_id: "Timer_past_exhausted",
        kind: "cycle",
        iso_spec: past_cycle_spec(10, start_at),
        enabled: false,
        next_fire_at: nil,
        cycle_total: 10,
        cycle_remaining: 2
      })

      {:ok, updated} = StartEventManager.enable_schedule("past-anchored-exhausted")

      assert updated.enabled == true
      assert updated.next_fire_at == nil
      assert updated.cycle_remaining == 0
      assert Scheduler.armed_count() == 0
    end

    test "enable_schedule keeps an exhausted finite cycle exhausted" do
      ServiceReset.scheduler()
      ServiceReset.timer_persistence()

      PersistenceNoOp.create_schedule(%{
        id: "exhausted-cycle",
        process_version_id: "pv-exhausted",
        process_model_id: "exhausted-model",
        flow_node_id: "Timer_exhausted",
        kind: "cycle",
        iso_spec: "R2/PT1H",
        enabled: false,
        next_fire_at: nil,
        cycle_total: 2,
        cycle_remaining: 0
      })

      {:ok, updated} = StartEventManager.enable_schedule("exhausted-cycle")

      assert updated.enabled == true
      assert updated.next_fire_at == nil
      assert Scheduler.armed_count() == 0
    end
  end

  # -------------------------------------------------------------------------
  # record_fire/1
  # -------------------------------------------------------------------------

  describe "record_fire/1" do
    test "sets last_triggered_at and leaves the cycle state to the scheduler callback" do
      specs = [%{flow_node_id: "Timer_cycle_fire", kind: :cycle, iso_spec: "R3/PT30M"}]

      StartEventManager.register_timer_starts("pv-cycle-fire", "cycle-fire", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()

      assert :ok = StartEventManager.record_fire(schedule.id)

      {:ok, updated} = PersistenceNoOp.get_schedule(schedule.id)
      assert updated.last_triggered_at != nil
      assert updated.cycle_remaining == 3
      assert updated.next_fire_at == schedule.next_fire_at
    end

    test "returns error for nonexistent schedule" do
      assert {:error, :not_found} = StartEventManager.record_fire("nonexistent")
    end
  end

  # -------------------------------------------------------------------------
  # list_schedules / get_schedule
  # -------------------------------------------------------------------------

  describe "list_schedules/1 and get_schedule/1" do
    test "list_schedules returns all registered schedules" do
      specs = [
        %{flow_node_id: "T1", kind: :duration, iso_spec: "PT1H"},
        %{flow_node_id: "T2", kind: :date, iso_spec: far_future_iso()}
      ]

      StartEventManager.register_timer_starts("pv-list", "list-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, schedules} = StartEventManager.list_schedules()
      assert length(schedules) == 2
    end

    test "get_schedule returns a specific schedule" do
      specs = [%{flow_node_id: "T1", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-get", "get-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = StartEventManager.list_schedules()
      {:ok, fetched} = StartEventManager.get_schedule(schedule.id)
      assert fetched.flow_node_id == "T1"
    end

    test "get_schedule returns :not_found for nonexistent ID" do
      assert {:error, :not_found} = StartEventManager.get_schedule("nonexistent")
    end
  end

  # -------------------------------------------------------------------------
  # handle_cycle_advance/3
  # -------------------------------------------------------------------------

  describe "handle_cycle_advance/3" do
    test "updates next_fire_at and cycle_remaining in persistence" do
      PersistenceNoOp.create_schedule(%{
        id: "cycle-adv-1",
        process_version_id: "pv-1",
        kind: "cycle",
        cycle_remaining: 5,
        next_fire_at: ~U[2026-06-01 11:00:00Z]
      })

      metadata = %{schedule_id: "cycle-adv-1"}
      next_fire = ~U[2026-06-01 12:00:00Z]

      assert :ok = StartEventManager.handle_cycle_advance(metadata, next_fire, 4)

      {:ok, updated} = PersistenceNoOp.get_schedule("cycle-adv-1")
      assert updated.next_fire_at == ~U[2026-06-01 12:00:00Z]
      assert updated.cycle_remaining == 4
    end

    test "sets next_fire_at to nil when exhausted" do
      PersistenceNoOp.create_schedule(%{
        id: "cycle-adv-2",
        process_version_id: "pv-1",
        kind: "cycle",
        cycle_remaining: 1,
        next_fire_at: ~U[2026-06-01 11:00:00Z]
      })

      metadata = %{schedule_id: "cycle-adv-2"}

      assert :ok = StartEventManager.handle_cycle_advance(metadata, nil, 0)

      {:ok, updated} = PersistenceNoOp.get_schedule("cycle-adv-2")
      assert updated.next_fire_at == nil
    end

    test "handles infinite cycle (does not set cycle_remaining)" do
      PersistenceNoOp.create_schedule(%{
        id: "cycle-adv-inf",
        process_version_id: "pv-1",
        kind: "cycle",
        cycle_remaining: nil,
        next_fire_at: ~U[2026-06-01 11:00:00Z]
      })

      metadata = %{schedule_id: "cycle-adv-inf"}

      assert :ok =
               StartEventManager.handle_cycle_advance(
                 metadata,
                 ~U[2026-06-01 12:00:00Z],
                 :infinite
               )

      {:ok, updated} = PersistenceNoOp.get_schedule("cycle-adv-inf")
      assert updated.next_fire_at == ~U[2026-06-01 12:00:00Z]
      assert updated.cycle_remaining == nil
    end

    test "is a no-op when metadata has no schedule_id" do
      assert :ok = StartEventManager.handle_cycle_advance(%{}, ~U[2026-06-01 12:00:00Z], 5)
    end
  end

  # -------------------------------------------------------------------------
  # reload_start_schedules/1
  # -------------------------------------------------------------------------

  describe "reload_start_schedules/1" do
    test "loads armed cycle schedules from persistence into the scheduler" do
      PersistenceNoOp.create_schedule(%{
        id: "reload-1",
        process_version_id: "pv-1",
        process_model_id: "process-1",
        flow_node_id: "Timer_1",
        kind: "cycle",
        iso_spec: "R3/PT1H",
        enabled: true,
        next_fire_at: far_future_datetime()
      })

      PersistenceNoOp.create_schedule(%{
        id: "reload-2",
        process_version_id: "pv-2",
        process_model_id: "process-2",
        flow_node_id: "Timer_2",
        kind: "cycle",
        iso_spec: "R/PT30M",
        enabled: true,
        next_fire_at: ~U[2099-12-31 00:00:00Z]
      })

      PersistenceNoOp.create_schedule(%{
        id: "reload-disabled",
        process_version_id: "pv-3",
        kind: "cycle",
        iso_spec: "R5/PT1H",
        enabled: false,
        next_fire_at: nil
      })

      assert :ok = StartEventManager.reload_start_schedules()
      assert Scheduler.armed_count() == 2
    end

    test "skips non-cycle schedules during reload" do
      PersistenceNoOp.create_schedule(%{
        id: "reload-dur",
        process_version_id: "pv-dur",
        process_model_id: "dur-model",
        flow_node_id: "Timer_dur",
        kind: "duration",
        iso_spec: "PT1H",
        enabled: true,
        next_fire_at: far_future_datetime()
      })

      PersistenceNoOp.create_schedule(%{
        id: "reload-date",
        process_version_id: "pv-date",
        process_model_id: "date-model",
        flow_node_id: "Timer_date",
        kind: "date",
        iso_spec: "2026-12-31T00:00:00Z",
        enabled: true,
        next_fire_at: ~U[2099-12-31 00:00:00Z]
      })

      assert :ok = StartEventManager.reload_start_schedules()
      assert Scheduler.armed_count() == 0
    end

    test "loads cycle schedules with cycle info" do
      PersistenceNoOp.create_schedule(%{
        id: "reload-cycle",
        process_version_id: "pv-cycle",
        process_model_id: "cycle-model",
        flow_node_id: "Timer_cycle",
        kind: "cycle",
        iso_spec: "R5/PT30M",
        enabled: true,
        next_fire_at: far_future_datetime(),
        cycle_total: 5,
        cycle_remaining: 3
      })

      assert :ok = StartEventManager.reload_start_schedules()
      assert Scheduler.armed_count() == 1
    end

    test "a finite cycle whose remaining occurrences were missed ends without firing" do
      PersistenceNoOp.create_schedule(%{
        id: "reload-last-repetition",
        process_version_id: "pv-last",
        process_model_id: "last-model",
        flow_node_id: "Timer_last",
        kind: "cycle",
        iso_spec: "R5/PT1H",
        enabled: true,
        next_fire_at: DateTime.add(DateTime.utc_now(), -1, :second),
        cycle_total: 5,
        cycle_remaining: 1
      })

      assert :ok = StartEventManager.reload_start_schedules()

      {:ok, schedule} = PersistenceNoOp.get_schedule("reload-last-repetition")
      assert schedule.next_fire_at == nil
      assert schedule.cycle_remaining == 0
      assert Scheduler.armed_count() == 0
    end

    test "skips occurrences missed while not armed and arms the next future one" do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      missed_since = DateTime.add(now, -5 * 3600 - 60, :second)

      PersistenceNoOp.create_schedule(%{
        id: "reload-missed",
        process_version_id: "pv-missed",
        process_model_id: "missed-model",
        flow_node_id: "Timer_missed",
        kind: "cycle",
        iso_spec: "R10/PT1H",
        enabled: true,
        next_fire_at: missed_since,
        cycle_total: 10,
        cycle_remaining: 8
      })

      assert :ok = StartEventManager.reload_start_schedules()

      {:ok, schedule} = PersistenceNoOp.get_schedule("reload-missed")
      expected_next_fire_at = DateTime.add(missed_since, 6 * 3600, :second)
      assert DateTime.compare(schedule.next_fire_at, expected_next_fire_at) == :eq
      assert schedule.cycle_remaining == 2
      assert Scheduler.armed_count() == 1
    end

    test "reloading twice arms each schedule once" do
      PersistenceNoOp.create_schedule(%{
        id: "reload-twice",
        process_version_id: "pv-twice",
        process_model_id: "twice-model",
        flow_node_id: "Timer_twice",
        kind: "cycle",
        iso_spec: "R/PT1H",
        enabled: true,
        next_fire_at: far_future_datetime()
      })

      assert :ok = StartEventManager.reload_start_schedules()
      assert :ok = StartEventManager.reload_start_schedules()
      assert Scheduler.armed_count() == 1
    end

    test "re-arms persisted schedules after the Scheduler crashed and restarted" do
      unique_id = System.unique_integer([:positive])
      scheduler_name = :"restart_scheduler_#{unique_id}"

      start_supervised!(
        {Scheduler,
         name: scheduler_name,
         tick_interval_ms: 20,
         primary_table: :"restart_primary_#{unique_id}",
         target_index_table: :"restart_target_index_#{unique_id}",
         on_restart: {StartEventManager, :reload_start_schedules, [[scheduler: scheduler_name]]}}
      )

      PersistenceNoOp.create_schedule(%{
        id: "reload-after-crash",
        process_version_id: "pv-crash",
        process_model_id: "crash-model",
        flow_node_id: "Timer_crash",
        kind: "cycle",
        iso_spec: "R/PT1H",
        enabled: true,
        next_fire_at: far_future_datetime()
      })

      assert :ok = StartEventManager.reload_start_schedules(scheduler: scheduler_name)
      assert Scheduler.armed_count(scheduler_name) == 1

      crashed_pid = Process.whereis(scheduler_name)
      Process.exit(crashed_pid, :kill)

      assert :ok =
               wait_until(fn ->
                 restarted_pid = Process.whereis(scheduler_name)

                 is_pid(restarted_pid) and restarted_pid != crashed_pid and
                   Scheduler.armed_count(scheduler_name) == 1
               end)
    end

    test "is a no-op when no armed schedules exist" do
      assert :ok = StartEventManager.reload_start_schedules()
      assert Scheduler.armed_count() == 0
    end
  end

  defp wait_until(condition, attempts_left \\ 100) do
    cond do
      condition.() ->
        :ok

      attempts_left == 0 ->
        :timeout

      true ->
        Process.sleep(20)
        wait_until(condition, attempts_left - 1)
    end
  end
end
