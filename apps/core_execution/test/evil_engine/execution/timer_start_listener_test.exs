defmodule EvilEngine.Execution.TimerStartListenerTest do
  @moduledoc """
  Unit tests for the TimerStartListener GenServer.

  Tests the fire handling logic: schedule verification, version verification,
  PI creation, and event emission. These tests use cycle timers since only
  cycle timer starts are auto-scheduled by the StartEventManager.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Execution.TimerStartListener
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Timers.StartEventManager

  setup do
    Scheduler.reset_state()
    :ok
  end

  describe "handle_info {:timer_fired, ...}" do
    test "creates PI when schedule is enabled and version is cached" do
      {version_id, schedule_id} = setup_cycle_schedule()

      send(
        TimerStartListener,
        {:timer_fired, "ref-1",
         %{
           schedule_id: schedule_id,
           process_version_id: version_id,
           process_model_id: "test-process",
           flow_node_id: "TimerStart_1"
         }}
      )

      _ = :sys.get_state(TimerStartListener)

      {:ok, schedule} = StartEventManager.get_schedule(schedule_id)
      assert schedule.last_triggered_at != nil
    end

    test "skips fire when schedule is disabled" do
      {version_id, schedule_id} = setup_cycle_schedule()
      StartEventManager.disable_schedule(schedule_id)

      send(
        TimerStartListener,
        {:timer_fired, "ref-disabled",
         %{
           schedule_id: schedule_id,
           process_version_id: version_id,
           process_model_id: "test-process",
           flow_node_id: "TimerStart_1"
         }}
      )

      _ = :sys.get_state(TimerStartListener)

      {:ok, schedule} = StartEventManager.get_schedule(schedule_id)
      assert schedule.last_triggered_at == nil
    end

    test "skips fire when version is not cached" do
      {_version_id, schedule_id} = setup_cycle_schedule()

      send(
        TimerStartListener,
        {:timer_fired, "ref-bad-version",
         %{
           schedule_id: schedule_id,
           process_version_id: "nonexistent-version",
           process_model_id: "test-process",
           flow_node_id: "TimerStart_1"
         }}
      )

      _ = :sys.get_state(TimerStartListener)

      {:ok, schedule} = StartEventManager.get_schedule(schedule_id)
      assert schedule.last_triggered_at == nil
    end

    test "skips fire when schedule not found" do
      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT1H")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      send(
        TimerStartListener,
        {:timer_fired, "ref-no-schedule",
         %{
           schedule_id: "nonexistent-schedule",
           process_version_id: version_id,
           process_model_id: "test-process",
           flow_node_id: "TimerStart_1"
         }}
      )

      _ = :sys.get_state(TimerStartListener)
    end

    test "ignores unknown messages gracefully" do
      send(TimerStartListener, :some_random_message)
      _ = :sys.get_state(TimerStartListener)
      assert Process.alive?(Process.whereis(TimerStartListener))
    end
  end

  describe "timer start event resolve_start_event" do
    test "PI can start with a Timer Start Event when start_event_id is provided" do
      definitions = BpmnFactory.timer_start_event_process(time_cycle: "R3/PT1H")
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

      assert is_pid(pid)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
      assert reason in [:normal, :noproc]
    end

    test "PI fails without start_event_id when only timer starts exist" do
      definitions = BpmnFactory.timer_start_event_process(time_duration: "PT1H")
      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)

      process_instance_id = "pi-#{System.unique_integer([:positive])}"
      identity = %EvilEngine.Types.Identity{id: "test", roles: ["admin"], groups: ["all"]}

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        payload: %{},
        identity: identity
      }

      result =
        DynamicSupervisor.start_child(
          EvilEngine.Execution.Supervisor,
          {EvilEngine.Execution.ProcessInstance, opts}
        )

      assert {:error, _reason} = result
    end

    test "Duration Timer Start Event blocks until duration elapses" do
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

      assert is_pid(pid)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
      assert reason in [:normal, :noproc]
    end

    test "Date Timer Start Event with past date completes immediately" do
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

      assert is_pid(pid)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
      assert reason in [:normal, :noproc]
    end
  end

  defp setup_cycle_schedule do
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

    {version_id, schedule.id}
  end
end
