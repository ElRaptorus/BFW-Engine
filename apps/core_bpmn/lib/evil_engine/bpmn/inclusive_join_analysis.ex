defmodule EvilEngine.BPMN.InclusiveJoinAnalysis do
  @moduledoc """
  Deploy-time graph analysis for inclusive gateway joins.

  For each inclusive join gateway in a process, pre-computes the
  **backward reachability set** per incoming sequence flow. At runtime,
  `InclusiveJoinEvaluator` intersects these pre-computed sets with the
  current active FNI set — turning dead-path elimination from an
  `O(graph_size)` BFS into an `O(1)` set intersection.

  The analysis is invoked once per process model version (on deploy or
  ModelCache rebuild) and stored on the `Model.Process` struct as
  `inclusive_join_analyses`.
  """

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess

  @type t :: %__MODULE__{
          join_flow_node_id: String.t(),
          incoming_flow_ids: [String.t()],
          upstream_reachability: %{String.t() => MapSet.t(String.t())}
        }

  @enforce_keys [:join_flow_node_id, :incoming_flow_ids, :upstream_reachability]
  defstruct [:join_flow_node_id, :incoming_flow_ids, :upstream_reachability]

  @doc """
  Analyze all inclusive join gateways in the given process model.

  Returns a map from join flow_node_id to `%InclusiveJoinAnalysis{}`.
  """
  @spec analyze(BpmnProcess.t()) :: %{String.t() => t()}
  def analyze(%BpmnProcess{} = process) do
    incoming_index = build_incoming_index(process.sequence_flows)

    process.flow_nodes
    |> Enum.filter(&inclusive_join?(&1, process))
    |> Map.new(fn join_node ->
      analysis = analyze_single_join(join_node, process, incoming_index)
      {join_node.id, analysis}
    end)
  end

  @doc """
  Enrich a process model with pre-computed inclusive join analyses.

  Populates the `inclusive_join_analyses` field on the process struct.
  """
  @spec enrich_process(BpmnProcess.t()) :: BpmnProcess.t()
  def enrich_process(%BpmnProcess{} = process) do
    %{process | inclusive_join_analyses: analyze(process)}
  end

  defp inclusive_join?(
         %FlowNode{type: :inclusive_gateway, type_data: %FlowNodeData.InclusiveGateway{}} = node,
         process
       ) do
    incoming_count = count_direction(node, process, :incoming)
    outgoing_count = count_direction(node, process, :outgoing)

    incoming_count > 1 and outgoing_count <= 1
  end

  defp inclusive_join?(_node, _process), do: false

  defp count_direction(%FlowNode{} = node, process, :incoming) do
    case node.incoming do
      ids when is_list(ids) and ids != [] -> length(ids)
      _ -> Enum.count(process.sequence_flows, &(&1.target_ref == node.id))
    end
  end

  defp count_direction(%FlowNode{} = node, process, :outgoing) do
    case node.outgoing do
      ids when is_list(ids) and ids != [] -> length(ids)
      _ -> Enum.count(process.sequence_flows, &(&1.source_ref == node.id))
    end
  end

  defp analyze_single_join(join_node, process, incoming_index) do
    incoming_flow_ids = resolve_incoming_flow_ids(join_node, process)

    upstream_reachability =
      Map.new(incoming_flow_ids, fn flow_id ->
        source_ref = find_flow_source_ref(flow_id, process)
        reachable = backward_reachability_bfs(source_ref, join_node.id, incoming_index)
        {flow_id, reachable}
      end)

    %__MODULE__{
      join_flow_node_id: join_node.id,
      incoming_flow_ids: incoming_flow_ids,
      upstream_reachability: upstream_reachability
    }
  end

  defp resolve_incoming_flow_ids(%FlowNode{} = node, process) do
    case node.incoming do
      ids when is_list(ids) and ids != [] ->
        ids

      _ ->
        process.sequence_flows
        |> Enum.filter(&(&1.target_ref == node.id))
        |> Enum.map(& &1.id)
    end
  end

  defp find_flow_source_ref(flow_id, process) do
    case Enum.find(process.sequence_flows, &(&1.id == flow_id)) do
      nil -> nil
      flow -> flow.source_ref
    end
  end

  @doc """
  BFS backward from `start_node_id`, collecting all reachable flow node IDs.

  Walks backwards through incoming sequence flows, excluding the join
  node itself to prevent cycles through the join. Returns a `MapSet`
  of all flow node IDs that can produce a token reaching `start_node_id`.
  """
  @dialyzer {:no_opaque, backward_reachability_bfs: 3}
  @spec backward_reachability_bfs(String.t() | nil, String.t(), map()) :: MapSet.t()
  def backward_reachability_bfs(nil, _excluded_node_id, _incoming_index), do: MapSet.new()

  def backward_reachability_bfs(start_node_id, excluded_node_id, incoming_index) do
    do_backward_bfs(
      :queue.from_list([start_node_id]),
      MapSet.new([excluded_node_id]),
      MapSet.new(),
      incoming_index
    )
  end

  @dialyzer {:no_opaque, do_backward_bfs: 4}
  defp do_backward_bfs(queue, visited, result, incoming_index) do
    case :queue.out(queue) do
      {:empty, _} ->
        result

      {{:value, node_id}, remaining_queue} ->
        do_backward_bfs_step(remaining_queue, visited, result, incoming_index, node_id)
    end
  end

  @dialyzer {:no_opaque, do_backward_bfs_step: 5}
  defp do_backward_bfs_step(queue, visited, result, incoming_index, node_id) do
    if MapSet.member?(visited, node_id) do
      do_backward_bfs(queue, visited, result, incoming_index)
    else
      visited = MapSet.put(visited, node_id)
      result = MapSet.put(result, node_id)

      predecessor_ids =
        incoming_index
        |> Map.get(node_id, [])
        |> Enum.reject(&MapSet.member?(visited, &1))

      updated_queue =
        Enum.reduce(predecessor_ids, queue, fn predecessor_id, queue_accumulator ->
          :queue.in(predecessor_id, queue_accumulator)
        end)

      do_backward_bfs(updated_queue, visited, result, incoming_index)
    end
  end

  defp build_incoming_index(sequence_flows) do
    Enum.reduce(sequence_flows, %{}, fn flow, accumulator ->
      Map.update(accumulator, flow.target_ref, [flow.source_ref], &[flow.source_ref | &1])
    end)
  end
end
