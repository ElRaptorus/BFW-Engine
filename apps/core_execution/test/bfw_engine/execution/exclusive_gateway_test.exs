defmodule BfwEngine.Execution.ExclusiveGatewayTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.ExclusiveGateway
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Types.Token

  defp make_token(payload \\ %{}) do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: payload,
      created_at: DateTime.utc_now()
    }
  end

  defp make_gateway(id, opts) do
    %FlowNode{
      id: id,
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{
        default_flow_ref: Keyword.get(opts, :default_flow_ref)
      },
      incoming: Keyword.get(opts, :incoming, ["sf-in"]),
      outgoing: Keyword.get(opts, :outgoing, [])
    }
  end

  defp make_target(id) do
    %FlowNode{id: id, type: :task, type_data: %FlowNodeData.Task{}}
  end

  defp make_context(gateway, sequence_flows, extra_nodes) do
    targets = Enum.map(extra_nodes, & &1) ++ [gateway]

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: targets ++ extra_nodes,
      sequence_flows: sequence_flows
    }

    %HandlerContext{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      process_model: process_model,
      flow_node_this: FeelContext.flow_node_this(gateway),
      identity: %{id: "user-1"},
      process: %{id: "proc-1"},
      process_instance: %{id: "pi-1"},
      data_objects: %{}
    }
  end

  # -------------------------------------------------------------------
  # Split: exactly one truthy condition
  # -------------------------------------------------------------------

  describe "split — exactly one truthy condition" do
    test "single truthy condition routes to the matching target" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "token.amount > 100"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "xor1",
        target_ref: "taskB",
        condition_expression: "token.amount <= 100"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 200})

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskA"]
      assert result.output_payload == token.payload
    end

    test "other branch wins when first condition is false" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "token.amount > 100"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "xor1",
        target_ref: "taskB",
        condition_expression: "token.amount <= 100"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 50})

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskB"]
    end
  end

  # -------------------------------------------------------------------
  # Split: default flow fallback
  # -------------------------------------------------------------------

  describe "split — default flow fallback" do
    test "falls back to default when no conditions are truthy" do
      target_a = make_target("taskA")
      target_default = make_target("taskDefault")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1000"
      }

      sf_default = %SequenceFlow{
        id: "sf-default",
        source_ref: "xor1",
        target_ref: "taskDefault",
        is_default: true
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a", "sf-default"])
      context = make_context(gateway, [sf_a, sf_default], [target_a, target_default])
      token = make_token(%{"amount" => 5})

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskDefault"]
    end
  end

  # -------------------------------------------------------------------
  # Split: no matching condition (fatal)
  # -------------------------------------------------------------------

  describe "split — no matching condition" do
    test "returns error when no condition is truthy and no default exists" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1000"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "xor1",
        target_ref: "taskB",
        condition_expression: "token.amount > 500"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 5})

      assert {:error, %{reason: :no_matching_condition}} =
               ExclusiveGateway.handle_enter(gateway, token, context)
    end

    test "single outgoing with a false condition fatals no_matching_condition" do
      target_a = make_target("taskA")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1000"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a"])
      context = make_context(gateway, [sf_a], [target_a])
      token = make_token(%{"amount" => 5})

      assert {:error, %{reason: :no_matching_condition}} =
               ExclusiveGateway.handle_enter(gateway, token, context)
    end

    test "unmarked non-default outgoing on a multi-out split fatals before FEEL" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "xor1",
        target_ref: "taskB"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 50})

      assert {:error, %{reason: :exclusive_gateway_unconditional_flow, sequence_flow_id: "sf-b"}} =
               ExclusiveGateway.handle_enter(gateway, token, context)
    end
  end

  # -------------------------------------------------------------------
  # Split: ambiguous conditions (fatal)
  # -------------------------------------------------------------------

  describe "split — ambiguous conditions" do
    test "returns error when multiple conditions are truthy" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "token.amount > 10"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "xor1",
        target_ref: "taskB",
        condition_expression: "token.amount > 5"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 50})

      assert {:error, %{reason: :ambiguous_condition} = error} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert "sf-a" in error.truthy_flow_ids
      assert "sf-b" in error.truthy_flow_ids
      assert error.message =~ "Multiple outgoing sequence flows"
    end
  end

  # -------------------------------------------------------------------
  # Split: expression evaluation failure (fatal)
  # -------------------------------------------------------------------

  describe "split — expression evaluation failure" do
    test "returns error when a FEEL expression has syntax errors" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-broken",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: "this is not valid FEEL @@!!"
      }

      sf_b = %SequenceFlow{
        id: "sf-false",
        source_ref: "xor1",
        target_ref: "taskB",
        condition_expression: "false"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-broken", "sf-false"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 50})

      assert {:error, %{reason: :expression_evaluation_failed} = error} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert error.sequence_flow_id == "sf-broken"
      assert error.message =~ "Failed to evaluate condition"
    end
  end

  # -------------------------------------------------------------------
  # Join (converging)
  # -------------------------------------------------------------------

  describe "join — converging gateway" do
    test "passes through to single outgoing flow" do
      target = make_target("taskAfterJoin")

      sf_out = %SequenceFlow{
        id: "sf-out",
        source_ref: "xor-join",
        target_ref: "taskAfterJoin"
      }

      gateway =
        make_gateway("xor-join",
          incoming: ["sf-in-1", "sf-in-2"],
          outgoing: ["sf-out"]
        )

      context = make_context(gateway, [sf_out], [target])
      token = make_token(%{"merged" => true})

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskAfterJoin"]
      assert result.output_payload == token.payload
    end
  end

  # -------------------------------------------------------------------
  # Mixed gateway (fatal)
  # -------------------------------------------------------------------

  describe "mixed gateway rejection" do
    test "returns error when gateway has >1 incoming AND >1 outgoing" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor-mixed",
        target_ref: "taskA",
        condition_expression: "true"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "xor-mixed",
        target_ref: "taskB",
        condition_expression: "false"
      }

      gateway =
        make_gateway("xor-mixed",
          incoming: ["sf-in-1", "sf-in-2"],
          outgoing: ["sf-a", "sf-b"]
        )

      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token()

      assert {:error, %{reason: :mixed_gateway} = error} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert error.incoming_count == 2
      assert error.outgoing_count == 2
      assert error.message =~ "Mixed gateway"
    end
  end

  # -------------------------------------------------------------------
  # Edge cases
  # -------------------------------------------------------------------

  describe "edge cases" do
    test "single incoming, single outgoing with truthy condition" do
      target = make_target("taskNext")

      sequence_flow = %SequenceFlow{
        id: "sf-only",
        source_ref: "xor1",
        target_ref: "taskNext",
        condition_expression: "true"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-only"])
      context = make_context(gateway, [sequence_flow], [target])
      token = make_token()

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskNext"]
    end

    test "gateway with nil incoming/outgoing doesn't crash" do
      gateway = %FlowNode{
        id: "xor-nil",
        type: :exclusive_gateway,
        type_data: %FlowNodeData.ExclusiveGateway{},
        incoming: nil,
        outgoing: nil
      }

      context = make_context(gateway, [], [])
      token = make_token()

      assert {:error, %{reason: :no_matching_condition}} =
               ExclusiveGateway.handle_enter(gateway, token, context)
    end

    test "unconditional outgoing flow on a one-out gateway is pass-through" do
      target = make_target("taskNext")

      sequence_flow = %SequenceFlow{
        id: "sf-unconditional",
        source_ref: "xor1",
        target_ref: "taskNext"
      }

      gateway = make_gateway("xor1", outgoing: ["sf-unconditional"])
      context = make_context(gateway, [sequence_flow], [target])
      token = make_token()

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskNext"]
    end
  end

  # -------------------------------------------------------------------
  # this binding contains flow node metadata, not token payload
  # -------------------------------------------------------------------

  describe "'this' binding carries flow node metadata" do
    test "condition referencing this.type resolves to gateway type, not token data" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "xor1",
        target_ref: "taskA",
        condition_expression: ~s|this.type = "exclusive_gateway"|
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "xor1",
        target_ref: "taskB",
        condition_expression: ~s|this.type != "exclusive_gateway"|
      }

      gateway = make_gateway("xor1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"type" => "should_be_ignored"})

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskA"]
    end

    test "condition referencing this.id resolves to the gateway's BPMN id" do
      target = make_target("taskA")
      target_default = make_target("taskDefault")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "my-xor",
        target_ref: "taskA",
        condition_expression: ~s|this.id = "my-xor"|
      }

      sf_default = %SequenceFlow{
        id: "sf-default",
        source_ref: "my-xor",
        target_ref: "taskDefault",
        is_default: true
      }

      gateway = make_gateway("my-xor", outgoing: ["sf-a", "sf-default"])
      context = make_context(gateway, [sf_a, sf_default], [target, target_default])
      token = make_token(%{"id" => "not-the-gateway-id"})

      assert {:ok, %FlowNodeResult{} = result} =
               ExclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskA"]
    end
  end
end
