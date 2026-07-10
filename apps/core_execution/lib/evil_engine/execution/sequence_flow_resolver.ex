defmodule EvilEngine.Execution.SequenceFlowResolver do
  @moduledoc """
  Utility for resolving outgoing sequence flows.

  Called by individual `FlowNodeHandler` implementations to determine
  their `next_flow_node_ids`. Non-gateway handlers and gateway join
  handlers delegate here; gateway split handlers implement their own
  routing logic (e.g. FEEL condition evaluation for Exclusive Gateway).

  Returns `{:ok, targets}` on success or `{:error, reason, metadata}`
  when a runtime encounter-time check (Tier 3) detects an
  ambiguous or invalid topology (implicit split, dead end).
  """

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow

  @gateway_types [
    :exclusive_gateway,
    :parallel_gateway,
    :inclusive_gateway,
    :event_based_gateway,
    :complex_gateway
  ]

  @doc """
  Resolve outgoing sequence flows for a completed flow node.

  Returns `{:ok, [FlowNode.t()]}` with the list of target flow nodes
  to dispatch, or `{:error, reason, metadata}` when the topology is
  invalid at runtime.
  """
  @spec resolve(FlowNode.t(), BpmnProcess.t()) ::
          {:ok, [FlowNode.t()]}
          | {:error, :implicit_split | :dead_end, map()}
  def resolve(%FlowNode{} = completed_node, %BpmnProcess{} = process) do
    candidates = fetch_outgoing_flows(completed_node, process)
    is_gateway = completed_node.type in @gateway_types
    is_end_event = completed_node.type == :end_event
    outgoing_count = length(candidates)

    cond do
      not is_gateway and outgoing_count > 1 ->
        {:error, :implicit_split,
         %{
           flow_node_id: completed_node.id,
           flow_node_type: completed_node.type,
           outgoing_count: outgoing_count
         }}

      not is_end_event and outgoing_count == 0 and not completed_node.is_for_compensation ->
        {:error, :dead_end,
         %{
           flow_node_id: completed_node.id,
           flow_node_type: completed_node.type
         }}

      outgoing_count == 0 ->
        {:ok, []}

      true ->
        resolve_candidates(candidates, process)
    end
  end

  defp fetch_outgoing_flows(%FlowNode{} = node, %BpmnProcess{} = process) do
    case node.outgoing do
      outgoing_ids when is_list(outgoing_ids) and outgoing_ids != [] ->
        flow_index = Map.new(process.sequence_flows, &{&1.id, &1})
        Enum.filter(outgoing_ids, &Map.has_key?(flow_index, &1)) |> Enum.map(&flow_index[&1])

      _ ->
        Enum.filter(process.sequence_flows, &(&1.source_ref == node.id))
    end
  end

  # `condition_expression` and `is_default` are honored only on
  # outgoing flows of Split Gateways, which route via their own handler and
  # never delegate here. For non-Gateway sources and Gateway-joins the
  # resolver follows every candidate flow unconditionally; the implicit-split
  # and dead-end checks above already prevent ambiguous topology from
  # reaching this point.
  defp resolve_candidates(candidates, process) do
    {:ok, resolve_targets(candidates, process)}
  end

  defp resolve_targets(flows, process) do
    node_index = Map.new(process.flow_nodes, &{&1.id, &1})

    flows
    |> Enum.map(fn %SequenceFlow{target_ref: target_ref} -> Map.get(node_index, target_ref) end)
    |> Enum.reject(&is_nil/1)
  end
end
