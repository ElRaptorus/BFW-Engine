defmodule EvilEngine.BPMN.InclusiveJoinAnalysisTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.InclusiveJoinAnalysis
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow

  defp build_process(flow_nodes, sequence_flows) do
    %BpmnProcess{
      id: "test",
      flow_nodes: flow_nodes,
      sequence_flows: sequence_flows,
      inclusive_join_analyses: %{}
    }
  end

  defp build_incoming_index(sequence_flows) do
    Enum.reduce(sequence_flows, %{}, fn flow, accumulator ->
      Map.update(accumulator, flow.target_ref, [flow.source_ref], &[flow.source_ref | &1])
    end)
  end

  describe "analyze/1 — simple split-join backward reachability" do
    test "computes upstream sets for each incoming flow at the inclusive join" do
      flow_nodes = [
        %FlowNode{
          id: "Start_1",
          type: :start_event,
          type_data: %FlowNodeData.StartEvent{},
          incoming: [],
          outgoing: ["Flow_1"]
        },
        %FlowNode{
          id: "IncSplit",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_1"],
          outgoing: ["Flow_2", "Flow_3"]
        },
        %FlowNode{
          id: "TaskA",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_2"],
          outgoing: ["Flow_4"]
        },
        %FlowNode{
          id: "TaskB",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_3"],
          outgoing: ["Flow_5"]
        },
        %FlowNode{
          id: "IncJoin",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_4", "Flow_5"],
          outgoing: ["Flow_6"]
        },
        %FlowNode{
          id: "End_1",
          type: :end_event,
          type_data: %FlowNodeData.EndEvent{},
          incoming: ["Flow_6"],
          outgoing: []
        }
      ]

      sequence_flows = [
        %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "IncSplit"},
        %SequenceFlow{id: "Flow_2", source_ref: "IncSplit", target_ref: "TaskA"},
        %SequenceFlow{id: "Flow_3", source_ref: "IncSplit", target_ref: "TaskB"},
        %SequenceFlow{id: "Flow_4", source_ref: "TaskA", target_ref: "IncJoin"},
        %SequenceFlow{id: "Flow_5", source_ref: "TaskB", target_ref: "IncJoin"},
        %SequenceFlow{id: "Flow_6", source_ref: "IncJoin", target_ref: "End_1"}
      ]

      process = build_process(flow_nodes, sequence_flows)
      analyses = InclusiveJoinAnalysis.analyze(process)

      assert map_size(analyses) == 1
      assert %InclusiveJoinAnalysis{} = analysis = analyses["IncJoin"]
      assert analysis.join_flow_node_id == "IncJoin"
      assert analysis.incoming_flow_ids == ["Flow_4", "Flow_5"]

      assert MapSet.new(["TaskA", "IncSplit", "Start_1"]) ==
               analysis.upstream_reachability["Flow_4"]

      assert MapSet.new(["TaskB", "IncSplit", "Start_1"]) ==
               analysis.upstream_reachability["Flow_5"]
    end
  end

  describe "analyze/1 — nested gateways reachability" do
    test "upstream sets for the inclusive join include parallel gateway nodes" do
      flow_nodes = [
        %FlowNode{
          id: "Start_1",
          type: :start_event,
          type_data: %FlowNodeData.StartEvent{},
          incoming: [],
          outgoing: ["Flow_1"]
        },
        %FlowNode{
          id: "IncSplit",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_1"],
          outgoing: ["Flow_2", "Flow_3"]
        },
        %FlowNode{
          id: "ParSplit",
          type: :parallel_gateway,
          type_data: %FlowNodeData.ParallelGateway{},
          incoming: ["Flow_2"],
          outgoing: ["Flow_4"]
        },
        %FlowNode{
          id: "TaskP1",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_4"],
          outgoing: ["Flow_5"]
        },
        %FlowNode{
          id: "ParJoin",
          type: :parallel_gateway,
          type_data: %FlowNodeData.ParallelGateway{},
          incoming: ["Flow_5"],
          outgoing: ["Flow_6"]
        },
        %FlowNode{
          id: "TaskB",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_3"],
          outgoing: ["Flow_7"]
        },
        %FlowNode{
          id: "IncJoin",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_6", "Flow_7"],
          outgoing: ["Flow_8"]
        },
        %FlowNode{
          id: "End_1",
          type: :end_event,
          type_data: %FlowNodeData.EndEvent{},
          incoming: ["Flow_8"],
          outgoing: []
        }
      ]

      sequence_flows = [
        %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "IncSplit"},
        %SequenceFlow{id: "Flow_2", source_ref: "IncSplit", target_ref: "ParSplit"},
        %SequenceFlow{id: "Flow_3", source_ref: "IncSplit", target_ref: "TaskB"},
        %SequenceFlow{id: "Flow_4", source_ref: "ParSplit", target_ref: "TaskP1"},
        %SequenceFlow{id: "Flow_5", source_ref: "TaskP1", target_ref: "ParJoin"},
        %SequenceFlow{id: "Flow_6", source_ref: "ParJoin", target_ref: "IncJoin"},
        %SequenceFlow{id: "Flow_7", source_ref: "TaskB", target_ref: "IncJoin"},
        %SequenceFlow{id: "Flow_8", source_ref: "IncJoin", target_ref: "End_1"}
      ]

      process = build_process(flow_nodes, sequence_flows)
      analysis = InclusiveJoinAnalysis.analyze(process)["IncJoin"]

      assert MapSet.new(["ParJoin", "TaskP1", "ParSplit", "IncSplit", "Start_1"]) ==
               analysis.upstream_reachability["Flow_6"]

      assert MapSet.new(["TaskB", "IncSplit", "Start_1"]) ==
               analysis.upstream_reachability["Flow_7"]
    end
  end

  describe "backward_reachability_bfs/3 — cycle handling" do
    test "terminates and returns correct nodes when the graph contains a loop" do
      sequence_flows = [
        %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "TaskA"},
        %SequenceFlow{id: "Flow_2", source_ref: "TaskA", target_ref: "TaskB"},
        %SequenceFlow{id: "Flow_3", source_ref: "TaskB", target_ref: "TaskA"},
        %SequenceFlow{id: "Flow_4", source_ref: "TaskB", target_ref: "IncJoin"},
        %SequenceFlow{id: "Flow_5", source_ref: "Start_1", target_ref: "IncJoin"}
      ]

      incoming_index = build_incoming_index(sequence_flows)

      reachable_from_task_b =
        InclusiveJoinAnalysis.backward_reachability_bfs("TaskB", "IncJoin", incoming_index)

      assert MapSet.new(["TaskB", "TaskA", "Start_1"]) == reachable_from_task_b

      reachable_from_start =
        InclusiveJoinAnalysis.backward_reachability_bfs("Start_1", "IncJoin", incoming_index)

      assert MapSet.new(["Start_1"]) == reachable_from_start
    end
  end

  describe "analyze/1 — no inclusive joins in model" do
    test "returns an empty map when the process has only exclusive and parallel gateways" do
      flow_nodes = [
        %FlowNode{
          id: "Start_1",
          type: :start_event,
          type_data: %FlowNodeData.StartEvent{},
          incoming: [],
          outgoing: ["Flow_1"]
        },
        %FlowNode{
          id: "ExcSplit",
          type: :exclusive_gateway,
          type_data: %FlowNodeData.ExclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_1"],
          outgoing: ["Flow_2", "Flow_3"]
        },
        %FlowNode{
          id: "ParSplit",
          type: :parallel_gateway,
          type_data: %FlowNodeData.ParallelGateway{},
          incoming: ["Flow_2"],
          outgoing: ["Flow_4", "Flow_5"]
        },
        %FlowNode{
          id: "TaskA",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_4"],
          outgoing: ["Flow_6"]
        },
        %FlowNode{
          id: "TaskB",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_5"],
          outgoing: ["Flow_7"]
        },
        %FlowNode{
          id: "ParJoin",
          type: :parallel_gateway,
          type_data: %FlowNodeData.ParallelGateway{},
          incoming: ["Flow_6", "Flow_7"],
          outgoing: ["Flow_8"]
        },
        %FlowNode{
          id: "ExcJoin",
          type: :exclusive_gateway,
          type_data: %FlowNodeData.ExclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_3", "Flow_8"],
          outgoing: ["Flow_9"]
        },
        %FlowNode{
          id: "End_1",
          type: :end_event,
          type_data: %FlowNodeData.EndEvent{},
          incoming: ["Flow_9"],
          outgoing: []
        }
      ]

      sequence_flows = [
        %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "ExcSplit"},
        %SequenceFlow{id: "Flow_2", source_ref: "ExcSplit", target_ref: "ParSplit"},
        %SequenceFlow{id: "Flow_3", source_ref: "ExcSplit", target_ref: "ExcJoin"},
        %SequenceFlow{id: "Flow_4", source_ref: "ParSplit", target_ref: "TaskA"},
        %SequenceFlow{id: "Flow_5", source_ref: "ParSplit", target_ref: "TaskB"},
        %SequenceFlow{id: "Flow_6", source_ref: "TaskA", target_ref: "ParJoin"},
        %SequenceFlow{id: "Flow_7", source_ref: "TaskB", target_ref: "ParJoin"},
        %SequenceFlow{id: "Flow_8", source_ref: "ParJoin", target_ref: "ExcJoin"},
        %SequenceFlow{id: "Flow_9", source_ref: "ExcJoin", target_ref: "End_1"}
      ]

      process = build_process(flow_nodes, sequence_flows)

      assert InclusiveJoinAnalysis.analyze(process) == %{}
    end
  end

  describe "analyze/1 — multiple inclusive joins" do
    test "returns a separate analysis entry for each inclusive join gateway" do
      flow_nodes = [
        %FlowNode{
          id: "Start_1",
          type: :start_event,
          type_data: %FlowNodeData.StartEvent{},
          incoming: [],
          outgoing: ["Flow_1"]
        },
        %FlowNode{
          id: "IncSplit1",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_1"],
          outgoing: ["Flow_2", "Flow_3"]
        },
        %FlowNode{
          id: "TaskA1",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_2"],
          outgoing: ["Flow_4"]
        },
        %FlowNode{
          id: "TaskB1",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_3"],
          outgoing: ["Flow_5"]
        },
        %FlowNode{
          id: "IncJoin1",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_4", "Flow_5"],
          outgoing: ["Flow_6"]
        },
        %FlowNode{
          id: "IncSplit2",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_6"],
          outgoing: ["Flow_7", "Flow_8"]
        },
        %FlowNode{
          id: "TaskA2",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_7"],
          outgoing: ["Flow_9"]
        },
        %FlowNode{
          id: "TaskB2",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_8"],
          outgoing: ["Flow_10"]
        },
        %FlowNode{
          id: "IncJoin2",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_9", "Flow_10"],
          outgoing: ["Flow_11"]
        },
        %FlowNode{
          id: "End_1",
          type: :end_event,
          type_data: %FlowNodeData.EndEvent{},
          incoming: ["Flow_11"],
          outgoing: []
        }
      ]

      sequence_flows = [
        %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "IncSplit1"},
        %SequenceFlow{id: "Flow_2", source_ref: "IncSplit1", target_ref: "TaskA1"},
        %SequenceFlow{id: "Flow_3", source_ref: "IncSplit1", target_ref: "TaskB1"},
        %SequenceFlow{id: "Flow_4", source_ref: "TaskA1", target_ref: "IncJoin1"},
        %SequenceFlow{id: "Flow_5", source_ref: "TaskB1", target_ref: "IncJoin1"},
        %SequenceFlow{id: "Flow_6", source_ref: "IncJoin1", target_ref: "IncSplit2"},
        %SequenceFlow{id: "Flow_7", source_ref: "IncSplit2", target_ref: "TaskA2"},
        %SequenceFlow{id: "Flow_8", source_ref: "IncSplit2", target_ref: "TaskB2"},
        %SequenceFlow{id: "Flow_9", source_ref: "TaskA2", target_ref: "IncJoin2"},
        %SequenceFlow{id: "Flow_10", source_ref: "TaskB2", target_ref: "IncJoin2"},
        %SequenceFlow{id: "Flow_11", source_ref: "IncJoin2", target_ref: "End_1"}
      ]

      process = build_process(flow_nodes, sequence_flows)
      analyses = InclusiveJoinAnalysis.analyze(process)

      assert map_size(analyses) == 2
      assert Map.has_key?(analyses, "IncJoin1")
      assert Map.has_key?(analyses, "IncJoin2")

      assert analyses["IncJoin1"].join_flow_node_id == "IncJoin1"
      assert analyses["IncJoin1"].incoming_flow_ids == ["Flow_4", "Flow_5"]

      assert analyses["IncJoin2"].join_flow_node_id == "IncJoin2"
      assert analyses["IncJoin2"].incoming_flow_ids == ["Flow_9", "Flow_10"]
    end
  end

  describe "enrich_process/1" do
    test "populates inclusive_join_analyses on the process struct" do
      flow_nodes = [
        %FlowNode{
          id: "Start_1",
          type: :start_event,
          type_data: %FlowNodeData.StartEvent{},
          incoming: [],
          outgoing: ["Flow_1"]
        },
        %FlowNode{
          id: "IncSplit",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_1"],
          outgoing: ["Flow_2", "Flow_3"]
        },
        %FlowNode{
          id: "TaskA",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_2"],
          outgoing: ["Flow_4"]
        },
        %FlowNode{
          id: "TaskB",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Flow_3"],
          outgoing: ["Flow_5"]
        },
        %FlowNode{
          id: "IncJoin",
          type: :inclusive_gateway,
          type_data: %FlowNodeData.InclusiveGateway{default_flow_ref: nil},
          incoming: ["Flow_4", "Flow_5"],
          outgoing: ["Flow_6"]
        },
        %FlowNode{
          id: "End_1",
          type: :end_event,
          type_data: %FlowNodeData.EndEvent{},
          incoming: ["Flow_6"],
          outgoing: []
        }
      ]

      sequence_flows = [
        %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "IncSplit"},
        %SequenceFlow{id: "Flow_2", source_ref: "IncSplit", target_ref: "TaskA"},
        %SequenceFlow{id: "Flow_3", source_ref: "IncSplit", target_ref: "TaskB"},
        %SequenceFlow{id: "Flow_4", source_ref: "TaskA", target_ref: "IncJoin"},
        %SequenceFlow{id: "Flow_5", source_ref: "TaskB", target_ref: "IncJoin"},
        %SequenceFlow{id: "Flow_6", source_ref: "IncJoin", target_ref: "End_1"}
      ]

      process = build_process(flow_nodes, sequence_flows)
      expected_analyses = InclusiveJoinAnalysis.analyze(process)
      enriched_process = InclusiveJoinAnalysis.enrich_process(process)

      assert enriched_process.inclusive_join_analyses == expected_analyses
      assert map_size(enriched_process.inclusive_join_analyses) == 1
      assert enriched_process.inclusive_join_analyses["IncJoin"].join_flow_node_id == "IncJoin"
    end
  end
end
