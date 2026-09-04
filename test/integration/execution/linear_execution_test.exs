defmodule EvilEngine.Integration.Execution.LinearExecutionTest do
  @moduledoc "Integration tests for linear process execution (Start→End, Start→Task→End)."
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  describe "Start → End" do
    test "PI finishes with 2 FNIs, both persisted as finished", %{collector: collector} do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {201, body} =
        http_start("LinearStartEnd", %{"payload" => %{"key" => "value"}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      process_instance = assert_pi_state!(process_instance_id, "finished")
      assert process_instance.finished_at != nil
      assert process_instance.started_with_context == nil

      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 2)
      assert_all_fnis_state!(process_instance_id, "finished")

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_1"))

      assert start_fni.flow_node_type == "start_event"
      assert start_fni.event_type == nil
      assert end_fni.flow_node_type == "end_event"
      assert end_fni.event_type == nil
      assert start_fni.input_token == %{"key" => "value"}
      assert start_fni.output_token == %{"key" => "value"}
      assert end_fni.input_token == %{"key" => "value"}
      assert end_fni.output_token == %{"key" => "value"}

      Enum.each(flow_node_instances, fn fni ->
        assert fni.error_info == nil,
               "Successful FNI #{fni.id} (#{fni.flow_node_id}) should have nil error_info"
      end)

      events = EventCollector.await_events(collector, 7)
      types = Enum.map(events, &(&1.__struct__))

      assert types == [
               Event.ProcessDefinitionDeployed,
               Event.ProcessInstanceStateChanged,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceFinished,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceFinished,
               Event.ProcessInstanceStateChanged
             ]
    end
  end

  describe "Start → Task → End" do
    test "PI finishes with 3 FNIs, payload threads through", %{collector: collector} do
      {201, _} = http_deploy("linear_three_node.bpmn")

      {201, body} =
        http_start("LinearThreeNode", %{"payload" => %{"order_id" => 42}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      process_instance = assert_pi_state!(process_instance_id, "finished")
      assert process_instance.finished_at != nil

      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      task_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Task_1"))
      end_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "End_1"))

      assert start_fni.flow_node_type == "start_event"
      assert start_fni.event_type == nil
      assert task_fni.flow_node_type == "task"
      assert task_fni.event_type == nil
      assert end_fni.flow_node_type == "end_event"
      assert end_fni.event_type == nil

      assert start_fni.input_token == %{"order_id" => 42}
      assert start_fni.output_token == %{"order_id" => 42}
      assert task_fni.input_token == %{"order_id" => 42}
      assert task_fni.output_token == %{"order_id" => 42}
      assert end_fni.input_token == %{"order_id" => 42}
      assert end_fni.output_token == %{"order_id" => 42}

      Enum.each(flow_node_instances, fn fni ->
        assert fni.error_info == nil,
               "Successful FNI #{fni.id} (#{fni.flow_node_id}) should have nil error_info"
      end)

      events = EventCollector.await_events(collector, 9)
      types = Enum.map(events, &(&1.__struct__))

      assert types == [
               Event.ProcessDefinitionDeployed,
               Event.ProcessInstanceStateChanged,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceFinished,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceFinished,
               Event.FlowNodeInstanceStarted,
               Event.FlowNodeInstanceFinished,
               Event.ProcessInstanceStateChanged
             ]
    end
  end
end
