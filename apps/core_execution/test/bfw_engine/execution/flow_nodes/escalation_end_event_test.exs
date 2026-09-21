defmodule BfwEngine.Execution.FlowNodes.EscalationEndEventTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.EscalationDefinition
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
    escalation_ref = Keyword.get(opts, :escalation_ref)
    id = Keyword.get(opts, :id, "End_Escalation")
    name = Keyword.get(opts, :name, "Escalation End")

    %FlowNode{
      id: id,
      name: name,
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Escalation{
          escalation_ref: escalation_ref
        }
      },
      incoming: ["Flow_1"]
    }
  end

  defp make_context(opts \\ []) do
    escalations = Keyword.get(opts, :escalations, [])

    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_instance_pid: self(),
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
    test "returns {:escalation_end, escalation_info, FlowNodeResult}" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      assert {:escalation_end, %{} = _escalation_info, %FlowNodeResult{}} =
               FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)
    end

    test "result has empty next_flow_node_ids (end event has no successors)" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:escalation_end, _escalation_info, result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert result.next_flow_node_ids == []
    end

    test "passes through token payload unchanged" do
      payload = %{"order_id" => "ORD-42", "items" => [1, 2, 3]}
      flow_node = make_flow_node()
      token = make_token(payload)
      context = make_context()

      {:escalation_end, _escalation_info, result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert result.output_payload == payload
    end

    test "metadata includes persisted flag and lifecycle result" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:escalation_end, _escalation_info, result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert result.metadata.persisted == true
      assert result.metadata.lifecycle != nil
    end
  end

  describe "handle_enter/3 — escalation_info resolution" do
    test "returns nil code and name when no escalation_ref" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:escalation_end, escalation_info, _result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert escalation_info.escalation_code == nil
      assert escalation_info.escalation_name == nil
    end

    test "resolves code and name from global EscalationDefinition via ref" do
      global_escalation = %EscalationDefinition{
        id: "Esc_Order",
        name: "Order Escalation",
        escalation_code: "ESC_ORDER_REVIEW"
      }

      flow_node = make_flow_node(escalation_ref: "Esc_Order")
      token = make_token()
      context = make_context(escalations: [global_escalation])

      {:escalation_end, escalation_info, result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert escalation_info.escalation_code == "ESC_ORDER_REVIEW"
      assert escalation_info.escalation_name == "Order Escalation"
      assert result.type_properties.escalation_code == "ESC_ORDER_REVIEW"
      assert result.type_properties.escalation_name == "Order Escalation"
    end

    test "escalation_ref pointing to non-existent global definition results in nil code" do
      flow_node = make_flow_node(escalation_ref: "Esc_NonExistent")
      token = make_token()
      context = make_context(escalations: [])

      {:escalation_end, escalation_info, _result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert escalation_info.escalation_code == nil
      assert escalation_info.escalation_name == nil
    end
  end

  describe "handle_enter/3 — type_properties" do
    test "type_properties includes end_event_id, end_event_name, and escalation fields" do
      global_escalation = %EscalationDefinition{
        id: "Esc_1",
        name: "My Escalation",
        escalation_code: "ESC_CODE_1"
      }

      flow_node =
        make_flow_node(
          id: "End_EscalationCustom",
          name: "My Escalation End",
          escalation_ref: "Esc_1"
        )

      token = make_token()
      context = make_context(escalations: [global_escalation])

      {:escalation_end, _escalation_info, result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert result.type_properties == %{
               end_event_id: "End_EscalationCustom",
               end_event_name: "My Escalation End",
               escalation_code: "ESC_CODE_1",
               escalation_name: "My Escalation"
             }
    end

    test "type_properties has nil escalation fields when no ref" do
      flow_node = make_flow_node(id: "End_E", name: "E End")
      token = make_token()
      context = make_context()

      {:escalation_end, _escalation_info, result} =
        FlowNodes.EscalationEndEvent.handle_enter(flow_node, token, context)

      assert result.type_properties.end_event_id == "End_E"
      assert result.type_properties.end_event_name == "E End"
      assert result.type_properties.escalation_code == nil
      assert result.type_properties.escalation_name == nil
    end
  end
end
