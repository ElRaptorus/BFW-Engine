defmodule BfwEngine.Timers.StartEventManagerTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Timers.Persistence.NoOp, as: PersistenceNoOp
  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Timers.StartEventManager

  setup do
    Scheduler.reset_state()
    PersistenceNoOp.reset_state()
    :ok
  end

  # Wall-clock future so the 50ms test Scheduler tick cannot treat the armed
  # entry as due. A stale `~U[2026-06-01 ...]` is in the past: `R3/PT1H`
  # catch-up fires all remaining cycles in one tick and `armed_count` drops to 0.
  defp future_reference_time do
    DateTime.utc_now()
    |> DateTime.add(30 * 24 * 3600, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp far_future_iso, do: "2099-12-25T08:00:00Z"

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

    test "enable_schedule returns error for nonexistent ID" do
      assert {:error, :not_found} = StartEventManager.enable_schedule("nonexistent")
    end

    test "disable_schedule returns error for nonexistent ID" do
      assert {:error, :not_found} = StartEventManager.disable_schedule("nonexistent")
    end

    test "enable_schedule returns :not_a_cycle for duration schedule" do
      Scheduler.reset_state()
      PersistenceNoOp.reset_state()

      specs = [%{flow_node_id: "Timer_dur", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-dur", "dur-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert {:error, :not_a_cycle} = StartEventManager.enable_schedule(schedule.id)
    end

    test "disable_schedule returns :not_a_cycle for duration schedule" do
      Scheduler.reset_state()
      PersistenceNoOp.reset_state()

      specs = [%{flow_node_id: "Timer_dur", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-dur", "dur-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert {:error, :not_a_cycle} = StartEventManager.disable_schedule(schedule.id)
    end

    test "disable_schedule does not cancel other schedules' timers" do
      Scheduler.reset_state()
      PersistenceNoOp.reset_state()

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
      Scheduler.reset_state()
      PersistenceNoOp.reset_state()

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
  end

  # -------------------------------------------------------------------------
  # record_fire/1
  # -------------------------------------------------------------------------

  describe "record_fire/1" do
    test "updates last_triggered_at and clears next_fire_at for one-shot" do
      specs = [%{flow_node_id: "Timer_oneshot", kind: :duration, iso_spec: "PT1H"}]

      StartEventManager.register_timer_starts("pv-fire", "fire-process", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()

      assert :ok = StartEventManager.record_fire(schedule.id)

      {:ok, updated} = PersistenceNoOp.get_schedule(schedule.id)
      assert updated.last_triggered_at != nil
      assert updated.next_fire_at == nil
    end

    test "decrements cycle_remaining for cycle schedules" do
      specs = [%{flow_node_id: "Timer_cycle_fire", kind: :cycle, iso_spec: "R3/PT30M"}]

      StartEventManager.register_timer_starts("pv-cycle-fire", "cycle-fire", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert schedule.cycle_remaining == 3

      StartEventManager.record_fire(schedule.id)

      {:ok, updated} = PersistenceNoOp.get_schedule(schedule.id)
      assert updated.cycle_remaining == 2
      assert updated.last_triggered_at != nil
    end

    test "exhausts cycle when remaining reaches 0" do
      specs = [%{flow_node_id: "Timer_exhaust", kind: :cycle, iso_spec: "R1/PT30M"}]

      StartEventManager.register_timer_starts("pv-exhaust", "exhaust", specs,
        reference_time: future_reference_time()
      )

      {:ok, [schedule]} = PersistenceNoOp.list_all_schedules()
      assert schedule.cycle_remaining == 1

      StartEventManager.record_fire(schedule.id)

      {:ok, updated} = PersistenceNoOp.get_schedule(schedule.id)
      assert updated.cycle_remaining == 0
      assert updated.next_fire_at == nil
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

    test "is a no-op when no armed schedules exist" do
      assert :ok = StartEventManager.reload_start_schedules()
      assert Scheduler.armed_count() == 0
    end
  end
end
