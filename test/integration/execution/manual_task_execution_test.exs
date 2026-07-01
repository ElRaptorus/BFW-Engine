defmodule EvilEngine.Integration.Execution.ManualTaskExecutionTest do
  @moduledoc "Integration tests for Manual Task execution with requireConfirmation."
  use EvilEngine.ExecutionCase, async: false

  describe "manual task with requireConfirmation" do
    test "PI pauses at manual task, finish call completes it" do
      {201, _} = http_deploy("manual_task_confirm.bpmn")

      {201, body} =
        http_start("ManualTaskConfirm", %{"payload" => %{"step" => "pack"}})

      process_instance_id = body["processInstanceId"]

      Process.sleep(200)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      manual_fni = Enum.find(flow_node_instances, &(&1.flow_node_type == "manual_task"))
      assert manual_fni != nil
      assert manual_fni.state == "waiting"

      {204, _} = http_finish_user_task(manual_fni.id, %{"confirmed" => true})

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")

      finished_manual = Enum.find(flow_node_instances, &(&1.flow_node_type == "manual_task"))
      assert finished_manual.state == "finished"
      assert finished_manual.finished_at != nil
    end
  end
end
