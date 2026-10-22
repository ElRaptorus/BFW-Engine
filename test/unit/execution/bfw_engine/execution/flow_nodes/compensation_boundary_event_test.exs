defmodule BfwEngine.Execution.FlowNodes.CompensationBoundaryEventTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  defp make_flow_node do
    %FlowNode{
      id: "Boundary_Compensation",
      name: "Compensation Boundary",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        event_definition: %EventDefinition.Compensation{},
        attached_to_ref: "Task_Host",
        cancel_activity: true
      },
      incoming: []
    }
  end

  defp make_token do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: %{},
      created_at: DateTime.utc_now()
    }
  end

  defp make_context do
    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_instance_pid: self(),
      identity: %{},
      process: %{},
      process_instance: %{},
      data_objects: %{}
    }
  end

  describe "handle_enter/3" do
    test "returns error — compensation boundary should never be dispatched" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      assert {:error, :compensation_boundary_not_dispatched} =
               FlowNodes.CompensationBoundaryEvent.handle_enter(flow_node, token, context)
    end
  end
end
