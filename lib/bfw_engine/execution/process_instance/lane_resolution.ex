defmodule BfwEngine.Execution.ProcessInstance.LaneResolution do
  @moduledoc """
  Resolves the lane name of a flow node from a process model or handler context.
  """

  alias BfwEngine.BPMN.Model.FlowNode

  @spec resolve_lane_name(struct() | nil, FlowNode.t() | nil) :: String.t() | nil
  def resolve_lane_name(nil, _flow_node), do: nil
  def resolve_lane_name(_process_model, nil), do: nil

  def resolve_lane_name(process_model, flow_node) do
    lane =
      Enum.find(process_model.lanes || [], fn lane ->
        flow_node.id in (lane.flow_node_refs || [])
      end)

    if lane, do: lane.name, else: nil
  end

  @spec resolve_lane_name_from_context(map(), FlowNode.t() | nil) :: String.t() | nil
  def resolve_lane_name_from_context(context, flow_node) do
    resolve_lane_name(Map.get(context, :process_model), flow_node)
  end
end
