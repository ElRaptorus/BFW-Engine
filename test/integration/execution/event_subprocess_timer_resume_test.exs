defmodule BfwEngine.Integration.Execution.EventSubprocessTimerResumeTest do
  @moduledoc "Regression: an Event Subprocess timer start keeps its original deadline across a resume (A8)."
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner

  @timer_duration_ms 6_000
  @elapsed_before_restart_ms 4_000
  @latest_fire_after_resume_ms 4_000

  describe "A8: timer Event Subprocess across a restart" do
    test "interrupting timer ESP fires at its original deadline, not a fresh full duration" do
      process_instance_id =
        http_deploy_and_start(
          "event_subprocess_timer_interrupting_resume.bpmn",
          "EventSubprocessTimerInterruptingResume"
        )

      _ = poll_fni_state(process_instance_id, "user_task", "waiting")

      # The assertion is about elapsed wall-clock time across the restart.
      Process.sleep(@elapsed_before_restart_ms)

      stop_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "running")

      resumed_at = System.monotonic_time(:millisecond)
      {:ok, 1} = ResumeRunner.resume_all()

      assert {:ok, _process_instance} =
               await_process_instance_state(process_instance_id, "finished",
                 timeout: @timer_duration_ms * 2
               )

      fired_after_resume_ms = System.monotonic_time(:millisecond) - resumed_at

      assert fired_after_resume_ms < @latest_fire_after_resume_ms,
             "ESP timer fired #{fired_after_resume_ms} ms after resume; " <>
               "the remaining time was about #{@timer_duration_ms - @elapsed_before_restart_ms} ms"
    end
  end

  defp stop_process_instance(process_instance_id) do
    {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)
    monitor_reference = Process.monitor(process_instance_pid)
    DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, process_instance_pid)
    assert_receive {:DOWN, ^monitor_reference, :process, ^process_instance_pid, _reason}, 2_000
  end
end
