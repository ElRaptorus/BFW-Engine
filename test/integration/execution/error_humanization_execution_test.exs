defmodule BfwEngine.Integration.Execution.ErrorHumanizationExecutionTest do
  @moduledoc """
  Integration tests for humanized runtime error messages on flow node instances.

  Verifies that fatal FNIs persist `error_info` with diagnostic sentences
  instead of raw `inspect/1` output.
  """
  use BfwEngine.ExecutionCase, async: false

  describe "service task with no registered handler" do
    test "fatal FNI error_info names the missing implementation value" do
      {201, _} = http_deploy("service_task_unknown_type.bpmn")

      {201, body} = http_start("ServiceTaskUnknownType")
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      service_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "ServiceTask_Unknown"))

      assert service_fni.state == "fatal"
      assert is_map(service_fni.error_info)

      assert service_fni.error_info["error_code"] == "no_handler_for_implementation"

      message = service_fni.error_info["message"]
      assert is_binary(message)
      assert message =~ "nonexistent_handler"
      assert message =~ "No handler registered"
      refute message =~ "%{"
      refute message =~ "inspect"
    end
  end
end
