defmodule BfwEngine.Execution.FlowNodes.InclusiveGatewayTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.InclusiveGateway
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
      type: :inclusive_gateway,
      type_data: %FlowNodeData.InclusiveGateway{
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

  describe "split — both conditions truthy (fork)" do
    test "activates all truthy paths" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "token.amount > 10"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "inc1",
        target_ref: "taskB",
        condition_expression: "token.amount > 5"
      }

      gateway = make_gateway("inc1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 50})

      assert {:ok, %FlowNodeResult{} = result} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert Enum.sort(result.next_flow_node_ids) == ["taskA", "taskB"]
      assert result.output_payload == token.payload
    end
  end

  describe "split — one of two conditions truthy" do
    test "activates only the truthy path" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "token.amount > 100"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "inc1",
        target_ref: "taskB",
        condition_expression: "token.amount > 5"
      }

      gateway = make_gateway("inc1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"amount" => 50})

      assert {:ok, %FlowNodeResult{} = result} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskB"]
    end
  end

  describe "split — default flow fallback" do
    test "falls back to default when no conditions are truthy" do
      target_a = make_target("taskA")
      target_default = make_target("taskDefault")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1000"
      }

      sf_default = %SequenceFlow{
        id: "sf-default",
        source_ref: "inc1",
        target_ref: "taskDefault",
        is_default: true
      }

      gateway = make_gateway("inc1", outgoing: ["sf-a", "sf-default"])
      context = make_context(gateway, [sf_a, sf_default], [target_a, target_default])
      token = make_token(%{"amount" => 5})

      assert {:ok, %FlowNodeResult{} = result} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskDefault"]
    end
  end

  describe "split — no matching condition, no default (fatal)" do
    test "returns error when no condition is truthy and no default exists" do
      target_a = make_target("taskA")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1000"
      }

      gateway = make_gateway("inc1", outgoing: ["sf-a"])
      context = make_context(gateway, [sf_a], [target_a])
      token = make_token(%{"amount" => 5})

      assert {:error, %{reason: :no_matching_condition}} =
               InclusiveGateway.handle_enter(gateway, token, context)
    end
  end

  describe "split — unconditional flows" do
    test "unconditional non-default flows are activated alongside truthy conditionals" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "token.x = true"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "inc1",
        target_ref: "taskB"
      }

      gateway = make_gateway("inc1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token(%{"x" => true})

      assert {:ok, %FlowNodeResult{} = result} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert Enum.sort(result.next_flow_node_ids) == ["taskA", "taskB"]
    end
  end

  describe "split — expression evaluation failure" do
    test "returns error when a FEEL expression has syntax errors" do
      target_a = make_target("taskA")

      sf_a = %SequenceFlow{
        id: "sf-broken",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "this is not valid FEEL @@!!"
      }

      gateway = make_gateway("inc1", outgoing: ["sf-broken"])
      context = make_context(gateway, [sf_a], [target_a])
      token = make_token(%{"amount" => 50})

      assert {:error, %{reason: :expression_evaluation_failed} = error} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert error.sequence_flow_id == "sf-broken"
      assert error.message =~ "Failed to evaluate condition"
    end
  end

  describe "join — converging gateway" do
    test "returns async tuple for join gateway" do
      target = make_target("taskAfterJoin")

      sf_out = %SequenceFlow{
        id: "sf-out",
        source_ref: "inc-join",
        target_ref: "taskAfterJoin"
      }

      gateway =
        make_gateway("inc-join",
          incoming: ["sf-in-1", "sf-in-2"],
          outgoing: ["sf-out"]
        )

      context = make_context(gateway, [sf_out], [target])
      token = make_token(%{"merged" => true})

      assert {:async, "fni-1", continuation, %{join_gateway: true}} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert is_function(continuation, 0)
    end
  end

  describe "mixed gateway rejection" do
    test "returns error when gateway has >1 incoming AND >1 outgoing" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc-mixed",
        target_ref: "taskA",
        condition_expression: "true"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "inc-mixed",
        target_ref: "taskB",
        condition_expression: "false"
      }

      gateway =
        make_gateway("inc-mixed",
          incoming: ["sf-in-1", "sf-in-2"],
          outgoing: ["sf-a", "sf-b"]
        )

      context = make_context(gateway, [sf_a, sf_b], [target_a, target_b])
      token = make_token()

      assert {:error, %{reason: :mixed_gateway} = error} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert error.incoming_count == 2
      assert error.outgoing_count == 2
      assert error.message =~ "Mixed gateway"
    end
  end

  describe "split — three branches, two truthy" do
    test "activates two out of three paths" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")
      target_c = make_target("taskC")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "token.a = true"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "inc1",
        target_ref: "taskB",
        condition_expression: "token.b = true"
      }

      sf_c = %SequenceFlow{
        id: "sf-c",
        source_ref: "inc1",
        target_ref: "taskC",
        condition_expression: "token.c = true"
      }

      gateway = make_gateway("inc1", outgoing: ["sf-a", "sf-b", "sf-c"])

      context =
        make_context(gateway, [sf_a, sf_b, sf_c], [target_a, target_b, target_c])

      token = make_token(%{"a" => true, "b" => true, "c" => false})

      assert {:ok, %FlowNodeResult{} = result} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert Enum.sort(result.next_flow_node_ids) == ["taskA", "taskB"]
    end
  end

  describe "split — default with unconditional when zero truthy" do
    test "activates only default when conditional is false and unconditional+default exist" do
      target_a = make_target("taskA")
      target_b = make_target("taskB")
      target_default = make_target("taskDefault")

      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "inc1",
        target_ref: "taskA",
        condition_expression: "token.a = true"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "inc1",
        target_ref: "taskB"
      }

      sf_default = %SequenceFlow{
        id: "sf-default",
        source_ref: "inc1",
        target_ref: "taskDefault",
        is_default: true
      }

      gateway = make_gateway("inc1", outgoing: ["sf-a", "sf-b", "sf-default"])

      context =
        make_context(
          gateway,
          [sf_a, sf_b, sf_default],
          [target_a, target_b, target_default]
        )

      token = make_token(%{"a" => false})

      assert {:ok, %FlowNodeResult{} = result} =
               InclusiveGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskDefault"]
    end
  end
end
