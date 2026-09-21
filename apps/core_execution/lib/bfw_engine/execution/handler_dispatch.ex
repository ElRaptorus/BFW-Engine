defmodule BfwEngine.Execution.HandlerDispatch do
  @moduledoc """
  Maps BPMN flow nodes to their handler modules.

  Accepts either a `%FlowNode{}` struct (primary) or a bare type atom
  (legacy fallback). For intermediate events the struct-based clause
  inspects the event definition to route to a type-specific handler
  (e.g. `LinkThrowEvent`); all other node types fall through to the
  static type-atom map.

  Returns `{:error, :unsupported_element}` (Tier 3) for flow-node
  types without a registered handler, or
  `{:error, {:unsupported_event_definition, flow_node}}` for typed
  event definitions that are not yet implemented — the PI fatals the
  FNI with a structured reason rather than raising.
  """

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.MultiInstance
  alias BfwEngine.BPMN.Model.StandardLoop
  alias BfwEngine.Execution.FlowNodes

  @handler_map %{
    start_event: FlowNodes.StartEvent,
    end_event: FlowNodes.EndEvent,
    task: FlowNodes.Task,
    service_task: FlowNodes.ServiceTask,
    send_task: FlowNodes.SendTask,
    receive_task: FlowNodes.ReceiveTask,
    intermediate_catch_event: FlowNodes.IntermediateEvent,
    intermediate_throw_event: FlowNodes.IntermediateEvent,
    manual_task: FlowNodes.ManualTask,
    user_task: FlowNodes.UserTask,
    exclusive_gateway: FlowNodes.ExclusiveGateway,
    script_task: FlowNodes.ScriptTask,
    business_rule_task: FlowNodes.BusinessRuleTask,
    parallel_gateway: FlowNodes.ParallelGateway,
    inclusive_gateway: FlowNodes.InclusiveGateway,
    complex_gateway: FlowNodes.ComplexGateway,
    event_based_gateway: FlowNodes.EventBasedGateway,
    call_activity: FlowNodes.CallActivity,
    sub_process: FlowNodes.SubProcess,
    boundary_event: FlowNodes.BoundaryEvent
  }

  @doc """
  Look up the handler module for a flow node.

  Accepts a `%FlowNode{}` struct (preferred — enables event-definition-aware
  dispatch for intermediate events) or a bare type atom (legacy fallback).

  Returns `{:ok, module}`, `{:error, :unsupported_element}`, or
  `{:error, {:unsupported_event_definition, flow_node}}`.
  """
  @spec handler_for(FlowNode.t() | atom()) ::
          {:ok, module()}
          | {:error, :unsupported_element}
          | {:error, {:unsupported_event_definition, FlowNode.t()}}
  def handler_for(%FlowNode{multi_instance: %MultiInstance{}}) do
    {:ok, FlowNodes.MultiInstanceBody}
  end

  def handler_for(%FlowNode{standard_loop: %StandardLoop{}}) do
    {:ok, FlowNodes.StandardLoopBody}
  end

  def handler_for(%FlowNode{} = flow_node) do
    case resolve_handler(flow_node) do
      {:ok, _} = ok ->
        ok

      :unsupported_event_definition ->
        {:error, {:unsupported_event_definition, flow_node}}

      :fallback ->
        handler_for_type(flow_node.type)
    end
  end

  def handler_for(flow_node_type) when is_atom(flow_node_type) do
    handler_for_type(flow_node_type)
  end

  @doc """
  Look up the handler module for the inner activity of an MI/Loop flow node.

  Strips the MI/StandardLoop wrapping and resolves the handler for the
  underlying activity type. Used by the PI when dispatching iteration FNIs.
  """
  @spec inner_handler_for(FlowNode.t()) ::
          {:ok, module()}
          | {:error, :unsupported_element}
          | {:error, {:unsupported_event_definition, FlowNode.t()}}
  def inner_handler_for(%FlowNode{} = flow_node) do
    stripped = %{flow_node | multi_instance: nil, standard_loop: nil}

    case resolve_handler(stripped) do
      {:ok, _} = ok -> ok
      :unsupported_event_definition -> {:error, {:unsupported_event_definition, flow_node}}
      :fallback -> handler_for_type(stripped.type)
    end
  end

  # -- Event-definition-aware dispatch for intermediate events ---------------

  defp resolve_handler(%FlowNode{
         type: :intermediate_throw_event,
         type_data: %{event_definition: %EventDefinition.Link{}}
       }) do
    {:ok, FlowNodes.LinkThrowEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_catch_event,
         type_data: %{event_definition: %EventDefinition.Link{}}
       }) do
    {:ok, FlowNodes.LinkCatchEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_catch_event,
         type_data: %{event_definition: %EventDefinition.Timer{}}
       }) do
    {:ok, FlowNodes.TimerCatchEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Timer{}}
       }) do
    {:ok, FlowNodes.TimerBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :start_event,
         type_data: %{event_definition: %EventDefinition.Timer{}}
       }) do
    {:ok, FlowNodes.TimerStartEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :end_event,
         type_data: %{event_definition: %EventDefinition.Terminate{}}
       }) do
    {:ok, FlowNodes.TerminateEndEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :end_event,
         type_data: %{event_definition: %EventDefinition.Error{}}
       }) do
    {:ok, FlowNodes.ErrorEndEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Error{}}
       }) do
    {:ok, FlowNodes.ErrorBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_catch_event,
         type_data: %{event_definition: %EventDefinition.Message{}}
       }) do
    {:ok, FlowNodes.MessageCatchEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Message{}}
       }) do
    {:ok, FlowNodes.MessageBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_throw_event,
         type_data: %{event_definition: %EventDefinition.Message{}}
       }) do
    {:ok, FlowNodes.MessageThrowEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :end_event,
         type_data: %{event_definition: %EventDefinition.Message{}}
       }) do
    {:ok, FlowNodes.MessageEndEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :start_event,
         type_data: %{event_definition: %EventDefinition.Message{}}
       }) do
    {:ok, FlowNodes.MessageStartEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_catch_event,
         type_data: %{event_definition: %EventDefinition.Signal{}}
       }) do
    {:ok, FlowNodes.SignalCatchEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Signal{}}
       }) do
    {:ok, FlowNodes.SignalBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_throw_event,
         type_data: %{event_definition: %EventDefinition.Signal{}}
       }) do
    {:ok, FlowNodes.SignalThrowEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :end_event,
         type_data: %{event_definition: %EventDefinition.Signal{}}
       }) do
    {:ok, FlowNodes.SignalEndEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :start_event,
         type_data: %{event_definition: %EventDefinition.Signal{}}
       }) do
    {:ok, FlowNodes.SignalStartEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :end_event,
         type_data: %{event_definition: %EventDefinition.Escalation{}}
       }) do
    {:ok, FlowNodes.EscalationEndEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_throw_event,
         type_data: %{event_definition: %EventDefinition.Escalation{}}
       }) do
    {:ok, FlowNodes.EscalationIntermediateThrowEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Escalation{}}
       }) do
    {:ok, FlowNodes.EscalationBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{type_data: %{event_definition: %EventDefinition.Escalation{}}}) do
    :unsupported_event_definition
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_throw_event,
         type_data: %{event_definition: %EventDefinition.Compensation{}}
       }) do
    {:ok, FlowNodes.CompensateThrowEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :end_event,
         type_data: %{event_definition: %EventDefinition.Compensation{}}
       }) do
    {:ok, FlowNodes.CompensateEndEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Compensation{}}
       }) do
    {:ok, FlowNodes.CompensationBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :intermediate_catch_event,
         type_data: %{event_definition: %EventDefinition.Conditional{}}
       }) do
    {:ok, FlowNodes.ConditionalCatchEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Conditional{}}
       }) do
    {:ok, FlowNodes.ConditionalBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :start_event,
         type_data: %{event_definition: %EventDefinition.Conditional{}}
       }) do
    :unsupported_event_definition
  end

  defp resolve_handler(%FlowNode{
         type: :end_event,
         type_data: %{event_definition: %EventDefinition.Cancel{}}
       }) do
    {:ok, FlowNodes.CancelEndEvent}
  end

  defp resolve_handler(%FlowNode{
         type: :boundary_event,
         type_data: %{event_definition: %EventDefinition.Cancel{}}
       }) do
    {:ok, FlowNodes.CancelBoundaryEvent}
  end

  defp resolve_handler(%FlowNode{type_data: %{event_definition: %EventDefinition.Cancel{}}}) do
    :unsupported_event_definition
  end

  # Transaction subprocess — must be checked before the Event Subprocess clause
  # to ensure `is_transaction: true` takes priority over `triggered_by_event`.
  defp resolve_handler(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{is_transaction: true}
       }) do
    {:ok, FlowNodes.TransactionSubProcess}
  end

  # Ad-hoc subprocess — must be checked before the Event Subprocess clause.
  defp resolve_handler(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{is_ad_hoc: true}
       }) do
    {:ok, FlowNodes.AdHocSubProcess}
  end

  # Event Subprocess shell — triggered by its start event, not by a token enter.
  # Firing is orchestrated by the scope PI, which dispatches the shell FNI
  # through this handler.
  defp resolve_handler(%FlowNode{
         type: :sub_process,
         type_data: %FlowNodeData.SubProcess{triggered_by_event: true}
       }) do
    {:ok, FlowNodes.EventSubprocess}
  end

  defp resolve_handler(_flow_node), do: :fallback

  # -- Static type-atom lookup -----------------------------------------------

  defp handler_for_type(flow_node_type) do
    case Map.fetch(@handler_map, flow_node_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unsupported_element}
    end
  end
end
