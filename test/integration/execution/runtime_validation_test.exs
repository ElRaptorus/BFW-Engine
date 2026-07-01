defmodule EvilEngine.Integration.Execution.RuntimeValidationTest do
  @moduledoc "Integration tests for encounter-time validation (implicit split, dead end)."
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  describe "implicit split" do
    test "task with 2 outgoing flows causes fatal PI", %{collector: collector} do
      {201, _} = http_deploy("implicit_split.bpmn")

      {201, body} = http_start("ImplicitSplit")
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal"))
      assert fatal_fni != nil
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info populated"
      assert is_map(fatal_fni.error_info), "error_info should be a map"

      non_fatal_fnis = Enum.reject(flow_node_instances, &(&1.state == "fatal"))

      Enum.each(non_fatal_fnis, fn fni ->
        assert fni.error_info == nil,
               "Non-fatal FNI #{fni.id} (#{fni.flow_node_id}) should have nil error_info, got: #{inspect(fni.error_info)}"
      end)

      events = EventCollector.await_events(collector, 4, 2_000)
      process_instance_state_change_events = Enum.filter(events, &match?(%Event.ProcessInstanceStateChanged{}, &1))
      final_process_instance_state_change_event = List.last(process_instance_state_change_events)
      assert final_process_instance_state_change_event.new_state == :fatal
    end
  end

  describe "dead end" do
    test "task with 0 outgoing flows causes fatal PI", %{collector: collector} do
      {201, _} = http_deploy("dead_end.bpmn")

      {201, body} = http_start("DeadEnd")
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal"))
      assert fatal_fni != nil
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info populated"
      assert is_map(fatal_fni.error_info), "error_info should be a map"

      non_fatal_fnis = Enum.reject(flow_node_instances, &(&1.state == "fatal"))

      Enum.each(non_fatal_fnis, fn fni ->
        assert fni.error_info == nil,
               "Non-fatal FNI #{fni.id} (#{fni.flow_node_id}) should have nil error_info, got: #{inspect(fni.error_info)}"
      end)

      events = EventCollector.await_events(collector, 4, 2_000)
      process_instance_state_change_events = Enum.filter(events, &match?(%Event.ProcessInstanceStateChanged{}, &1))
      final_process_instance_state_change_event = List.last(process_instance_state_change_events)
      assert final_process_instance_state_change_event.new_state == :fatal
    end
  end
end
