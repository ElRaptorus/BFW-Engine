defmodule EvilEngine.BPMN.ComplexRegionAnalysis do
  @moduledoc """
  Deploy-time SESE (Single-Entry, Single-Exit) region analysis for Complex
  Gateway joins.

  Twist 2 of the Complex Gateway (see `docs/architecture/execution.md`
  §Complex Gateway) requires that, when a Complex Join fires, every still-active
  Flow Node Instance inside the region bounded by the **paired Complex Split**
  is cancelled. That region must be deterministic and well-formed, so it is
  computed once per process model version (on deploy / ModelCache rebuild) and
  stored on `Model.Process` as `complex_region_analyses`.

  ## Pairing rule (`S = idom_complex(J)`)

  For a Complex Join `J`, the paired Complex Split `S` is the **nearest
  enclosing Complex Split that dominates `J`** — the immediate dominator of `J`
  restricted to Complex Split nodes. Dominators are computed from a virtual
  entry that feeds every Start Event. Under nesting this always resolves to the
  innermost enclosing split, so inner regions are strictly contained in outer
  ones.

  ## Region

  `region_node_ids = forward_reachable(S) ∩ backward_reachable(J) \\ {S, J}` —
  the flow nodes strictly between the paired split and join.

  ## Well-formedness

  `region_violations/1` reports deploy-time violations (surfaced by the
  `Validator`): a join with no dominating Complex Split
  (`complex_join_no_paired_split`), edges that cross the region boundary other
  than `S → region` and `region → J` (`complex_region_cross_boundary`), and
  regions that partially overlap another region rather than being disjoint or
  strictly nested (`complex_region_overlap`).
  """

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess

  @entry_marker :__complex_region_entry__

  # MapSet is an opaque type; Dialyzer cannot see through its internal
  # representation when sets are built, merged, and passed across these
  # graph-analysis helpers (dominators, reachability, region computation).
  # The behaviour is fully exercised by `ComplexRegionAnalysisTest`.
  @dialyzer {:no_opaque,
             [
               compute_dominators: 3,
               initial_dominators: 2,
               region_node_ids: 4,
               traverse: 4,
               traverse_step: 5
             ]}

  @type t :: %__MODULE__{
          join_flow_node_id: String.t(),
          split_flow_node_id: String.t(),
          region_node_ids: MapSet.t(String.t()),
          incoming_flow_ids: [String.t()],
          upstream_reachability: %{String.t() => MapSet.t(String.t())}
        }

  @enforce_keys [:join_flow_node_id, :split_flow_node_id, :region_node_ids]
  defstruct [
    :join_flow_node_id,
    :split_flow_node_id,
    :region_node_ids,
    incoming_flow_ids: [],
    upstream_reachability: %{}
  ]

  @doc """
  Analyze all Complex Gateway joins in the given process model.

  Returns a map from join `flow_node_id` to `%ComplexRegionAnalysis{}`,
  containing **only** well-formed pairings (a join with no paired split or a
  non-SESE region is omitted — the `Validator` rejects such models at deploy,
  so a clean model always yields a complete map).
  """
  @spec analyze(BpmnProcess.t()) :: %{String.t() => t()}
  def analyze(%BpmnProcess{} = process) do
    process
    |> pairings()
    |> Enum.filter(fn pairing -> pairing.split_id != nil and pairing.violations == [] end)
    |> Map.new(fn pairing ->
      {pairing.join.id,
       %__MODULE__{
         join_flow_node_id: pairing.join.id,
         split_flow_node_id: pairing.split_id,
         region_node_ids: pairing.region,
         incoming_flow_ids: pairing.incoming_flow_ids,
         upstream_reachability: pairing.upstream_reachability
       }}
    end)
  end

  @doc """
  Enrich a process model with pre-computed complex region analyses.

  Populates the `complex_region_analyses` field on the process struct.
  """
  @spec enrich_process(BpmnProcess.t()) :: BpmnProcess.t()
  def enrich_process(%BpmnProcess{} = process) do
    %{process | complex_region_analyses: analyze(process)}
  end

  @doc """
  Collect all deploy-time region well-formedness violations for the process.

  Returns a list of `{code, message}` tuples for the `Validator` to include in
  its violation set. An empty list means every Complex Join is paired to a
  Complex Split via a well-formed SESE region.
  """
  @spec region_violations(BpmnProcess.t()) :: [{atom(), String.t()}]
  def region_violations(%BpmnProcess{} = process) do
    process
    |> pairings()
    |> Enum.flat_map(& &1.violations)
  end

  # ---------------------------------------------------------------------------
  # Core: per-join pairing + region + violations
  # ---------------------------------------------------------------------------

  defp pairings(%BpmnProcess{} = process) do
    incoming_index = build_incoming_index(process.sequence_flows)
    outgoing_index = build_outgoing_index(process.sequence_flows)

    complex_splits = MapSet.new(complex_gateway_ids(process, :split))
    joins = complex_gateway_ids(process, :join)

    dominators = compute_dominators(process, incoming_index, outgoing_index)

    join_pairings =
      Enum.map(joins, fn join_id ->
        join_node = Enum.find(process.flow_nodes, &(&1.id == join_id))
        build_join_pairing(join_node, process, complex_splits, dominators, incoming_index, outgoing_index)
      end)

    overlap_violations = overlap_violations(join_pairings)

    attach_overlap_violations(join_pairings, overlap_violations)
  end

  defp build_join_pairing(join_node, process, complex_splits, dominators, incoming_index, outgoing_index) do
    join_id = join_node.id
    split_id = nearest_dominating_split(join_id, complex_splits, dominators)

    base = %{
      join: join_node,
      split_id: split_id,
      region: MapSet.new(),
      incoming_flow_ids: resolve_incoming_flow_ids(join_node, process),
      upstream_reachability: %{},
      violations: []
    }

    if split_id == nil do
      %{
        base
        | violations: [
            {:complex_join_no_paired_split,
             "ComplexGateway '#{join_id}' is a Complex Join but no Complex Split dominates it. " <>
               "Every Complex Join must be paired to exactly one Complex Split that opens its region."}
          ]
      }
    else
      region = region_node_ids(split_id, join_id, incoming_index, outgoing_index)

      boundary_violations =
        cross_boundary_violations(split_id, join_id, region, process.sequence_flows)

      %{
        base
        | region: region,
          upstream_reachability: upstream_reachability(base.incoming_flow_ids, join_id, process, incoming_index),
          violations: boundary_violations
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Dominators (iterative dataflow from a virtual entry)
  # ---------------------------------------------------------------------------

  defp compute_dominators(process, incoming_index, outgoing_index) do
    all_node_ids = Enum.map(process.flow_nodes, & &1.id)
    start_ids = start_node_ids(process, incoming_index)

    predecessors = predecessor_map(all_node_ids, start_ids, incoming_index)
    reachable = forward_reachable_from_entry(start_ids, outgoing_index)

    universe = MapSet.new([@entry_marker | all_node_ids])
    initial = initial_dominators(reachable, universe)

    iterate_dominators(MapSet.to_list(reachable), predecessors, initial)
  end

  defp initial_dominators(reachable, universe) do
    reachable
    |> MapSet.to_list()
    |> Map.new(fn node_id -> {node_id, universe} end)
    |> Map.put(@entry_marker, MapSet.new([@entry_marker]))
  end

  defp iterate_dominators(reachable_nodes, predecessors, dominators) do
    {updated, changed?} =
      Enum.reduce(reachable_nodes, {dominators, false}, fn node_id, {accumulator, changed?} ->
        recompute_node_dominators(node_id, predecessors, accumulator, changed?)
      end)

    if changed? do
      iterate_dominators(reachable_nodes, predecessors, updated)
    else
      updated
    end
  end

  defp recompute_node_dominators(@entry_marker, _predecessors, accumulator, changed?) do
    {accumulator, changed?}
  end

  defp recompute_node_dominators(node_id, predecessors, accumulator, changed?) do
    # Only intersect over predecessors that are themselves reachable (present in
    # the dominators map). An unreachable predecessor feeding into the reachable
    # graph must not collapse the intersection to the empty set.
    preds =
      predecessors
      |> Map.get(node_id, [])
      |> Enum.filter(&Map.has_key?(accumulator, &1))

    new_dominators =
      preds
      |> Enum.map(fn pred -> Map.get(accumulator, pred, MapSet.new()) end)
      |> intersect_all()
      |> MapSet.put(node_id)

    if MapSet.equal?(new_dominators, Map.get(accumulator, node_id, MapSet.new())) do
      {accumulator, changed?}
    else
      {Map.put(accumulator, node_id, new_dominators), true}
    end
  end

  defp intersect_all([]), do: MapSet.new()

  defp intersect_all([first | rest]) do
    Enum.reduce(rest, first, &MapSet.intersection/2)
  end

  # The paired split: among Complex Splits that dominate the join (excluding the
  # join itself), the nearest one — the split dominated by every other candidate,
  # i.e. the one with the largest dominator set (deepest in the dominator tree).
  defp nearest_dominating_split(join_id, complex_splits, dominators) do
    join_dominators = Map.get(dominators, join_id, MapSet.new())

    join_dominators
    |> MapSet.delete(join_id)
    |> MapSet.to_list()
    |> Enum.filter(&MapSet.member?(complex_splits, &1))
    |> Enum.max_by(fn split_id -> MapSet.size(Map.get(dominators, split_id, MapSet.new())) end, fn -> nil end)
  end

  # ---------------------------------------------------------------------------
  # Region computation
  # ---------------------------------------------------------------------------

  defp region_node_ids(split_id, join_id, incoming_index, outgoing_index) do
    forward = forward_reachable(split_id, join_id, outgoing_index)
    backward = backward_reachable(join_id, split_id, incoming_index)

    forward
    |> MapSet.intersection(backward)
    |> MapSet.delete(split_id)
    |> MapSet.delete(join_id)
  end

  # Forward BFS from `start_id` following outgoing edges. `stop_id` (the join) is
  # included but never expanded, so traversal does not continue past the join.
  defp forward_reachable(start_id, stop_id, outgoing_index) do
    traverse(:queue.from_list([start_id]), MapSet.new(), outgoing_index, stop_id)
  end

  # Backward BFS from `start_id` (the join) following incoming edges. `stop_id`
  # (the split) is included but never expanded.
  defp backward_reachable(start_id, stop_id, incoming_index) do
    traverse(:queue.from_list([start_id]), MapSet.new(), incoming_index, stop_id)
  end

  defp traverse(queue, visited, adjacency_index, stop_id) do
    case :queue.out(queue) do
      {:empty, _} ->
        visited

      {{:value, node_id}, remaining} ->
        traverse_step(remaining, visited, adjacency_index, stop_id, node_id)
    end
  end

  defp traverse_step(queue, visited, adjacency_index, stop_id, node_id) do
    cond do
      MapSet.member?(visited, node_id) ->
        traverse(queue, visited, adjacency_index, stop_id)

      node_id == stop_id ->
        # Include the boundary node but do not expand beyond it.
        traverse(queue, MapSet.put(visited, node_id), adjacency_index, stop_id)

      true ->
        visited = MapSet.put(visited, node_id)

        neighbors =
          adjacency_index
          |> Map.get(node_id, [])
          |> Enum.reject(&MapSet.member?(visited, &1))

        updated_queue =
          Enum.reduce(neighbors, queue, fn neighbor, accumulator ->
            :queue.in(neighbor, accumulator)
          end)

        traverse(updated_queue, visited, adjacency_index, stop_id)
    end
  end

  # ---------------------------------------------------------------------------
  # SESE well-formedness — cross-boundary edges
  # ---------------------------------------------------------------------------

  defp cross_boundary_violations(split_id, join_id, region, sequence_flows) do
    region_with_entry = MapSet.put(region, split_id)
    region_with_exit = MapSet.put(region, join_id)

    sequence_flows
    |> Enum.flat_map(fn flow ->
      edge_boundary_violations(flow, split_id, join_id, region, region_with_entry, region_with_exit)
    end)
    |> Enum.uniq()
  end

  defp edge_boundary_violations(flow, split_id, join_id, region, region_with_entry, region_with_exit) do
    source = flow.source_ref
    target = flow.target_ref

    []
    |> maybe_entry_violation(source, target, split_id, join_id, region, region_with_entry)
    |> maybe_exit_violation(source, target, split_id, join_id, region, region_with_exit)
  end

  # A token enters the region (target ∈ region, or target is the join) from a
  # node that is neither in the region nor the paired split → external entry.
  defp maybe_entry_violation(acc, source, target, split_id, join_id, region, region_with_entry) do
    enters_region? = MapSet.member?(region, target) or target == join_id

    if enters_region? and not MapSet.member?(region_with_entry, source) and source != split_id do
      [
        {:complex_region_cross_boundary,
         "Complex Gateway region between split '#{split_id}' and join '#{join_id}' is not " <>
           "single-entry: sequence flow '#{flow_label(source, target)}' enters the region from " <>
           "'#{source}', which is outside the region and is not the paired split."}
        | acc
      ]
    else
      acc
    end
  end

  # A token leaves the region (source ∈ region, or source is the split) toward a
  # node that is neither in the region nor the join → external exit / leak.
  defp maybe_exit_violation(acc, source, target, split_id, join_id, region, region_with_exit) do
    leaves_region? = MapSet.member?(region, source) or source == split_id

    if leaves_region? and not MapSet.member?(region_with_exit, target) and target != join_id do
      [
        {:complex_region_cross_boundary,
         "Complex Gateway region between split '#{split_id}' and join '#{join_id}' is not " <>
           "single-exit: sequence flow '#{flow_label(source, target)}' leaves the region toward " <>
           "'#{target}', which is outside the region and is not the paired join."}
        | acc
      ]
    else
      acc
    end
  end

  defp flow_label(source, target), do: "#{source} -> #{target}"

  # ---------------------------------------------------------------------------
  # SESE well-formedness — region overlap (must be disjoint or strictly nested)
  # ---------------------------------------------------------------------------

  defp overlap_violations(join_pairings) do
    valid =
      Enum.filter(join_pairings, fn pairing ->
        pairing.split_id != nil and pairing.violations == []
      end)

    for %{join: %{id: join_a}, split_id: split_a, region: region_a} <- valid,
        %{join: %{id: join_b}, split_id: split_b, region: region_b} <- valid,
        join_a < join_b,
        overlap?(full_set(region_a, split_a, join_a), full_set(region_b, split_b, join_b)) do
      {:complex_region_overlap,
       "Complex Gateway regions (split '#{split_a}' / join '#{join_a}') and " <>
         "(split '#{split_b}' / join '#{join_b}') partially overlap. Regions must be either " <>
         "disjoint or strictly nested — partial overlap makes scoped cancellation ambiguous."}
    end
  end

  defp full_set(region, split_id, join_id) do
    region |> MapSet.put(split_id) |> MapSet.put(join_id)
  end

  # Two node sets partially overlap when they intersect but neither contains the
  # other (disjoint and strict-containment are both allowed).
  defp overlap?(set_a, set_b) do
    intersection = MapSet.intersection(set_a, set_b)

    not MapSet.equal?(intersection, MapSet.new()) and
      not MapSet.subset?(set_a, set_b) and
      not MapSet.subset?(set_b, set_a)
  end

  defp attach_overlap_violations(join_pairings, []), do: join_pairings

  defp attach_overlap_violations(join_pairings, overlap_violations) do
    # Attach every overlap violation to the first eligible join so the Validator
    # surfaces each one exactly once (deduplicated).
    unique = Enum.uniq(overlap_violations)

    case Enum.find_index(join_pairings, fn pairing ->
           pairing.split_id != nil and pairing.violations == []
         end) do
      nil ->
        join_pairings

      index ->
        List.update_at(join_pairings, index, fn pairing ->
          %{pairing | violations: pairing.violations ++ unique}
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Graph helpers
  # ---------------------------------------------------------------------------

  defp complex_gateway_ids(process, direction) do
    process.flow_nodes
    |> Enum.filter(&complex_gateway_role?(&1, process, direction))
    |> Enum.map(& &1.id)
  end

  defp complex_gateway_role?(
         %FlowNode{type: :complex_gateway, type_data: %FlowNodeData.ComplexGateway{}} = node,
         process,
         :split
       ) do
    outgoing_count(node, process) > 1 and incoming_count(node, process) <= 1
  end

  defp complex_gateway_role?(
         %FlowNode{type: :complex_gateway, type_data: %FlowNodeData.ComplexGateway{}} = node,
         process,
         :join
       ) do
    incoming_count(node, process) > 1 and outgoing_count(node, process) <= 1
  end

  defp complex_gateway_role?(_node, _process, _direction), do: false

  defp incoming_count(%FlowNode{incoming: ids}, _process) when is_list(ids) and ids != [], do: length(ids)

  defp incoming_count(%FlowNode{id: node_id}, process) do
    Enum.count(process.sequence_flows, &(&1.target_ref == node_id))
  end

  defp outgoing_count(%FlowNode{outgoing: ids}, _process) when is_list(ids) and ids != [], do: length(ids)

  defp outgoing_count(%FlowNode{id: node_id}, process) do
    Enum.count(process.sequence_flows, &(&1.source_ref == node_id))
  end

  defp start_node_ids(process, incoming_index) do
    explicit_starts =
      process.flow_nodes
      |> Enum.filter(&(&1.type == :start_event))
      |> Enum.map(& &1.id)

    case explicit_starts do
      [] ->
        # Fall back to nodes with no incoming edges.
        process.flow_nodes
        |> Enum.map(& &1.id)
        |> Enum.filter(fn node_id -> Map.get(incoming_index, node_id, []) == [] end)

      starts ->
        starts
    end
  end

  defp predecessor_map(all_node_ids, start_ids, incoming_index) do
    start_set = MapSet.new(start_ids)

    Map.new(all_node_ids, fn node_id ->
      base_predecessors = Map.get(incoming_index, node_id, [])

      predecessors =
        if MapSet.member?(start_set, node_id) do
          [@entry_marker | base_predecessors]
        else
          base_predecessors
        end

      {node_id, predecessors}
    end)
  end

  defp forward_reachable_from_entry(start_ids, outgoing_index) do
    traverse(:queue.from_list(start_ids), MapSet.new(), outgoing_index, nil)
  end

  defp upstream_reachability(incoming_flow_ids, join_id, process, incoming_index) do
    Map.new(incoming_flow_ids, fn flow_id ->
      source_ref = find_flow_source_ref(flow_id, process)
      {flow_id, backward_reachable(source_ref || join_id, join_id, incoming_index)}
    end)
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

  defp build_incoming_index(sequence_flows) do
    Enum.reduce(sequence_flows, %{}, fn flow, accumulator ->
      Map.update(accumulator, flow.target_ref, [flow.source_ref], &[flow.source_ref | &1])
    end)
  end

  defp build_outgoing_index(sequence_flows) do
    Enum.reduce(sequence_flows, %{}, fn flow, accumulator ->
      Map.update(accumulator, flow.source_ref, [flow.target_ref], &[flow.target_ref | &1])
    end)
  end
end
