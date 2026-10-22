defmodule BfwEngine.Execution.ProcessInstance.FlowNodeLookup do
  @moduledoc """
  Looks up a flow node on the in-memory process model and reads its event type.
  """

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode

  @event_definition_type_map %{
    EventDefinition.Message => "message",
    EventDefinition.Signal => "signal",
    EventDefinition.Timer => "timer",
    EventDefinition.Error => "error",
    EventDefinition.Escalation => "escalation",
    EventDefinition.Conditional => "conditional",
    EventDefinition.Compensation => "compensation",
    EventDefinition.Terminate => "terminate",
    EventDefinition.Cancel => "cancel",
    EventDefinition.Link => "link"
  }

  @spec find_flow_node(struct(), String.t()) :: FlowNode.t() | nil
  def find_flow_node(data, flow_node_id) do
    Enum.find(data.process_model.flow_nodes, &(&1.id == flow_node_id))
  end

  @spec extract_event_type(FlowNode.t()) :: String.t() | nil
  def extract_event_type(%FlowNode{type: type})
      when type in [:send_task, :receive_task],
      do: "message"

  def extract_event_type(%FlowNode{type_data: %{event_definition: %{__struct__: module}}}) do
    Map.get(@event_definition_type_map, module)
  end

  def extract_event_type(%FlowNode{}), do: nil
end
