defmodule BfwEngine.Integration.Execution.EventSubprocessScopeCatchTest do
  @moduledoc """
  An escalation thrown inside an embedded subprocess and not caught by a
  boundary reaches the parent scope's escalation Event Subprocess (C4). A
  message Event Subprocess whose correlation key fails turns the scope fatal
  with a diagnostic (C5), and so does a timer Event Subprocess whose spec
  cannot be resolved (D-10.7).
  """
  use BfwEngine.ExecutionCase, async: false

  describe "C4: escalation intermediate throw passthrough" do
    test "the parent scope's escalation Event Subprocess catches it and the child continues" do
      process_instance_id =
        http_deploy_and_start(
          "escalation_intermediate_throw_sp_parent_esp.bpmn",
          "EscalationITSPParentEsp"
        )

      assert {:ok, %{state: "finished"}} =
               await_finished_fni_by_node_id(process_instance_id, "ESP_Escalation")

      subprocess_shell = find_fni_by_flow_node_id(process_instance_id, "SubProcess_1")
      assert subprocess_shell.state == "waiting"

      child_process_instance_id = subprocess_shell.type_properties["child_process_instance_id"]
      assert %{state: "waiting"} = find_fni_by_flow_node_id(child_process_instance_id, "Sub_Park")
      assert_pi_state!(process_instance_id, "running")
    end
  end

  describe "C5: Event Subprocess correlation key failure" do
    test "the scope goes fatal with a diagnostic naming the Event Subprocess and expression" do
      {201, start_body} =
        http_deploy_and_start_raw(
          "event_subprocess_message_correlation_error.bpmn",
          "EventSubprocessMessageCorrelationError"
        )

      process_instance = poll_pi_state(start_body["processInstanceId"], "fatal")

      assert process_instance.error_info["error_code"] == "event_subprocess_correlation_failed"
      assert process_instance.error_info["message"] =~ "Event Subprocess 'ESP_Message'"
      assert process_instance.error_info["message"] =~ "for x in [1] return if x then"
    end
  end

  describe "D-10.7: Event Subprocess timer start whose spec cannot be resolved" do
    test "the scope goes fatal with a diagnostic naming the Event Subprocess and timer" do
      {201, start_body} =
        http_deploy_and_start_raw(
          "event_subprocess_timer_resolution_error.bpmn",
          "EventSubprocessTimerResolutionError"
        )

      process_instance = poll_pi_state(start_body["processInstanceId"], "fatal")

      assert process_instance.error_info["error_code"] ==
               "event_subprocess_timer_resolution_failed"

      assert process_instance.error_info["message"] =~ "Event Subprocess 'ESP_Timer'"
      assert process_instance.error_info["message"] =~ "'1 + 1'"
      assert process_instance.error_info["message"] =~ "not a duration"
    end
  end

  defp http_deploy_and_start_raw(fixture_name, process_model_id) do
    {201, _deploy_body} = http_deploy(fixture_name)
    http_start(process_model_id)
  end
end
