defmodule BfwEngine.Execution.FlowNodes.ErrorEndEventTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.ErrorDefinition
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
    error_code = Keyword.get(opts, :error_code)
    error_message = Keyword.get(opts, :error_message)
    error_ref = Keyword.get(opts, :error_ref)
    id = Keyword.get(opts, :id, "End_Error")
    name = Keyword.get(opts, :name, "Error End")

    %FlowNode{
      id: id,
      name: name,
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Error{
          error_code: error_code,
          error_message: error_message,
          error_ref: error_ref
        }
      },
      incoming: ["Flow_1"]
    }
  end

  defp make_context(opts \\ []) do
    errors = Keyword.get(opts, :errors, [])

    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_instance_pid: self(),
      definitions: %Definitions{
        definitions_id: "Definitions_1",
        errors: errors,
        raw_xml: ""
      },
      identity: %{},
      process: %{},
      process_instance: %{},
      data_objects: %{}
    }
  end

  describe "handle_enter/3 — inline error code and message" do
    test "returns {:bpmn_error, error_info, FlowNodeResult} with inline code and message" do
      flow_node = make_flow_node(error_code: "VALIDATION_FAILED", error_message: "Input invalid")
      token = make_token()
      context = make_context()

      assert {:bpmn_error, error_info, %FlowNodeResult{} = result} =
               FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert error_info == %{error_code: "VALIDATION_FAILED", error_message: "Input invalid"}
      assert result.output_payload == token.payload
      assert result.next_flow_node_ids == []
      assert result.type_properties.end_event_id == "End_Error"
      assert result.type_properties.end_event_name == "Error End"
      assert result.type_properties.error_code == "VALIDATION_FAILED"
      assert result.type_properties.error_message == "Input invalid"
    end

    test "passes through token payload unchanged" do
      payload = %{"order_id" => "ORD-42", "items" => [1, 2, 3]}
      flow_node = make_flow_node(error_code: "ERR")
      token = make_token(payload)
      context = make_context()

      {:bpmn_error, _error_info, result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert result.output_payload == payload
    end
  end

  describe "handle_enter/3 — error_ref resolution" do
    test "resolves error_code from global ErrorDefinition via error_ref" do
      global_error = %ErrorDefinition{
        id: "Err_Payment",
        name: "Payment Error",
        error_code: "PAYMENT_FAILED"
      }

      flow_node = make_flow_node(error_ref: "Err_Payment")
      token = make_token()
      context = make_context(errors: [global_error])

      {:bpmn_error, error_info, result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert error_info.error_code == "PAYMENT_FAILED"
      assert error_info.error_message == nil
      assert result.type_properties.error_code == "PAYMENT_FAILED"
    end

    test "inline error_code overrides global definition code" do
      global_error = %ErrorDefinition{id: "Err_1", error_code: "GLOBAL_CODE"}
      flow_node = make_flow_node(error_code: "INLINE_CODE", error_ref: "Err_1")
      token = make_token()
      context = make_context(errors: [global_error])

      {:bpmn_error, error_info, _result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert error_info.error_code == "INLINE_CODE"
    end

    test "error_ref pointing to non-existent global definition results in nil error_code" do
      flow_node = make_flow_node(error_ref: "Err_NonExistent")
      token = make_token()
      context = make_context(errors: [])

      {:bpmn_error, error_info, _result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert error_info.error_code == nil
      assert error_info.error_message == nil
    end
  end

  describe "handle_enter/3 — catch-all (no code, no ref)" do
    test "no error_ref, no inline code produces nil error_code and error_message" do
      flow_node = make_flow_node()
      token = make_token()
      context = make_context()

      {:bpmn_error, error_info, result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert error_info == %{error_code: nil, error_message: nil}
      assert result.type_properties.error_code == nil
      assert result.type_properties.error_message == nil
    end
  end

  describe "handle_enter/3 — result structure" do
    test "returns empty next_flow_node_ids (end events have no successors)" do
      flow_node = make_flow_node(error_code: "ERR")
      token = make_token()
      context = make_context()

      {:bpmn_error, _error_info, result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert result.next_flow_node_ids == []
    end

    test "populates type_properties with end event identity and error details" do
      flow_node =
        make_flow_node(
          id: "Custom_End",
          name: "My Error",
          error_code: "CUSTOM",
          error_message: "Something went wrong"
        )

      token = make_token()
      context = make_context()

      {:bpmn_error, _error_info, result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert result.type_properties == %{
               end_event_id: "Custom_End",
               end_event_name: "My Error",
               error_code: "CUSTOM",
               error_message: "Something went wrong"
             }
    end

    test "metadata includes persisted flag and lifecycle result" do
      flow_node = make_flow_node(error_code: "ERR")
      token = make_token()
      context = make_context()

      {:bpmn_error, _error_info, result} =
        FlowNodes.ErrorEndEvent.handle_enter(flow_node, token, context)

      assert result.metadata.persisted == true
      assert result.metadata.lifecycle != nil
    end
  end
end
