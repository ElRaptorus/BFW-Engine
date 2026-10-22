defmodule BfwEngine.Execution.FlowNodes.CompensateEndEventTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  defp make_token(payload \\ %{"key" => "value"}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: payload,
      created_at: DateTime.utc_now()
    }
  end

  defp make_flow_node(opts \\ []) do
    id = Keyword.get(opts, :id, "End_Compensation")
    name = Keyword.get(opts, :name, "Compensation End")
    activity_ref = Keyword.get(opts, :activity_ref, nil)

    %FlowNode{
      id: id,
      name: name,
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Compensation{
          activity_ref: activity_ref
        }
      },
      incoming: ["Flow_in"]
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

  describe "handle_enter/3 — returns {:compensate, run_spec, FlowNodeResult}" do
    test "returns {:compensate, ...} with empty outgoing" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      assert {:compensate, run_spec, %FlowNodeResult{} = result} =
               FlowNodes.CompensateEndEvent.handle_enter(flow_node, token, context)

      assert run_spec.throw_type == :end
      assert run_spec.outgoing_flow_node_ids == []
      assert result.next_flow_node_ids == []
    end

    test "populates type_properties with end event id and name" do
      flow_node = make_flow_node(id: "End_Comp_1", name: "My Compensation End")
      token = make_token()
      context = make_context()

      {:compensate, _run_spec, result} =
        FlowNodes.CompensateEndEvent.handle_enter(flow_node, token, context)

      assert result.type_properties.end_event_id == "End_Comp_1"
      assert result.type_properties.end_event_name == "My Compensation End"
    end

    test "passes through input token payload" do
      payload = %{"refund" => true, "reason" => "cancellation"}
      flow_node = make_flow_node()
      token = make_token(payload)
      context = make_context()

      {:compensate, _run_spec, result} =
        FlowNodes.CompensateEndEvent.handle_enter(flow_node, token, context)

      assert result.output_payload == payload
    end

    test "includes event_definition in run_spec" do
      event_definition = %EventDefinition.Compensation{activity_ref: "Task_Refund"}
      flow_node = make_flow_node(activity_ref: "Task_Refund")
      token = make_token()
      context = make_context()

      {:compensate, run_spec, _result} =
        FlowNodes.CompensateEndEvent.handle_enter(flow_node, token, context)

      assert run_spec.event_definition == event_definition
      assert run_spec.event_definition.activity_ref == "Task_Refund"
    end

    test "metadata is an empty map" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:compensate, _run_spec, result} =
        FlowNodes.CompensateEndEvent.handle_enter(flow_node, token, context)

      assert result.metadata == %{}
    end
  end
end
