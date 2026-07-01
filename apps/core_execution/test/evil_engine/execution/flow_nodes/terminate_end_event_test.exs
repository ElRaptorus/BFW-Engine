defmodule EvilEngine.Execution.FlowNodes.TerminateEndEventTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  defp make_token(payload \\ %{"key" => "value"}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: payload,
      created_at: DateTime.utc_now()
    }
  end

  defp make_flow_node(id \\ "End_Terminate", name \\ "Terminate All") do
    %FlowNode{
      id: id,
      name: name,
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Terminate{}
      },
      incoming: ["Flow_1"]
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
    test "returns {:terminate, FlowNodeResult}" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      assert {:terminate, %FlowNodeResult{} = result} =
               FlowNodes.TerminateEndEvent.handle_enter(flow_node, token, context)

      assert result.output_payload == token.payload
      assert result.next_flow_node_ids == []
      assert result.type_properties.end_event_id == "End_Terminate"
      assert result.type_properties.end_event_name == "Terminate All"
    end

    test "passes through token payload unchanged" do
      payload = %{"order_id" => "123", "total" => 42}
      flow_node = make_flow_node()
      token = make_token(payload)
      context = make_context()

      {:terminate, result} =
        FlowNodes.TerminateEndEvent.handle_enter(flow_node, token, context)

      assert result.output_payload == payload
    end

    test "populates type_properties with end event identity" do
      flow_node = make_flow_node("Custom_End", "My Terminate")
      token = make_token()
      context = make_context()

      {:terminate, result} =
        FlowNodes.TerminateEndEvent.handle_enter(flow_node, token, context)

      assert result.type_properties == %{
               end_event_id: "Custom_End",
               end_event_name: "My Terminate"
             }
    end

    test "returns empty next_flow_node_ids (end events have no successors)" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:terminate, result} =
        FlowNodes.TerminateEndEvent.handle_enter(flow_node, token, context)

      assert result.next_flow_node_ids == []
    end
  end
end
