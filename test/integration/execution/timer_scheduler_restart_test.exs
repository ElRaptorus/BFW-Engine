defmodule BfwEngine.Integration.Execution.TimerSchedulerRestartTest do
  @moduledoc "A timer that waits while the Scheduler crashes still fires once the Scheduler is back."
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Timers.Scheduler

  describe "Scheduler restart" do
    test "a waiting catch timer fires after the Scheduler was killed" do
      process_instance_id =
        http_deploy_and_start("timer_catch_feel_expression.bpmn", "TimerCatchFeelExpression", %{
          "payload" => %{"seconds" => 2}
        })

      _ = poll_fni_state(process_instance_id, "intermediate_catch_event", "waiting")
      kill_scheduler()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished", timeout: 10_000)
    end

    test "an armed Event Subprocess timer start fires after the Scheduler was killed" do
      process_instance_id =
        http_deploy_and_start(
          "event_subprocess_timer_interrupting.bpmn",
          "EventSubprocessTimerInterrupting"
        )

      _ = poll_fni_state(process_instance_id, "user_task", "waiting")
      kill_scheduler()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished", timeout: 10_000)
    end
  end

  defp kill_scheduler do
    scheduler_pid = Process.whereis(Scheduler)
    monitor_reference = Process.monitor(scheduler_pid)
    Process.exit(scheduler_pid, :kill)
    assert_receive {:DOWN, ^monitor_reference, :process, ^scheduler_pid, :killed}, 2_000
  end
end
