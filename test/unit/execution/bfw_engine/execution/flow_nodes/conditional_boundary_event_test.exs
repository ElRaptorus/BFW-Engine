defmodule BfwEngine.Execution.FlowNodes.ConditionalBoundaryEventTest do
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.FlowNodes.ConditionalBoundaryEvent
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  defp build_boundary_flow_node(condition_expression, cancel_activity) do
    %FlowNode{
      id: "ConditionalBoundary_1",
      name: "Wait for Condition",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "UserTask_Host",
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Conditional{
          condition_expression: condition_expression
        }
      },
      incoming: [],
      outgoing: ["Flow_BE"]
    }
  end

  defp build_context(opts \\ []) do
    %HandlerContext{
      flow_node_instance_id: Keyword.get(opts, :flow_node_instance_id, "fni-boundary-1"),
      process_instance_id: "pi-test-1",
      process_instance_pid: self(),
      process_model: nil,
      host_flow_node_instance_id: Keyword.get(opts, :host_fni_id, "fni-host-1"),
      flow_node_this: %{
        "id" => "ConditionalBoundary_1",
        "name" => "Wait for Condition",
        "type" => "boundary_event"
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

  describe "handle_enter/3 — interrupting, condition true" do
    test "fires immediately with cancel_activity: true" do
      flow_node = build_boundary_flow_node("token.fire = true", true)
      context = build_context()
      token = build_token(%{"fire" => true})

      assert {:boundary, "ConditionalBoundary_1", %{}, true} =
               ConditionalBoundaryEvent.handle_enter(flow_node, token, context)
    end
  end

  describe "handle_enter/3 — non-interrupting, condition true" do
    test "fires immediately with cancel_activity: false" do
      flow_node = build_boundary_flow_node("token.fire = true", false)
      context = build_context()
      token = build_token(%{"fire" => true})

      assert {:boundary, "ConditionalBoundary_1", %{}, false} =
               ConditionalBoundaryEvent.handle_enter(flow_node, token, context)
    end
  end

  describe "handle_enter/3 — condition false, parks as waiting" do
    test "returns {:wait, ...} when condition is false" do
      flow_node = build_boundary_flow_node("token.fire = true", true)
      context = build_context()
      token = build_token(%{"fire" => false})

      assert {:wait, %BfwEngine.Execution.FlowNodeResult{} = result} =
               ConditionalBoundaryEvent.handle_enter(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
    end

    test "non-interrupting boundary also returns {:wait, ...}" do
      flow_node = build_boundary_flow_node("token.fire = true", false)
      context = build_context()
      token = build_token(%{"fire" => false})

      assert {:wait, %BfwEngine.Execution.FlowNodeResult{} = result} =
               ConditionalBoundaryEvent.handle_enter(flow_node, token, context)

      assert result.metadata.awaiting_condition == true
    end
  end

  describe "handle_enter/3 — Data Object condition" do
    test "fires when data object matches" do
      flow_node = build_boundary_flow_node("dataObjects.Trigger.ready = true", true)
      context = build_context(data_objects: %{"Trigger" => %{"ready" => true}})
      token = build_token()

      assert {:boundary, "ConditionalBoundary_1", %{}, true} =
               ConditionalBoundaryEvent.handle_enter(flow_node, token, context)
    end
  end

  describe "handle_resume/3" do
    test "fires immediately when condition is true on resume" do
      flow_node = build_boundary_flow_node("context.trigger = true", true)
      context = build_context(context: %{"trigger" => true})

      assert {:boundary, "ConditionalBoundary_1", %{}, true} =
               ConditionalBoundaryEvent.handle_resume(flow_node, %{}, context)
    end

    test "parks as waiting when condition is still false on resume" do
      flow_node = build_boundary_flow_node("context.trigger = true", true)
      context = build_context(context: %{"trigger" => false})

      assert {:wait, %BfwEngine.Execution.FlowNodeResult{} = result} =
               ConditionalBoundaryEvent.handle_resume(flow_node, %{}, context)

      assert result.metadata.awaiting_condition == true
    end
  end

  describe "evaluate_condition/3" do
    test "returns {:fire, true} when condition matches" do
      flow_node = build_boundary_flow_node("dataObjects.Trigger.fire = true", true)
      token_payload = %{}

      pi_state = %{
        process_instance_id: "pi-test-1",
        identity: nil,
        process_model: %{id: "test-process", name: "Test Process", version: "1.0.0"},
        started_with_context: %{},
        data_object_cache: %{"Trigger" => %{"fire" => true}},
        started_at: nil
      }

      assert {:fire, true} =
               ConditionalBoundaryEvent.evaluate_condition(flow_node, token_payload, pi_state)
    end

    test "returns {:fire, false} when condition does not match" do
      flow_node = build_boundary_flow_node("dataObjects.Trigger.fire = true", true)
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
               ConditionalBoundaryEvent.evaluate_condition(flow_node, token_payload, pi_state)
    end
  end

  describe "handle_fatal/1 and handle_aborted/1" do
    test "handle_fatal returns :ok" do
      assert :ok = ConditionalBoundaryEvent.handle_fatal(%{})
    end

    test "handle_aborted returns :ok" do
      assert :ok = ConditionalBoundaryEvent.handle_aborted(%{})
    end
  end
end
