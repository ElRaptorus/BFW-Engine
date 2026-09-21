defmodule BfwEngine.BPMN.ComplexRegionAnalysisTest do
  use ExUnit.Case, async: true

  alias BfwEngine.BPMN.ComplexRegionAnalysis
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow

  defp build_process(flow_nodes, sequence_flows) do
    %BpmnProcess{
      id: "test",
      flow_nodes: flow_nodes,
      sequence_flows: sequence_flows
    }
  end

  defp start_event(id, outgoing) do
    %FlowNode{
      id: id,
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{},
      incoming: [],
      outgoing: outgoing
    }
  end

  defp end_event(id, incoming) do
    %FlowNode{
      id: id,
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{},
      incoming: incoming,
      outgoing: []
    }
  end

  defp task(id, incoming, outgoing) do
    %FlowNode{
      id: id,
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: incoming,
      outgoing: outgoing
    }
  end

  defp complex_gateway(id, incoming, outgoing, activation_condition \\ nil) do
    %FlowNode{
      id: id,
      type: :complex_gateway,
      type_data: %FlowNodeData.ComplexGateway{activation_condition: activation_condition},
      incoming: incoming,
      outgoing: outgoing
    }
  end

  defp parallel_gateway(id, incoming, outgoing) do
    %FlowNode{
      id: id,
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: incoming,
      outgoing: outgoing
    }
  end

  defp flow(id, source_ref, target_ref) do
    %SequenceFlow{id: id, source_ref: source_ref, target_ref: target_ref}
  end

  describe "analyze/1 — simple complex split/join pair" do
    setup do
      flow_nodes = [
        start_event("Start_1", ["Flow_1"]),
        complex_gateway("ComplexSplit", ["Flow_1"], ["Flow_2", "Flow_3"]),
        task("TaskA", ["Flow_2"], ["Flow_4"]),
        task("TaskB", ["Flow_3"], ["Flow_5"]),
        complex_gateway("ComplexJoin", ["Flow_4", "Flow_5"], ["Flow_6"], "activatedCount >= 2"),
        end_event("End_1", ["Flow_6"])
      ]

      sequence_flows = [
        flow("Flow_1", "Start_1", "ComplexSplit"),
        flow("Flow_2", "ComplexSplit", "TaskA"),
        flow("Flow_3", "ComplexSplit", "TaskB"),
        flow("Flow_4", "TaskA", "ComplexJoin"),
        flow("Flow_5", "TaskB", "ComplexJoin"),
        flow("Flow_6", "ComplexJoin", "End_1")
      ]

      %{process: build_process(flow_nodes, sequence_flows)}
    end

    test "pairs the join to the dominating split and computes the between-region", %{
      process: process
    } do
      analyses = ComplexRegionAnalysis.analyze(process)

      assert map_size(analyses) == 1
      assert %ComplexRegionAnalysis{} = analysis = analyses["ComplexJoin"]
      assert analysis.join_flow_node_id == "ComplexJoin"
      assert analysis.split_flow_node_id == "ComplexSplit"
      assert analysis.region_node_ids == MapSet.new(["TaskA", "TaskB"])
      assert analysis.incoming_flow_ids == ["Flow_4", "Flow_5"]
    end

    test "reports no region violations for a well-formed pair", %{process: process} do
      assert ComplexRegionAnalysis.region_violations(process) == []
    end

    test "enrich_process/1 populates complex_region_analyses", %{process: process} do
      enriched = ComplexRegionAnalysis.enrich_process(process)

      assert enriched.complex_region_analyses == ComplexRegionAnalysis.analyze(process)

      assert enriched.complex_region_analyses["ComplexJoin"].region_node_ids ==
               MapSet.new(["TaskA", "TaskB"])
    end
  end

  describe "analyze/1 — nested complex regions" do
    setup do
      flow_nodes = [
        start_event("Start_1", ["Flow_1"]),
        complex_gateway("OuterSplit", ["Flow_1"], ["Flow_2", "Flow_3"]),
        complex_gateway("InnerSplit", ["Flow_2"], ["Flow_4", "Flow_5"]),
        task("TaskA", ["Flow_4"], ["Flow_6"]),
        task("TaskB", ["Flow_5"], ["Flow_7"]),
        complex_gateway("InnerJoin", ["Flow_6", "Flow_7"], ["Flow_8"], "activatedCount >= 1"),
        task("TaskC", ["Flow_3"], ["Flow_9"]),
        complex_gateway("OuterJoin", ["Flow_8", "Flow_9"], ["Flow_10"], "activatedCount >= 1"),
        end_event("End_1", ["Flow_10"])
      ]

      sequence_flows = [
        flow("Flow_1", "Start_1", "OuterSplit"),
        flow("Flow_2", "OuterSplit", "InnerSplit"),
        flow("Flow_3", "OuterSplit", "TaskC"),
        flow("Flow_4", "InnerSplit", "TaskA"),
        flow("Flow_5", "InnerSplit", "TaskB"),
        flow("Flow_6", "TaskA", "InnerJoin"),
        flow("Flow_7", "TaskB", "InnerJoin"),
        flow("Flow_8", "InnerJoin", "OuterJoin"),
        flow("Flow_9", "TaskC", "OuterJoin"),
        flow("Flow_10", "OuterJoin", "End_1")
      ]

      %{process: build_process(flow_nodes, sequence_flows)}
    end

    test "pairs each join to its nearest dominating split", %{process: process} do
      analyses = ComplexRegionAnalysis.analyze(process)

      assert map_size(analyses) == 2
      assert analyses["InnerJoin"].split_flow_node_id == "InnerSplit"
      assert analyses["OuterJoin"].split_flow_node_id == "OuterSplit"
    end

    test "inner region is strictly contained in the outer region", %{process: process} do
      analyses = ComplexRegionAnalysis.analyze(process)

      inner = analyses["InnerJoin"].region_node_ids
      outer = analyses["OuterJoin"].region_node_ids

      assert inner == MapSet.new(["TaskA", "TaskB"])
      assert outer == MapSet.new(["InnerSplit", "TaskA", "TaskB", "InnerJoin", "TaskC"])
      assert MapSet.subset?(inner, outer)
      refute MapSet.equal?(inner, outer)
    end

    test "reports no region violations for well-formed nesting", %{process: process} do
      assert ComplexRegionAnalysis.region_violations(process) == []
    end
  end

  describe "region_violations/1 — cross-boundary edge" do
    test "rejects a flow that leaks out of the region toward an external node" do
      flow_nodes = [
        start_event("Start_1", ["Flow_1"]),
        complex_gateway("ComplexSplit", ["Flow_1"], ["Flow_2", "Flow_3"]),
        task("TaskA", ["Flow_2"], ["Flow_4", "Flow_leak"]),
        task("TaskB", ["Flow_3"], ["Flow_5"]),
        complex_gateway("ComplexJoin", ["Flow_4", "Flow_5"], ["Flow_6"], "activatedCount >= 2"),
        end_event("End_1", ["Flow_6"]),
        end_event("End_leak", ["Flow_leak"])
      ]

      sequence_flows = [
        flow("Flow_1", "Start_1", "ComplexSplit"),
        flow("Flow_2", "ComplexSplit", "TaskA"),
        flow("Flow_3", "ComplexSplit", "TaskB"),
        flow("Flow_4", "TaskA", "ComplexJoin"),
        flow("Flow_5", "TaskB", "ComplexJoin"),
        flow("Flow_6", "ComplexJoin", "End_1"),
        flow("Flow_leak", "TaskA", "End_leak")
      ]

      process = build_process(flow_nodes, sequence_flows)
      violations = ComplexRegionAnalysis.region_violations(process)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :complex_region_cross_boundary
             end)

      refute Map.has_key?(ComplexRegionAnalysis.analyze(process), "ComplexJoin")
    end
  end

  describe "region_violations/1 — unpaired join (zero dominating split)" do
    test "rejects a complex join with no dominating complex split" do
      flow_nodes = [
        start_event("Start_1", ["Flow_1"]),
        parallel_gateway("ParSplit", ["Flow_1"], ["Flow_2", "Flow_3"]),
        task("TaskA", ["Flow_2"], ["Flow_4"]),
        task("TaskB", ["Flow_3"], ["Flow_5"]),
        complex_gateway("ComplexJoin", ["Flow_4", "Flow_5"], ["Flow_6"], "activatedCount >= 2"),
        end_event("End_1", ["Flow_6"])
      ]

      sequence_flows = [
        flow("Flow_1", "Start_1", "ParSplit"),
        flow("Flow_2", "ParSplit", "TaskA"),
        flow("Flow_3", "ParSplit", "TaskB"),
        flow("Flow_4", "TaskA", "ComplexJoin"),
        flow("Flow_5", "TaskB", "ComplexJoin"),
        flow("Flow_6", "ComplexJoin", "End_1")
      ]

      process = build_process(flow_nodes, sequence_flows)
      violations = ComplexRegionAnalysis.region_violations(process)

      assert Enum.any?(violations, fn {code, _message} ->
               code == :complex_join_no_paired_split
             end)

      assert ComplexRegionAnalysis.analyze(process) == %{}
    end
  end
end
