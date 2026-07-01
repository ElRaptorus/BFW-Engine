defmodule EvilEngine.Execution.FlowNodes.BoundaryEventTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.FlowNodes.BoundaryEvent
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  defp build_context(process_model) do
    %HandlerContext{
      flow_node_instance_id: "fni-boundary-1",
      process_instance_id: "pi-1",
      process_model: process_model,
      identity: %{},
      process: %{},
      process_instance: %{id: "pi-1"},
      data_objects: %{}
    }
  end

  describe "handle_enter/3" do
    test "passes through error token along outgoing flow" do
      boundary_node = %FlowNode{
        id: "BE_1",
        type: :boundary_event,
        type_data: %FlowNodeData.BoundaryEvent{
          attached_to_ref: "CA_1",
          event_definition: %EventDefinition.Error{error_code: "ERR"}
        },
        incoming: [],
        outgoing: ["Flow_BE"]
      }

      end_node = %FlowNode{
        id: "End_Error",
        type: :end_event,
        type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
        incoming: ["Flow_BE"]
      }

      flow = %SequenceFlow{id: "Flow_BE", source_ref: "BE_1", target_ref: "End_Error"}

      model = %BpmnProcess{
        id: "proc",
        flow_nodes: [boundary_node, end_node],
        sequence_flows: [flow]
      }

      token = %Token{
        id: "t1",
        process_instance_id: "pi-1",
        payload: %{error_code: "ERR", error_message: "something failed"}
      }

      context = build_context(model)
      assert {:ok, result} = BoundaryEvent.handle_enter(boundary_node, token, context)
      assert result.output_payload == token.payload
      assert result.next_flow_node_ids == ["End_Error"]
    end
  end
end
