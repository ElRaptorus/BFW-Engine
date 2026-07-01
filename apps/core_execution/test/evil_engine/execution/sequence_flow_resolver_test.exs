defmodule EvilEngine.Execution.SequenceFlowResolverTest do
  @moduledoc """
  Unit tests for `SequenceFlowResolver`.

  Since the handler-owned routing refactor, `SequenceFlowResolver` is
  called by individual `FlowNodeHandler` implementations (not the PI
  directly) to determine their `next_flow_node_ids`. Gateway split
  handlers (e.g. `ExclusiveGateway`) implement their own condition
  evaluation and do not use this module for the split path.
  """
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.SequenceFlowResolver

  defp make_node(id, type, opts \\ []) do
    type_data = Keyword.get(opts, :type_data, %FlowNodeData.Task{})
    outgoing = Keyword.get(opts, :outgoing, [])

    %FlowNode{
      id: id,
      type: type,
      type_data: type_data,
      outgoing: outgoing
    }
  end

  defp make_flow(id, source, target, opts \\ []) do
    %SequenceFlow{
      id: id,
      source_ref: source,
      target_ref: target,
      condition_expression: Keyword.get(opts, :condition),
      is_default: Keyword.get(opts, :is_default, false)
    }
  end

  defp make_process(nodes, flows) do
    %BpmnProcess{
      id: "test-process",
      flow_nodes: nodes,
      sequence_flows: flows
    }
  end

  describe "implicit split detection" do
    test "non-gateway with >1 outgoing returns :implicit_split" do
      task = make_node("task1", :task, outgoing: ["f1", "f2"])
      target1 = make_node("t1", :task)
      target2 = make_node("t2", :task)
      f1 = make_flow("f1", "task1", "t1")
      f2 = make_flow("f2", "task1", "t2")

      process = make_process([task, target1, target2], [f1, f2])

      assert {:error, :implicit_split, meta} = SequenceFlowResolver.resolve(task, process)
      assert meta.flow_node_id == "task1"
      assert meta.outgoing_count == 2
    end

    test "gateway with >1 outgoing does NOT trigger implicit_split" do
      gateway =
        make_node("gw1", :exclusive_gateway,
          outgoing: ["f1", "f2"],
          type_data: %FlowNodeData.ExclusiveGateway{}
        )

      target1 = make_node("t1", :task)
      target2 = make_node("t2", :task)
      f1 = make_flow("f1", "gw1", "t1")
      f2 = make_flow("f2", "gw1", "t2")

      process = make_process([gateway, target1, target2], [f1, f2])

      assert {:ok, _targets} = SequenceFlowResolver.resolve(gateway, process)
    end
  end

  describe "dead end detection" do
    test "non-End-Event with 0 outgoing returns :dead_end" do
      task = make_node("task1", :task, outgoing: [])
      process = make_process([task], [])

      assert {:error, :dead_end, meta} = SequenceFlowResolver.resolve(task, process)
      assert meta.flow_node_id == "task1"
    end
  end

  describe "End Event with 0 outgoing" do
    test "returns {:ok, []}" do
      end_event =
        make_node("end1", :end_event,
          outgoing: [],
          type_data: %FlowNodeData.EndEvent{}
        )

      process = make_process([end_event], [])

      assert {:ok, []} = SequenceFlowResolver.resolve(end_event, process)
    end
  end

  describe "single unconditional outgoing" do
    test "returns {:ok, [target]}" do
      task = make_node("task1", :task, outgoing: ["f1"])
      end_event = make_node("end1", :end_event, type_data: %FlowNodeData.EndEvent{})
      f1 = make_flow("f1", "task1", "end1")

      process = make_process([task, end_event], [f1])

      assert {:ok, [target]} = SequenceFlowResolver.resolve(task, process)
      assert target.id == "end1"
    end
  end

  describe "non-Gateway sources ignore condition + default flags" do
    test "single outgoing flow with condition is followed unconditionally" do
      task = make_node("task1", :task, outgoing: ["f1"])
      target = make_node("t1", :task)
      f1 = make_flow("f1", "task1", "t1", condition: "token.amount > 100")

      process = make_process([task, target], [f1])

      assert {:ok, [result]} = SequenceFlowResolver.resolve(task, process)
      assert result.id == "t1"
    end

    test "single outgoing flow with is_default flag is followed regardless" do
      task = make_node("task1", :task, outgoing: ["f1"])
      target = make_node("t1", :task)
      f1 = make_flow("f1", "task1", "t1", is_default: true)

      process = make_process([task, target], [f1])

      assert {:ok, [result]} = SequenceFlowResolver.resolve(task, process)
      assert result.id == "t1"
    end

    test "single outgoing flow with both condition and is_default is followed" do
      task = make_node("task1", :task, outgoing: ["f1"])
      target = make_node("t1", :task)
      f1 = make_flow("f1", "task1", "t1", condition: "token.amount > 100", is_default: true)

      process = make_process([task, target], [f1])

      assert {:ok, [result]} = SequenceFlowResolver.resolve(task, process)
      assert result.id == "t1"
    end

    test "End Event with conditional outgoing flow follows it unconditionally" do
      end_event =
        make_node("end1", :end_event,
          outgoing: ["f1"],
          type_data: %FlowNodeData.EndEvent{}
        )

      target = make_node("t1", :task)
      f1 = make_flow("f1", "end1", "t1", condition: "token.amount > 100")

      process = make_process([end_event, target], [f1])

      assert {:ok, [result]} = SequenceFlowResolver.resolve(end_event, process)
      assert result.id == "t1"
    end

    test "Gateway-join with conditional single outgoing flow follows it unconditionally" do
      gateway_join =
        make_node("gw1", :exclusive_gateway,
          outgoing: ["f1"],
          type_data: %FlowNodeData.ExclusiveGateway{}
        )

      target = make_node("t1", :task)
      f1 = make_flow("f1", "gw1", "t1", condition: "token.amount > 100")

      process = make_process([gateway_join, target], [f1])

      assert {:ok, [result]} = SequenceFlowResolver.resolve(gateway_join, process)
      assert result.id == "t1"
    end
  end
end
