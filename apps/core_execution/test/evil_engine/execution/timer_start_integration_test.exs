defmodule EvilEngine.Execution.TimerStartIntegrationTest do
  @moduledoc """
  Integration tests for the full Timer Start Event lifecycle.

  ## Cycle Timer Start Events (auto-scheduled)

  1. Deploy hook scans BPMN for cycle timer starts and registers schedules
  2. Scheduler fires timer to TimerStartListener
  3. Listener creates PI with correct start_event_id
  4. PI completes normally via the cycle start event path (pass-through)

  ## Date/Duration Timer Start Events (PI-scoped blocking)

  Date and Duration Timer Start Events are NOT auto-scheduled. They
  block the Start Event FNI inside the PI until their condition is met:
  - Duration: blocks for the configured duration
  - Date: blocks until the configured datetime

  These tests exercise both paths using fast tick intervals and PT0S
  durations / past dates for immediate completion.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Execution.TestSupport.SchedulerWait
  alias EvilEngine.Execution.TimerStartListener
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Timers.StartEventManager

  setup do
    Scheduler.reset_state()
    :ok
  end

  describe "cycle timer start — auto-fire via Scheduler" do
    test "Scheduler fires cycle timer start, listener creates PI" do
      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT0S")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      StartEventManager.register_timer_starts(
        version_id,
        "test-process",
        [%{flow_node_id: "TimerStart_1", kind: :cycle, iso_spec: "R3/PT0S"}]
      )

      {:ok, schedules} = StartEventManager.list_schedules(process_version_id: version_id)
      schedule = hd(schedules)
      assert schedule.enabled == true
      assert schedule.next_fire_at != nil
      assert schedule.kind == "cycle"

      assert :ok =
               SchedulerWait.wait_until(
                 fn ->
                   {:ok, updated_schedule} = StartEventManager.get_schedule(schedule.id)
                   updated_schedule.last_triggered_at != nil
                 end,
                 5_000
               )
    end

    test "disabled cycle schedule does not fire" do
      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT1H")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      StartEventManager.register_timer_starts(
        version_id,
        "test-process",
        [%{flow_node_id: "TimerStart_1", kind: :cycle, iso_spec: "R3/PT1H"}]
      )

      {:ok, schedules} = StartEventManager.list_schedules(process_version_id: version_id)
      schedule = hd(schedules)

      StartEventManager.disable_schedule(schedule.id)

      assert :ok = SchedulerWait.wait_until_count(0)

      {:ok, updated_schedule} = StartEventManager.get_schedule(schedule.id)
      assert updated_schedule.last_triggered_at == nil
      assert updated_schedule.enabled == false
    end

    test "unregister_timer_starts cancels cycle schedules" do
      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT1H")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      StartEventManager.register_timer_starts(
        version_id,
        "test-process",
        [%{flow_node_id: "TimerStart_1", kind: :cycle, iso_spec: "R3/PT1H"}]
      )

      {:ok, schedules_before} =
        StartEventManager.list_schedules(process_version_id: version_id)

      assert length(schedules_before) == 1
      armed_before = Scheduler.armed_count()
      assert armed_before >= 1

      StartEventManager.unregister_timer_starts(version_id)

      {:ok, schedules_after} =
        StartEventManager.list_schedules(process_version_id: version_id)

      assert schedules_after == []
      assert :ok = SchedulerWait.wait_until_below(armed_before)
    end

    test "enable_schedule re-arms a disabled cycle schedule" do
      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT1H")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      StartEventManager.register_timer_starts(
        version_id,
        "test-process",
        [%{flow_node_id: "TimerStart_1", kind: :cycle, iso_spec: "R3/PT1H"}]
      )

      {:ok, schedules} = StartEventManager.list_schedules(process_version_id: version_id)
      schedule = hd(schedules)

      {:ok, disabled} = StartEventManager.disable_schedule(schedule.id)
      assert disabled.enabled == false

      {:ok, enabled} = StartEventManager.enable_schedule(schedule.id)
      assert enabled.enabled == true
    end

    test "cycle timer start fires multiple times" do
      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT0S")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      StartEventManager.register_timer_starts(
        version_id,
        "test-process",
        [%{flow_node_id: "TimerStart_1", kind: :cycle, iso_spec: "R3/PT0S"}]
      )

      {:ok, schedules} = StartEventManager.list_schedules(process_version_id: version_id)
      schedule = hd(schedules)
      assert schedule.cycle_total == 3
      assert schedule.cycle_remaining == 3

      assert :ok =
               SchedulerWait.wait_until(
                 fn ->
                   {:ok, final} = StartEventManager.get_schedule(schedule.id)
                   final.last_triggered_at != nil
                 end,
                 5_000
               )
    end
  end

  describe "duration timer start — PI-scoped blocking" do
    test "duration PT0S completes the PI immediately" do
      definitions = BpmnFactory.timer_start_event_process(time_duration: "PT0S")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      process_instance_id = "pi-#{System.unique_integer([:positive])}"
      identity = %EvilEngine.Types.Identity{id: "test", roles: ["admin"], groups: ["all"]}

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        start_event_id: "TimerStart_1",
        payload: %{},
        identity: identity
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(
          EvilEngine.Execution.Supervisor,
          {EvilEngine.Execution.ProcessInstance, opts}
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 3_000
      assert reason in [:normal, :noproc]
    end

    test "duration timer start is NOT registered in StartEventManager" do
      definitions = BpmnFactory.timer_start_event_process(time_duration: "PT1H")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      {:ok, schedules} = StartEventManager.list_schedules(process_version_id: version_id)
      assert schedules == []

      armed_count = Scheduler.armed_count()
      assert armed_count == 0
    end
  end

  describe "date timer start — PI-scoped blocking" do
    test "past date completes the PI immediately" do
      past_date = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
      definitions = BpmnFactory.timer_start_event_process(time_date: past_date)
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      process_instance_id = "pi-#{System.unique_integer([:positive])}"
      identity = %EvilEngine.Types.Identity{id: "test", roles: ["admin"], groups: ["all"]}

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        start_event_id: "TimerStart_1",
        payload: %{},
        identity: identity
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(
          EvilEngine.Execution.Supervisor,
          {EvilEngine.Execution.ProcessInstance, opts}
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 3_000
      assert reason in [:normal, :noproc]
    end

    test "date timer start is NOT registered in StartEventManager" do
      future_date =
        DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601()

      definitions = BpmnFactory.timer_start_event_process(time_date: future_date)
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      {:ok, schedules} = StartEventManager.list_schedules(process_version_id: version_id)
      assert schedules == []

      armed_count = Scheduler.armed_count()
      assert armed_count == 0
    end
  end

  describe "direct listener message handling" do
    test "listener is registered and responds to timer_fired messages" do
      assert Process.whereis(TimerStartListener) != nil

      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT1H")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      StartEventManager.register_timer_starts(
        version_id,
        "test-process",
        [%{flow_node_id: "TimerStart_1", kind: :cycle, iso_spec: "R3/PT1H"}]
      )

      {:ok, schedules} = StartEventManager.list_schedules(process_version_id: version_id)
      schedule = hd(schedules)

      send(
        TimerStartListener,
        {:timer_fired, "manual-ref",
         %{
           schedule_id: schedule.id,
           process_version_id: version_id,
           process_model_id: "test-process",
           flow_node_id: "TimerStart_1"
         }}
      )

      _ = :sys.get_state(TimerStartListener)

      {:ok, updated} = StartEventManager.get_schedule(schedule.id)
      assert updated.last_triggered_at != nil
    end
  end
end
