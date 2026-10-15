defmodule BfwEngine.Integration.Execution.ProcessInstanceStrayMessageTest do
  @moduledoc "Regression: an unexpected message in a running process instance's mailbox is ignored (E8)."
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution

  describe "E8: stray info message" do
    test "a late reply-shaped message does not crash the process instance" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      {:ok, process_instance_pid} = Execution.lookup_process_instance(process_instance_id)

      send(process_instance_pid, {make_ref(), {:ok, :late_reply}})
      await_mailbox_processed(process_instance_pid)

      assert Process.alive?(process_instance_pid)

      {204, _} = http_finish_user_task(user_task.id, %{"approved" => true})
      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  defp await_mailbox_processed(process_instance_pid) do
    _ = :sys.get_state(process_instance_pid)
  catch
    :exit, _reason -> :process_exited
  end
end
