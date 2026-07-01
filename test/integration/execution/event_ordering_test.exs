defmodule EvilEngine.Integration.Execution.EventOrderingTest do
  @moduledoc "Strict event ordering verification for Start → Task → End."
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  describe "event ordering for Start → Task → End" do
    test "events arrive in strict sequence with correct metadata", %{collector: collector} do
      {201, _} = http_deploy("linear_three_node.bpmn")

      {201, body} =
        http_start("LinearThreeNode", %{"payload" => %{"x" => 1}})

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      events = EventCollector.await_events(collector, 9, 2_000)

      assert length(events) == 9

      [
        deploy_event,
        process_instance_start_event,
        fni1_start,
        fni1_finish,
        fni2_start,
        fni2_finish,
        fni3_start,
        fni3_finish,
        process_instance_finish_event
      ] = events

      assert %Event.ProcessDefinitionDeployed{} = deploy_event
      assert %Event.ProcessInstanceStateChanged{old_state: nil, new_state: :running} = process_instance_start_event
      assert process_instance_start_event.process_instance_id == process_instance_id

      assert %Event.FlowNodeInstanceStarted{flow_node_id: "Start_1", flow_node_type: :start_event} =
               fni1_start

      assert fni1_start.process_instance_id == process_instance_id

      assert %Event.FlowNodeInstanceFinished{flow_node_id: "Start_1", terminal_state: :finished} =
               fni1_finish

      assert fni1_finish.process_instance_id == process_instance_id

      assert %Event.FlowNodeInstanceStarted{flow_node_id: "Task_1", flow_node_type: :task} = fni2_start
      assert fni2_start.process_instance_id == process_instance_id

      assert %Event.FlowNodeInstanceFinished{flow_node_id: "Task_1", terminal_state: :finished} = fni2_finish
      assert fni2_finish.process_instance_id == process_instance_id

      assert %Event.FlowNodeInstanceStarted{flow_node_id: "End_1", flow_node_type: :end_event} = fni3_start
      assert fni3_start.process_instance_id == process_instance_id

      assert %Event.FlowNodeInstanceFinished{flow_node_id: "End_1", terminal_state: :finished} = fni3_finish
      assert fni3_finish.process_instance_id == process_instance_id

      assert %Event.ProcessInstanceStateChanged{old_state: :running, new_state: :finished} = process_instance_finish_event
      assert process_instance_finish_event.process_instance_id == process_instance_id
    end
  end
end
