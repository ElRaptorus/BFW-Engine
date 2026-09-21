defmodule BfwEngine.Execution.FlowNodes.EscalationIntermediateThrowEventTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.EscalationDefinition
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
    escalation_ref = Keyword.get(opts, :escalation_ref)
    id = Keyword.get(opts, :id, "Throw_Escalation")
    name = Keyword.get(opts, :name, "Throw Escalation")
    outgoing = Keyword.get(opts, :outgoing, ["Flow_out"])

    %FlowNode{
      id: id,
      name: name,
      type: :intermediate_throw_event,
      type_data: %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Escalation{
          escalation_ref: escalation_ref
        }
      },
      incoming: ["Flow_1"],
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
    escalations = Keyword.get(opts, :escalations, [])
    flow_node_id = Keyword.get(opts, :flow_node_id, "Throw_Escalation")
    outgoing_target_id = Keyword.get(opts, :outgoing_target_id, "End_1")

    end_node = make_end_node(outgoing_target_id)
    throw_node = make_flow_node(id: flow_node_id)

    process_model = %BpmnProcess{
      id: "proc",
      flow_nodes: [throw_node, end_node],
      sequence_flows: [
        %SequenceFlow{id: "Flow_out", source_ref: flow_node_id, target_ref: outgoing_target_id}
      ]
    }

    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_instance_pid: self(),
      process_model: process_model,
      definitions: %Definitions{
        definitions_id: "Definitions_1",
        escalations: escalations,
        raw_xml: ""
      },
      identity: %{},
      process: %{},
      process_instance: %{},
      data_objects: %{}
    }
  end

  describe "handle_enter/3 — result type" do
    test "returns {:escalation_throw, escalation_info, FlowNodeResult}" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      assert {:escalation_throw, %{} = _escalation_info, %FlowNodeResult{}} =
               FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)
    end

    test "result contains outgoing flow node IDs" do
      flow_node = make_flow_node(outgoing: ["Flow_out"])
      token = make_token()
      context = make_context()

      {:escalation_throw, _escalation_info, result} =
        FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)

      assert result.next_flow_node_ids == ["End_1"]
    end

    test "passes through token payload unchanged" do
      payload = %{"order_id" => "ORD-42"}
      flow_node = make_flow_node()
      token = make_token(payload)
      context = make_context()

      {:escalation_throw, _escalation_info, result} =
        FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)

      assert result.output_payload == payload
    end

    test "metadata includes persisted flag and lifecycle result" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:escalation_throw, _escalation_info, result} =
        FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)

      assert result.metadata.persisted == true
      assert result.metadata.lifecycle != nil
    end
  end

  describe "handle_enter/3 — escalation_info resolution" do
    test "returns nil code and name when no escalation_ref" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:escalation_throw, escalation_info, _result} =
        FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)

      assert escalation_info.escalation_code == nil
      assert escalation_info.escalation_name == nil
    end

    test "resolves code and name from global EscalationDefinition via ref" do
      global_escalation = %EscalationDefinition{
        id: "Esc_Approval",
        name: "Approval Escalation",
        escalation_code: "ESC_APPROVAL_NEEDED"
      }

      flow_node = make_flow_node(escalation_ref: "Esc_Approval")
      token = make_token()
      context = make_context(escalations: [global_escalation])

      {:escalation_throw, escalation_info, result} =
        FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)

      assert escalation_info.escalation_code == "ESC_APPROVAL_NEEDED"
      assert escalation_info.escalation_name == "Approval Escalation"
      assert result.type_properties.escalation_code == "ESC_APPROVAL_NEEDED"
    end

    test "returns nil code when escalation_ref points to non-existent definition" do
      flow_node = make_flow_node(escalation_ref: "Esc_NonExistent")
      token = make_token()
      context = make_context()

      {:escalation_throw, escalation_info, _result} =
        FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)

      assert escalation_info.escalation_code == nil
    end
  end

  describe "handle_enter/3 — type_properties" do
    test "type_properties includes escalation code and name" do
      global_escalation = %EscalationDefinition{
        id: "Esc_1",
        name: "My Escalation",
        escalation_code: "ESC_CODE_1"
      }

      flow_node = make_flow_node(escalation_ref: "Esc_1")
      token = make_token()
      context = make_context(escalations: [global_escalation])

      {:escalation_throw, _escalation_info, result} =
        FlowNodes.EscalationIntermediateThrowEvent.handle_enter(flow_node, token, context)

      assert result.type_properties == %{
               escalation_code: "ESC_CODE_1",
               escalation_name: "My Escalation"
             }
    end
  end
end
