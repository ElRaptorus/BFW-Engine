defmodule EvilEngine.Execution.TimerBoundaryIntegrationTest do
  @moduledoc """
  Integration tests for the Timer Boundary Event lifecycle at the PI level:

  1. PI dispatches a host activity FNI and its attached subscription-model
     boundary FNIs simultaneously.
  2. TimerBoundaryEvent handler schedules a timer via `Scheduler`, blocks
     on `receive {:timer_fired, ...}`, and returns
     `{:boundary, node_id, payload, cancel_activity}`.
  3. PI processes the boundary result:
     - Interrupting: host FNI interrupted, siblings cancelled, boundary
       outgoing targets dispatched.
     - Non-interrupting: host continues, boundary outgoing targets
       dispatched in parallel.
  4. Host completion cleans up any remaining boundary FNIs.

  These tests use in-memory BPMN models (BpmnFactory) and NoOp persistence.
  """

  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Identity

  @test_identity %Identity{id: "test-user", roles: ["admin"], groups: ["all"]}

  setup do
    Scheduler.reset_state()
    :ok
  end

  defp start_pi_with_boundary(boundary_opts, payload \\ %{}) do
    definitions = BpmnFactory.user_task_with_timer_boundary(boundary_opts)
    start_pi(definitions, payload)
  end

  defp start_pi_with_auto_host_boundary(boundary_opts, payload \\ %{}) do
    definitions = BpmnFactory.task_with_timer_boundary(boundary_opts)
    start_pi(definitions, payload)
  end

  defp start_pi(definitions, payload) do
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

  describe "interrupting timer boundary — PT0S (immediate fire)" do
    test "boundary fires immediately, host is interrupted, PI completes via timeout path" do
      %{pid: pid} =
        start_pi_with_boundary(time_duration: "PT0S", cancel_activity: true)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "interrupting timer boundary — future duration" do
    test "PI stays alive while timer is pending, user task is waiting" do
      %{pid: pid} =
        start_pi_with_boundary(time_duration: "PT1H", cancel_activity: true)

      Process.sleep(300)
      assert Process.alive?(pid)
      assert Scheduler.armed_count() >= 1

      ProcessInstance.abort(pid, "test cleanup", @test_identity)
    end
  end

  describe "non-interrupting timer boundary — PT0S (immediate fire)" do
    test "boundary fires, host user task continues, PI waits for user task" do
      %{pid: pid} =
        start_pi_with_boundary(time_duration: "PT0S", cancel_activity: false)

      Process.sleep(500)
      assert Process.alive?(pid)

      ProcessInstance.abort(pid, "test cleanup", @test_identity)
    end
  end

  describe "host completion cleans up boundary FNIs" do
    test "when host activity finishes normally, boundary timer is cancelled and PI completes" do
      armed_before = Scheduler.armed_count()

      %{pid: pid} =
        start_pi_with_auto_host_boundary(time_duration: "PT1H", cancel_activity: true)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      Process.sleep(200)
      armed_after = Scheduler.armed_count()
      assert armed_after == armed_before
    end
  end

  describe "error cases" do
    test "missing timer spec causes boundary FNI to fatal, PI goes fatal" do
      %{pid: pid} = start_pi_with_boundary(cancel_activity: true)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :noproc]
    end

    test "time_cycle on non-interrupting boundary keeps PI alive" do
      %{pid: pid} = start_pi_with_boundary(time_cycle: "R3/PT1H", cancel_activity: false)

      Process.sleep(300)
      assert Process.alive?(pid)
      assert Scheduler.armed_count() >= 1

      ProcessInstance.abort(pid, "test cleanup", @test_identity)
    end

    test "time_cycle on interrupting boundary fires once and completes PI" do
      %{pid: pid} =
        start_pi_with_boundary(time_cycle: "R3/PT0S", cancel_activity: true)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "non-interrupting cycle boundary — PT0S (immediate multi-fire)" do
    test "cycle fires multiple times while host continues, PI waits for user task" do
      %{pid: pid} =
        start_pi_with_boundary(time_cycle: "R3/PT0S", cancel_activity: false)

      Process.sleep(500)
      assert Process.alive?(pid)

      ProcessInstance.abort(pid, "test cleanup", @test_identity)
    end
  end

  describe "cancel on host fatal — boundary timer cleaned up" do
    test "host service task fatals (unknown impl), timer boundary FNI is aborted, PI goes fatal" do
      definitions =
        BpmnFactory.service_task_fatal_with_timer_boundary(
          time_duration: "PT1H",
          cancel_activity: true
        )

      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)
      process_instance_id = "pi-#{System.unique_integer([:positive])}"

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        payload: %{},
        identity: @test_identity
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :noproc]

      Process.sleep(200)
      assert Scheduler.armed_count() == 0
    end
  end

  describe "multiple interrupting boundaries — first wins, second stale" do
    test "two interrupting timer boundaries fire simultaneously, PI completes via one path" do
      definitions = BpmnFactory.user_task_with_dual_timer_boundaries(time_duration: "PT0S")

      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)
      process_instance_id = "pi-#{System.unique_integer([:positive])}"

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        payload: %{},
        identity: @test_identity
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "mixed interrupting + non-interrupting boundaries" do
    test "both boundaries fire, PI completes normally" do
      definitions =
        BpmnFactory.user_task_with_mixed_timer_boundaries(
          non_interrupting_duration: "PT0S",
          interrupting_duration: "PT0S"
        )

      version_id = "version-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)
      process_instance_id = "pi-#{System.unique_integer([:positive])}"

      opts = %{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        payload: %{},
        identity: @test_identity
      }

      {:ok, pid} =
        DynamicSupervisor.start_child(EvilEngine.Execution.Supervisor, {ProcessInstance, opts})

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "resume — timer boundary re-arm" do
    test "resume with active host and future timer boundary re-schedules timer" do
      definitions =
        BpmnFactory.user_task_with_timer_boundary(
          time_duration: "PT2H",
          cancel_activity: true
        )

      version_id = "version-resume-be-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)
      process_instance_id = "pi-resume-be-#{System.unique_integer([:positive])}"

      future_iso =
        DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.to_iso8601()

      fni_data = [
        %{
          id: "fni-user-task-1",
          flow_node_id: "UserTask_1",
          flow_node_type: "user_task",
          state: "waiting",
          input_token: %{"data" => "task-payload"},
          started_at: DateTime.utc_now(),
          previous_flow_node_instance_ids: [],
          type_properties: %{}
        },
        %{
          id: "fni-timer-be-1",
          flow_node_id: "TimerBE_1",
          flow_node_type: "boundary_event",
          event_type: "timer",
          state: "waiting",
          input_token: %{},
          started_at: DateTime.utc_now(),
          previous_flow_node_instance_ids: [],
          type_properties: %{
            "timer_ref" => "old-ref-expired",
            "fire_at" => future_iso,
            "cancel_activity" => true,
            "host_flow_node_instance_id" => "fni-user-task-1"
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

      Process.sleep(300)
      assert Process.alive?(pid)
      assert Scheduler.armed_count() >= 1

      ProcessInstance.abort(pid, "test cleanup", @test_identity)
    end

    test "resume with past timer boundary fire_at fires immediately, host interrupted" do
      definitions =
        BpmnFactory.user_task_with_timer_boundary(
          time_duration: "PT1M",
          cancel_activity: true
        )

      version_id = "version-resume-be-past-#{System.unique_integer([:positive])}"
      ModelCache.put_new(version_id, definitions)
      process_instance_id = "pi-resume-be-past-#{System.unique_integer([:positive])}"

      past_iso =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      fni_data = [
        %{
          id: "fni-user-task-1",
          flow_node_id: "UserTask_1",
          flow_node_type: "user_task",
          state: "waiting",
          input_token: %{"data" => "task-payload"},
          started_at: DateTime.utc_now(),
          previous_flow_node_instance_ids: [],
          type_properties: %{}
        },
        %{
          id: "fni-timer-be-1",
          flow_node_id: "TimerBE_1",
          flow_node_type: "boundary_event",
          event_type: "timer",
          state: "waiting",
          input_token: %{},
          started_at: DateTime.utc_now(),
          previous_flow_node_instance_ids: [],
          type_properties: %{
            "timer_ref" => "old-ref-expired",
            "fire_at" => past_iso,
            "cancel_activity" => true,
            "host_flow_node_instance_id" => "fni-user-task-1"
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

  describe "abort during boundary wait" do
    test "aborting PI while timer boundary is waiting cancels the timer" do
      %{pid: pid} =
        start_pi_with_boundary(time_duration: "PT1H", cancel_activity: true)

      Process.sleep(300)
      assert Process.alive?(pid)
      armed_before = Scheduler.armed_count()
      assert armed_before >= 1

      ref = Process.monitor(pid)
      ProcessInstance.abort(pid, "user-abort", @test_identity)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      Process.sleep(200)
      armed_after = Scheduler.armed_count()
      assert armed_after < armed_before
    end
  end
end
