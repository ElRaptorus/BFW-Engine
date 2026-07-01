defmodule EvilEngine.Execution.ComplexJoinEvaluatorTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.ComplexJoinEvaluator
  alias EvilEngine.Execution.ProcessInstance.State

  # A minimal process: A -> J, B -> J, J is the complex join.
  defp build_process(activation_condition) do
    join =
      %FlowNode{
        id: "J",
        type: :complex_gateway,
        type_data: %FlowNodeData.ComplexGateway{activation_condition: activation_condition},
        incoming: ["sf1", "sf2"],
        outgoing: ["sf_out"]
      }

    %BpmnProcess{
      id: "proc-1",
      flow_nodes: [
        join,
        %FlowNode{id: "A", type: :task, type_data: %FlowNodeData.Task{}},
        %FlowNode{id: "B", type: :task, type_data: %FlowNodeData.Task{}}
      ],
      sequence_flows: [
        %SequenceFlow{id: "sf1", source_ref: "A", target_ref: "J"},
        %SequenceFlow{id: "sf2", source_ref: "B", target_ref: "J"},
        %SequenceFlow{id: "sf_out", source_ref: "J", target_ref: "End"}
      ]
    }
  end

  defp build_state(process, fni_states) do
    %State{
      process_instance_id: "pi-1",
      process_version_id: "pv-1",
      process_model: process,
      identity: %{id: "user-1"},
      started_with_context: %{},
      data_object_cache: %{},
      flow_node_instance_states: fni_states
    }
  end

  defp join_flow_node(process), do: Enum.find(process.flow_nodes, &(&1.id == "J"))

  defp routing(arrived_flow_ids, payload \\ %{}) do
    %{
      fni_id: "join-fni",
      gateway_type: :complex_gateway,
      required: 2,
      arrived_via_flow_ids: MapSet.new(arrived_flow_ids),
      activation_condition: nil,
      merged_payload: payload,
      fired: false
    }
  end

  describe "fire" do
    test "fires when the activation condition is met" do
      process = build_process("activatedCount >= 2")
      state = build_state(process, %{})

      assert :fire =
               ComplexJoinEvaluator.evaluate(join_flow_node(process), routing(["sf1", "sf2"]), state)
    end

    test "fires when a token-based condition is met" do
      process = build_process("activatedCount >= 1 and token.approved = true")
      state = build_state(process, %{})

      assert :fire =
               ComplexJoinEvaluator.evaluate(
                 join_flow_node(process),
                 routing(["sf1"], %{"approved" => true}),
                 state
               )
    end
  end

  describe "wait" do
    test "waits when the condition is unmet and an upstream branch is still live" do
      process = build_process("activatedCount >= 2")

      # B is still active → sf2's upstream is live → not resolved.
      fni_states = %{
        "fni-b" => %{flow_node_id: "B", state: :active}
      }

      state = build_state(process, fni_states)

      assert :wait =
               ComplexJoinEvaluator.evaluate(join_flow_node(process), routing(["sf1"]), state)
    end
  end

  describe "error (Twist 1 — all branches resolved, condition unmet)" do
    test "errors when all branches are arrived-or-dead but the condition is still false" do
      process = build_process("activatedCount >= 2")

      # No live FNIs → sf2 (from B) is dead; sf1 arrived → all resolved.
      state = build_state(process, %{})

      assert {:error, {:complex_join_condition_unmet, detail}} =
               ComplexJoinEvaluator.evaluate(join_flow_node(process), routing(["sf1"]), state)

      assert detail.flow_node_id == "J"
      assert detail.activated_count == 1
      assert detail.incoming_count == 2
      assert detail.activation_condition == "activatedCount >= 2"
    end
  end

  describe "error (FEEL evaluation failure)" do
    test "errors on a blank activation condition" do
      process = build_process("")
      state = build_state(process, %{})

      assert {:error, {:complex_join_condition_failed, detail}} =
               ComplexJoinEvaluator.evaluate(join_flow_node(process), routing(["sf1"]), state)

      assert detail.flow_node_id == "J"
    end

    test "errors on a malformed FEEL expression" do
      process = build_process("@@ not valid feel !!")
      state = build_state(process, %{})

      assert {:error, {:complex_join_condition_failed, _detail}} =
               ComplexJoinEvaluator.evaluate(join_flow_node(process), routing(["sf1"]), state)
    end
  end
end
