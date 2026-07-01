defmodule EvilEngine.Execution.InclusiveJoinEvaluator do
  @moduledoc """
  Runtime dead-path elimination for inclusive gateway joins.

  Determines whether a parked inclusive join should fire by checking
  each incoming sequence flow:

  - **arrived** — a token has been delivered via this flow
  - **dead** — no active/waiting FNI exists whose `flow_node_id` is
    in the pre-computed upstream reachability set for this flow
  - **waiting** — at least one upstream FNI is still alive

  The join fires when all incoming flows are either `arrived` or `dead`,
  and at least one flow is `arrived`.

  Uses pre-computed `InclusiveJoinAnalysis` data from the process model.
  Falls back to runtime BFS when no analysis is available (backward
  compatibility with models deployed before the analysis was introduced).
  """

  alias EvilEngine.BPMN.InclusiveJoinAnalysis
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess

  @doc """
  Returns `true` if the inclusive join should fire.

  Checks every incoming sequence flow of the join: flows that have
  delivered a token are `arrived`; flows with no live upstream FNIs
  are `dead`. The join fires when no flow is still `waiting`.
  """
  @spec should_fire?(
          join_flow_node_id :: String.t(),
          arrived_via_flow_ids :: MapSet.t(String.t()),
          flow_node_instance_states :: map(),
          process_model :: BpmnProcess.t()
        ) :: boolean()
  def should_fire?(join_flow_node_id, arrived_via_flow_ids, flow_node_instance_states, process_model) do
    case Map.get(process_model.inclusive_join_analyses, join_flow_node_id) do
      %InclusiveJoinAnalysis{} = analysis ->
        evaluate_with_analysis(analysis, arrived_via_flow_ids, flow_node_instance_states)

      nil ->
        evaluate_with_runtime_bfs(
          join_flow_node_id,
          arrived_via_flow_ids,
          flow_node_instance_states,
          process_model
        )
    end
  end

  defp evaluate_with_analysis(analysis, arrived_via_flow_ids, flow_node_instance_states) do
    active_flow_node_ids = collect_active_flow_node_ids(flow_node_instance_states)

    all_resolved =
      Enum.all?(analysis.incoming_flow_ids, fn flow_id ->
        if MapSet.member?(arrived_via_flow_ids, flow_id) do
          true
        else
          upstream_nodes = Map.get(analysis.upstream_reachability, flow_id, MapSet.new())
          MapSet.disjoint?(active_flow_node_ids, upstream_nodes)
        end
      end)

    all_resolved and MapSet.size(arrived_via_flow_ids) > 0
  end

  defp evaluate_with_runtime_bfs(join_flow_node_id, arrived_via_flow_ids, flow_node_instance_states, process_model) do
    incoming_index = build_incoming_index(process_model.sequence_flows)

    incoming_flow_ids = resolve_incoming_flow_ids(join_flow_node_id, process_model)
    active_flow_node_ids = collect_active_flow_node_ids(flow_node_instance_states)

    all_resolved =
      Enum.all?(incoming_flow_ids, fn flow_id ->
        if MapSet.member?(arrived_via_flow_ids, flow_id) do
          true
        else
          source_ref = find_flow_source_ref(flow_id, process_model)

          upstream_nodes =
            InclusiveJoinAnalysis.backward_reachability_bfs(
              source_ref,
              join_flow_node_id,
              incoming_index
            )

          MapSet.disjoint?(active_flow_node_ids, upstream_nodes)
        end
      end)

    all_resolved and MapSet.size(arrived_via_flow_ids) > 0
  end

  defp collect_active_flow_node_ids(flow_node_instance_states) do
    flow_node_instance_states
    |> Enum.filter(fn {_fni_id, entry} -> entry.state in [:active, :waiting] end)
    |> Enum.map(fn {_fni_id, entry} -> entry.flow_node_id end)
    |> MapSet.new()
  end

  defp resolve_incoming_flow_ids(join_flow_node_id, process_model) do
    flow_node = Enum.find(process_model.flow_nodes, &(&1.id == join_flow_node_id))

    case flow_node do
      %{incoming: ids} when is_list(ids) and ids != [] ->
        ids

      _ ->
        process_model.sequence_flows
        |> Enum.filter(&(&1.target_ref == join_flow_node_id))
        |> Enum.map(& &1.id)
    end
  end

  defp find_flow_source_ref(flow_id, process_model) do
    case Enum.find(process_model.sequence_flows, &(&1.id == flow_id)) do
      nil -> nil
      flow -> flow.source_ref
    end
  end

  defp build_incoming_index(sequence_flows) do
    Enum.reduce(sequence_flows, %{}, fn flow, accumulator ->
      Map.update(accumulator, flow.target_ref, [flow.source_ref], &[flow.source_ref | &1])
    end)
  end
end
