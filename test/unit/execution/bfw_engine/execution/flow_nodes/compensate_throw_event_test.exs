defmodule BfwEngine.Execution.FlowNodes.CompensateThrowEventTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
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
    id = Keyword.get(opts, :id, "Throw_Compensation")
    name = Keyword.get(opts, :name, "Compensate Throw")
    activity_ref = Keyword.get(opts, :activity_ref, nil)
    outgoing = Keyword.get(opts, :outgoing, ["Flow_out"])

    %FlowNode{
      id: id,
      name: name,
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Compensation{
          activity_ref: activity_ref
        }
      },
      incoming: ["Flow_in"],
      outgoing: outgoing
    }
  end

  defp make_end_node(id) do
    %FlowNode{
      id: id,
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: nil},
      incoming: ["Flow_out"]
    }
  end

  defp make_context(opts \\ []) do
    flow_node_id = Keyword.get(opts, :flow_node_id, "Throw_Compensation")
    outgoing_target_id = Keyword.get(opts, :outgoing_target_id, "End_1")

    throw_node = make_flow_node(id: flow_node_id)
    end_node = make_end_node(outgoing_target_id)

    process_model = %BpmnProcess{
      id: "proc",
      flow_nodes: [throw_node, end_node],
      sequence_flows: [
        %SequenceFlow{
          id: "Flow_out",
          source_ref: flow_node_id,
          target_ref: outgoing_target_id
        }
      ]
    }

    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_instance_pid: self(),
      process_model: process_model,
      identity: %{},
      process: %{},
      process_instance: %{},
      data_objects: %{}
    }
  end

  describe "handle_enter/3 — returns {:compensate, run_spec, FlowNodeResult}" do
    test "returns {:compensate, ...} with outgoing flows" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      assert {:compensate, run_spec, %FlowNodeResult{} = result} =
               FlowNodes.CompensateThrowEvent.handle_enter(flow_node, token, context)

      assert run_spec.throw_type == :throw
      assert run_spec.outgoing_flow_node_ids == ["End_1"]
      assert result.next_flow_node_ids == ["End_1"]
    end

    test "passes through input token payload unchanged" do
      payload = %{"order_id" => "ORD-99", "amount" => 42}
      flow_node = make_flow_node()
      token = make_token(payload)
      context = make_context()

      {:compensate, _run_spec, result} =
        FlowNodes.CompensateThrowEvent.handle_enter(flow_node, token, context)

      assert result.output_payload == payload
    end

    test "includes event_definition in run_spec" do
      event_definition = %EventDefinition.Compensation{activity_ref: "Task_A"}
      flow_node = make_flow_node(activity_ref: "Task_A")
      token = make_token()
      context = make_context()

      {:compensate, run_spec, _result} =
        FlowNodes.CompensateThrowEvent.handle_enter(flow_node, token, context)

      assert run_spec.event_definition == event_definition
      assert run_spec.event_definition.activity_ref == "Task_A"
    end

    test "event_definition has nil activity_ref when not specified" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:compensate, run_spec, _result} =
        FlowNodes.CompensateThrowEvent.handle_enter(flow_node, token, context)

      assert run_spec.event_definition.activity_ref == nil
    end

    test "type_properties and metadata are empty maps" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:compensate, _run_spec, result} =
        FlowNodes.CompensateThrowEvent.handle_enter(flow_node, token, context)

      assert result.type_properties == %{}
      assert result.metadata == %{}
    end
  end
end
