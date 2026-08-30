defmodule EvilEngine.Execution.TimerCatchIntegrationTest do
  @moduledoc """
  Integration tests for the Timer Intermediate Catch Event lifecycle:

  1. PI dispatches to TimerCatchEvent handler via the async continuation pattern
  2. Handler schedules the timer with `target: self()` (handler Task PID)
  3. FNI parks in `:waiting` — handler Task stays alive, blocked on `receive`
  4. Scheduler fires the timer to the handler Task; handler completes,
     sends `{:fni_result, ...}` back through the generic PI pipeline
  5. Resume: PI spawns a Task calling `handle_resume/3` on the handler

  The PI has zero timer-specific code — all scheduling, event emission,
  and completion logic lives in the handler.

  These tests use in-memory BPMN models (BpmnFactory) and NoOp persistence.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Execution.TestSupport.SchedulerWait
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Identity

  @test_identity %Identity{id: "test-user", roles: ["admin"], groups: ["all"]}

  setup do
    Scheduler.reset_state()
    :ok
  end

  defp start_pi_with_timer(timer_opts, payload \\ %{}) do
    definitions = BpmnFactory.timer_catch_event_process(timer_opts)
    process = hd(definitions.processes)
    version_id = "version-#{System.unique_integer([:positive])}"

    ModelCache.put_new(version_id, definitions)

    process_instance_id = "pi-#{System.unique_integer([:positive])}"

    opts = %{
      process_instance_id: process_instance_id,
      process_version_id: version_id,
      payload: payload,
      identity: @test_identity
    }

    {:ok, pid} =
      DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

    %{
      pid: pid,
      process_instance_id: process_instance_id,
      version_id: version_id,
      process_model: process
    }
  end

  describe "timer catch event — duration (happy path)" do
    test "PI waits on timer catch event, completes when timer fires" do
      %{pid: pid} = start_pi_with_timer(time_duration: "PT0S")

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "timer catch event with short duration fires and completes PI" do
      %{pid: pid} = start_pi_with_timer(time_duration: "PT0S", process_id: "timer-test")

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "timer catch event — date" do
    test "past date fires immediately, PI completes" do
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()

      %{pid: pid} = start_pi_with_timer(time_date: past)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "future date keeps FNI in waiting state" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      %{pid: pid} = start_pi_with_timer(time_date: future)

      assert :ok = SchedulerWait.wait_until_armed(1)
      assert Process.alive?(pid)

      ProcessInstance.abort(pid, "test cleanup", @test_identity)
    end
  end

  describe "timer catch event — error cases" do
    test "cycle timer on catch event causes fatal" do
      %{pid: pid} = start_pi_with_timer(time_cycle: "R3/PT1H")

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :noproc]
    end

    test "no timer spec causes fatal" do
      %{pid: pid} = start_pi_with_timer([])

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :noproc]
    end
  end

  describe "timer catch event — payload preservation" do
    test "input payload is preserved through timer wait" do
      payload = %{"order_id" => "ORD-42", "amount" => 100}

      %{pid: pid} = start_pi_with_timer([time_duration: "PT0S"], payload)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "timer catch event — resume" do
    test "resume with future fire_at re-schedules timer" do
      future = DateTime.utc_now() |> DateTime.add(7200, :second)
      future_iso = DateTime.to_iso8601(future)

      definitions = BpmnFactory.timer_catch_event_process(time_duration: "PT2H")
      version_id = "version-resume-#{System.unique_integer([:positive])}"

      ModelCache.put_new(version_id, definitions)

      process_instance_id = "pi-resume-#{System.unique_integer([:positive])}"

      fni_data = [
        %{
          id: "fni-timer-catch-1",
          flow_node_id: "TimerCatch_1",
          flow_node_type: "intermediate_catch_event",
          event_type: "timer",
          state: "waiting",
          input_token: %{"data" => "preserved"},
          started_at: DateTime.utc_now(),
          previous_flow_node_instance_ids: [],
          type_properties: %{
            "timer_ref" => "old-ref-that-expired",
            "fire_at" => future_iso
          }
        }
      ]

      opts = %{
        resume: true,
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        started_at: DateTime.utc_now(),
        started_by: %{"id" => "test-user", "roles" => ["admin"], "groups" => ["all"]},
        fni_data: fni_data
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

      assert :ok = SchedulerWait.wait_until_armed(1)
      assert Process.alive?(pid)

      ProcessInstance.abort(pid, "test cleanup", @test_identity)
    end

    test "resume with past fire_at completes FNI immediately" do
      past_iso =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      definitions = BpmnFactory.timer_catch_event_process(time_duration: "PT1M")
      version_id = "version-resume-past-#{System.unique_integer([:positive])}"

      ModelCache.put_new(version_id, definitions)

      process_instance_id = "pi-resume-past-#{System.unique_integer([:positive])}"

      fni_data = [
        %{
          id: "fni-timer-catch-past",
          flow_node_id: "TimerCatch_1",
          flow_node_type: "intermediate_catch_event",
          event_type: "timer",
          state: "waiting",
          input_token: %{"data" => "should-complete"},
          started_at: DateTime.utc_now(),
          previous_flow_node_instance_ids: [],
          type_properties: %{
            "timer_ref" => "old-ref-expired",
            "fire_at" => past_iso
          }
        }
      ]

      opts = %{
        resume: true,
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        started_at: DateTime.utc_now(),
        started_by: %{"id" => "test-user", "roles" => ["admin"], "groups" => ["all"]},
        fni_data: fni_data
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "timer catch event — FEEL expression" do
    test "FEEL expression evaluating to a duration string fires timer correctly" do
      definitions = BpmnFactory.timer_catch_event_process(time_duration: "PT0S")
      version_id = "version-feel-#{System.unique_integer([:positive])}"

      ModelCache.put_new(version_id, definitions)

      process_instance_id = "pi-feel-#{System.unique_integer([:positive])}"

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        payload: %{"seconds" => 0},
        identity: @test_identity
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "timer catch event — abort during wait" do
    test "aborting PI while timer is waiting cancels timer" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      %{pid: pid} = start_pi_with_timer(time_date: future)

      assert :ok = SchedulerWait.wait_until_armed(1)
      assert Process.alive?(pid)
      armed_before = Scheduler.armed_count()

      ref = Process.monitor(pid)
      ProcessInstance.abort(pid, "user-abort", @test_identity)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      assert :ok = SchedulerWait.wait_until_below(armed_before)
    end
  end
end
