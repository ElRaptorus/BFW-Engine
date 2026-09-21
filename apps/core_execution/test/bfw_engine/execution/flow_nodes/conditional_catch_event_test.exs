defmodule BfwEngine.Execution.FlowNodes.ConditionalCatchEventTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.ConditionalCatchEvent
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  defp build_conditional_flow_node(condition_expression) do
    %FlowNode{
      id: "ConditionalCatch_1",
      name: "Wait for Condition",
      type: :intermediate_catch_event,
      type_data: %FlowNodeData.IntermediateCatchEvent{
        event_definition: %EventDefinition.Conditional{
          condition_expression: condition_expression
        }
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"]
    }
  end

  defp build_process_model(flow_node) do
    end_event = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    %BpmnProcess{
      id: "test-process",
      name: "Test Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: [flow_node, end_event],
      sequence_flows: [
        %SequenceFlow{id: "Flow_2", source_ref: "ConditionalCatch_1", target_ref: "End_1"}
      ]
    }
  end

  defp build_context(flow_node, opts \\ []) do
    process_model = build_process_model(flow_node)

    %HandlerContext{
      flow_node_instance_id: Keyword.get(opts, :flow_node_instance_id, "fni-cond-1"),
      process_instance_id: "pi-test-1",
      process_instance_pid: self(),
      process_model: process_model,
      flow_node_this: %{
        "id" => flow_node.id,
        "name" => flow_node.name,
        "type" => "intermediate_catch_event"
      },
      context: Keyword.get(opts, :context, %{}),
      identity: %{},
      process: %{"id" => "test-process", "name" => "Test Process", "version" => "1.0.0"},
      process_instance: %{"id" => "pi-test-1", "startedAt" => nil, "startedBy" => nil},
      data_objects: Keyword.get(opts, :data_objects, %{})
    }
  end

  defp build_token(payload \\ %{}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-test-1",
      payload: payload,
      originating_flow_node_instance_id: nil,
      created_at: DateTime.utc_now()
    }
  end

  describe "handle_enter/3 — condition already true" do
    test "returns {:wait, result} even when condition is true — PI handles completion" do
      flow_node = build_conditional_flow_node("token.ready = true")
      context = build_context(flow_node)
      token = build_token(%{"ready" => true})

      assert {:wait, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.handle_enter(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
      assert result.next_flow_node_ids == ["End_1"]
    end
  end

  describe "handle_enter/3 — condition false, parks as waiting" do
    test "returns {:wait, ...} when condition evaluates to false" do
      flow_node = build_conditional_flow_node("token.ready = true")
      context = build_context(flow_node)
      token = build_token(%{"ready" => false})

      assert {:wait, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.handle_enter(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
      assert result.next_flow_node_ids == ["End_1"]
    end
  end

  describe "handle_enter/3 — FEEL evaluation error" do
    test "parks as waiting when condition expression references unknown variable" do
      flow_node = build_conditional_flow_node("nonexistent.field = true")
      context = build_context(flow_node)
      token = build_token(%{})

      assert {:wait, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.handle_enter(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
    end
  end

  describe "handle_enter/3 — Data Object condition" do
    test "condition true when data object has matching value — still returns wait" do
      flow_node = build_conditional_flow_node("dataObjects.OrderData.status = \"ready\"")
      context = build_context(flow_node, data_objects: %{"OrderData" => %{"status" => "ready"}})
      token = build_token()

      assert {:wait, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.handle_enter(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
    end

    test "condition false when data object does not match" do
      flow_node = build_conditional_flow_node("dataObjects.OrderData.status = \"ready\"")
      context = build_context(flow_node, data_objects: %{"OrderData" => %{"status" => "pending"}})
      token = build_token()

      assert {:wait, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.handle_enter(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
    end
  end

  describe "complete_condition/3" do
    test "persists and returns FlowNodeResult with outgoing targets" do
      flow_node = build_conditional_flow_node("token.ready = true")
      context = build_context(flow_node)

      assert {:ok, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.complete_condition(flow_node, %{"ready" => true}, context)

      assert result.output_payload == %{"ready" => true}
      assert result.next_flow_node_ids == ["End_1"]
    end
  end

  describe "handle_resume/3" do
    test "returns {:wait, ...} even when condition is true — PI handles completion" do
      flow_node = build_conditional_flow_node("token.value > 100")
      context = build_context(flow_node)
      token = build_token(%{"value" => 200})

      assert {:wait, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.handle_resume(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
    end

    test "parks as waiting when condition is still false on resume" do
      flow_node = build_conditional_flow_node("token.value > 100")
      context = build_context(flow_node)
      token = build_token(%{"value" => 50})

      assert {:wait, %FlowNodeResult{} = result} =
               ConditionalCatchEvent.handle_resume(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
    end
  end

  describe "evaluate_condition/3" do
    test "returns {:fire, true} when condition matches" do
      flow_node = build_conditional_flow_node("token.amount > 100")
      token_payload = %{"amount" => 200}

      pi_state = %{
        process_instance_id: "pi-test-1",
        identity: nil,
        process_model: %{id: "test-process", name: "Test Process", version: "1.0.0"},
        started_with_context: %{},
        data_object_cache: %{},
        started_at: nil
      }

      assert {:fire, true} =
               ConditionalCatchEvent.evaluate_condition(flow_node, token_payload, pi_state)
    end

    test "returns {:fire, false} when condition does not match" do
      flow_node = build_conditional_flow_node("token.amount > 100")
      token_payload = %{"amount" => 50}

      pi_state = %{
        process_instance_id: "pi-test-1",
        identity: nil,
        process_model: %{id: "test-process", name: "Test Process", version: "1.0.0"},
        started_with_context: %{},
        data_object_cache: %{},
        started_at: nil
      }

      assert {:fire, false} =
               ConditionalCatchEvent.evaluate_condition(flow_node, token_payload, pi_state)
    end

    test "returns {:fire, false} on FEEL evaluation error" do
      flow_node = build_conditional_flow_node("nonexistent.deep.path = true")
      token_payload = %{}

      pi_state = %{
        process_instance_id: "pi-test-1",
        identity: nil,
        process_model: %{id: "test-process", name: "Test Process", version: "1.0.0"},
        started_with_context: %{},
        data_object_cache: %{},
        started_at: nil
      }

      assert {:fire, false} =
               ConditionalCatchEvent.evaluate_condition(flow_node, token_payload, pi_state)
    end

    test "evaluates against data_object_cache from PI state" do
      flow_node = build_conditional_flow_node("dataObjects.Order.ready = true")
      token_payload = %{}

      pi_state = %{
        process_instance_id: "pi-test-1",
        identity: nil,
        process_model: %{id: "test-process", name: "Test Process", version: "1.0.0"},
        started_with_context: %{},
        data_object_cache: %{"Order" => %{"ready" => true}},
        started_at: nil
      }

      assert {:fire, true} =
               ConditionalCatchEvent.evaluate_condition(flow_node, token_payload, pi_state)
    end
  end

  describe "handle_fatal/1 and handle_aborted/1" do
    test "handle_fatal returns :ok" do
      assert :ok = ConditionalCatchEvent.handle_fatal(%{})
    end

    test "handle_aborted returns :ok" do
      assert :ok = ConditionalCatchEvent.handle_aborted(%{})
    end
  end
end
