defmodule EvilEngine.Execution.FlowNodes.ComplexGatewayTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes.ComplexGateway
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Types.Token

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
      type: :complex_gateway,
      type_data: %FlowNodeData.ComplexGateway{
        activation_condition: Keyword.get(opts, :activation_condition)
      },
      incoming: Keyword.get(opts, :incoming, ["sf-in"]),
      outgoing: Keyword.get(opts, :outgoing, [])
    }
  end

  defp make_target(id) do
    %FlowNode{id: id, type: :task, type_data: %FlowNodeData.Task{}}
  end

  defp make_context(gateway, sequence_flows, extra_nodes) do
    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [gateway | extra_nodes],
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
      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "cg1",
        target_ref: "taskA",
        condition_expression: "token.amount > 10"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "cg1",
        target_ref: "taskB",
        condition_expression: "token.amount > 5"
      }

      gateway = make_gateway("cg1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [make_target("taskA"), make_target("taskB")])
      token = make_token(%{"amount" => 50})

      assert {:ok, %FlowNodeResult{} = result} =
               ComplexGateway.handle_enter(gateway, token, context)

      assert Enum.sort(result.next_flow_node_ids) == ["taskA", "taskB"]
      assert result.output_payload == token.payload
    end
  end

  describe "split — one of two conditions truthy" do
    test "activates only the truthy path" do
      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "cg1",
        target_ref: "taskA",
        condition_expression: "token.amount > 100"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "cg1",
        target_ref: "taskB",
        condition_expression: "token.amount > 5"
      }

      gateway = make_gateway("cg1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [make_target("taskA"), make_target("taskB")])
      token = make_token(%{"amount" => 50})

      assert {:ok, %FlowNodeResult{} = result} =
               ComplexGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskB"]
    end
  end

  describe "split — default flow fallback" do
    test "falls back to default when no conditions are truthy" do
      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "cg1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1000"
      }

      sf_default = %SequenceFlow{
        id: "sf-default",
        source_ref: "cg1",
        target_ref: "taskDefault",
        is_default: true
      }

      gateway = make_gateway("cg1", outgoing: ["sf-a", "sf-default"])

      context =
        make_context(gateway, [sf_a, sf_default], [
          make_target("taskA"),
          make_target("taskDefault")
        ])

      token = make_token(%{"amount" => 5})

      assert {:ok, %FlowNodeResult{} = result} =
               ComplexGateway.handle_enter(gateway, token, context)

      assert result.next_flow_node_ids == ["taskDefault"]
    end
  end

  describe "split — no matching condition, no default (fatal)" do
    test "returns complex_split_no_matching_condition error" do
      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "cg1",
        target_ref: "taskA",
        condition_expression: "token.amount > 1000"
      }

      gateway = make_gateway("cg1", outgoing: ["sf-a"])
      context = make_context(gateway, [sf_a], [make_target("taskA")])
      token = make_token(%{"amount" => 5})

      assert {:error, {:complex_split_no_matching_condition, %{flow_node_id: "cg1"}}} =
               ComplexGateway.handle_enter(gateway, token, context)
    end
  end

  describe "split — unconditional non-default flows are a runtime fatal" do
    test "an unconditional non-default flow fatals even when a sibling condition is truthy" do
      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "cg1",
        target_ref: "taskA",
        condition_expression: "token.x = true"
      }

      sf_b = %SequenceFlow{id: "sf-b", source_ref: "cg1", target_ref: "taskB"}

      gateway = make_gateway("cg1", outgoing: ["sf-a", "sf-b"])
      context = make_context(gateway, [sf_a, sf_b], [make_target("taskA"), make_target("taskB")])
      token = make_token(%{"x" => true})

      assert {:error, {:complex_gateway_unconditional_flow, detail}} =
               ComplexGateway.handle_enter(gateway, token, context)

      assert detail.sequence_flow_id == "sf-b"
      assert detail.flow_node_id == "cg1"
    end
  end

  describe "split — expression evaluation failure" do
    test "returns complex_split_condition_failed on FEEL syntax error" do
      sf_a = %SequenceFlow{
        id: "sf-broken",
        source_ref: "cg1",
        target_ref: "taskA",
        condition_expression: "this is not valid FEEL @@!!"
      }

      gateway = make_gateway("cg1", outgoing: ["sf-broken"])
      context = make_context(gateway, [sf_a], [make_target("taskA")])
      token = make_token(%{"amount" => 50})

      assert {:error, {:complex_split_condition_failed, detail}} =
               ComplexGateway.handle_enter(gateway, token, context)

      assert detail.sequence_flow_id == "sf-broken"
      assert detail.flow_node_id == "cg1"
    end
  end

  describe "join — converging gateway" do
    test "returns async tuple for a join gateway" do
      sf_out = %SequenceFlow{id: "sf-out", source_ref: "cg-join", target_ref: "taskAfterJoin"}

      gateway =
        make_gateway("cg-join",
          activation_condition: "activatedCount >= 2",
          incoming: ["sf-in-1", "sf-in-2"],
          outgoing: ["sf-out"]
        )

      context = make_context(gateway, [sf_out], [make_target("taskAfterJoin")])
      token = make_token(%{"merged" => true})

      assert {:async, "fni-1", continuation, %{join_gateway: true}} =
               ComplexGateway.handle_enter(gateway, token, context)

      assert is_function(continuation, 0)
    end
  end

  describe "mixed gateway rejection" do
    test "returns mixed_gateway error when gateway has >1 incoming AND >1 outgoing" do
      sf_a = %SequenceFlow{
        id: "sf-a",
        source_ref: "cg-mixed",
        target_ref: "taskA",
        condition_expression: "true"
      }

      sf_b = %SequenceFlow{
        id: "sf-b",
        source_ref: "cg-mixed",
        target_ref: "taskB",
        condition_expression: "false"
      }

      gateway =
        make_gateway("cg-mixed",
          incoming: ["sf-in-1", "sf-in-2"],
          outgoing: ["sf-a", "sf-b"]
        )

      context = make_context(gateway, [sf_a, sf_b], [make_target("taskA"), make_target("taskB")])
      token = make_token()

      assert {:error, {:mixed_gateway, detail}} =
               ComplexGateway.handle_enter(gateway, token, context)

      assert detail.incoming_count == 2
      assert detail.outgoing_count == 2
    end
  end
end
