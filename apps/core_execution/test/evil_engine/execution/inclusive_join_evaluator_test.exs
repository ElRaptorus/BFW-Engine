defmodule EvilEngine.Execution.InclusiveJoinEvaluatorTest do
  use ExUnit.Case, async: true

  alias EvilEngine.BPMN.InclusiveJoinAnalysis
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.Execution.InclusiveJoinEvaluator

  @join_id "Join_1"

  defp make_task(flow_node_id) do
    %FlowNode{
      id: flow_node_id,
      type: :task,
      type_data: %FlowNodeData.Task{}
    }
  end

  defp make_start_event(flow_node_id) do
    %FlowNode{
      id: flow_node_id,
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{}
    }
  end

  defp make_split(flow_node_id) do
    %FlowNode{
      id: flow_node_id,
      type: :inclusive_gateway,
      type_data: %FlowNodeData.InclusiveGateway{},
      outgoing: ["Flow_A1", "Flow_B1"]
    }
  end

  defp make_join(incoming_flow_ids) do
    %FlowNode{
      id: @join_id,
      type: :inclusive_gateway,
      type_data: %FlowNodeData.InclusiveGateway{},
      incoming: incoming_flow_ids
    }
  end

  defp make_sequence_flow(flow_id, source_ref, target_ref) do
    %SequenceFlow{
      id: flow_id,
      source_ref: source_ref,
      target_ref: target_ref
    }
  end

  defp make_inclusive_join_analysis(incoming_flow_ids, upstream_reachability) do
    %InclusiveJoinAnalysis{
      join_flow_node_id: @join_id,
      incoming_flow_ids: incoming_flow_ids,
      upstream_reachability: upstream_reachability
    }
  end

  defp default_two_flow_analysis do
    make_inclusive_join_analysis(
      ["Flow_A2", "Flow_B2"],
      %{
        "Flow_A2" => MapSet.new(["Task_A", "Split_1", "Start_1"]),
        "Flow_B2" => MapSet.new(["Task_B", "Split_1", "Start_1"])
      }
    )
  end

  defp make_process_model(keyword_options \\ []) do
    flow_nodes = Keyword.get(keyword_options, :flow_nodes, [])
    sequence_flows = Keyword.get(keyword_options, :sequence_flows, [])

    inclusive_join_analyses =
      Keyword.get(
        keyword_options,
        :inclusive_join_analyses,
        %{@join_id => default_two_flow_analysis()}
      )

    %BpmnProcess{
      id: "test",
      flow_nodes: flow_nodes,
      sequence_flows: sequence_flows,
      inclusive_join_analyses: inclusive_join_analyses
    }
  end

  defp make_flow_node_instance_state(flow_node_id, state) do
    %{
      flow_node_id: flow_node_id,
      state: state
    }
  end

  defp should_fire?(
         arrived_flow_ids,
         flow_node_instance_states,
         process_model \\ make_process_model()
       ) do
    InclusiveJoinEvaluator.should_fire?(
      @join_id,
      MapSet.new(arrived_flow_ids),
      flow_node_instance_states,
      process_model
    )
  end

  defp two_branch_process_graph do
    start_event = make_start_event("Start_1")
    split = make_split("Split_1")
    task_a = make_task("Task_A")
    task_b = make_task("Task_B")
    join = make_join(["Flow_A2", "Flow_B2"])

    sequence_flows = [
      make_sequence_flow("Flow_Start", "Start_1", "Split_1"),
      make_sequence_flow("Flow_A1", "Split_1", "Task_A"),
      make_sequence_flow("Flow_B1", "Split_1", "Task_B"),
      make_sequence_flow("Flow_A2", "Task_A", @join_id),
      make_sequence_flow("Flow_B2", "Task_B", @join_id)
    ]

    flow_nodes = [start_event, split, task_a, task_b, join]

    {flow_nodes, sequence_flows}
  end

  describe "should_fire?/4 with pre-computed InclusiveJoinAnalysis" do
    test "all arrived — both incoming flows delivered tokens" do
      assert should_fire?(["Flow_A2", "Flow_B2"], %{})
    end

    test "one arrived, one dead — undelivered flow has no active upstream FNI" do
      assert should_fire?(["Flow_A2"], %{})
    end

    test "one arrived, one waiting — undelivered flow has active upstream FNI" do
      flow_node_instance_states = %{
        "fni-2" => make_flow_node_instance_state("Task_B", :active)
      }

      refute should_fire?(["Flow_A2"], flow_node_instance_states)
    end

    test "no tokens arrived — returns false even when all paths are dead" do
      refute should_fire?([], %{})
    end

    test "complex: three incoming flows with mixed arrived, waiting, and dead states" do
      three_flow_analysis =
        make_inclusive_join_analysis(
          ["Flow_A2", "Flow_B2", "Flow_C2"],
          %{
            "Flow_A2" => MapSet.new(["Task_A", "Split_1", "Start_1"]),
            "Flow_B2" => MapSet.new(["Task_B", "Split_1", "Start_1"]),
            "Flow_C2" => MapSet.new(["Task_C", "Split_1", "Start_1"])
          }
        )

      process_model =
        make_process_model(inclusive_join_analyses: %{@join_id => three_flow_analysis})

      flow_node_instance_states = %{
        "fni-2" => make_flow_node_instance_state("Task_B", :active)
      }

      refute should_fire?(["Flow_A2"], flow_node_instance_states, process_model)
    end
  end

  describe "should_fire?/4 runtime BFS fallback" do
    test "falls back to runtime BFS when inclusive_join_analyses is empty" do
      {flow_nodes, sequence_flows} = two_branch_process_graph()

      process_model =
        make_process_model(
          flow_nodes: flow_nodes,
          sequence_flows: sequence_flows,
          inclusive_join_analyses: %{}
        )

      assert should_fire?(["Flow_A2", "Flow_B2"], %{}, process_model)
    end
  end
end
