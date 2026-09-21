defmodule BfwEngine.Execution.FlowNodes.EscalationIntermediateThrowEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateThrowEvent>` with an Escalation event definition.

  Returns `{:escalation_throw, escalation_info, FlowNodeResult}` — the PI reacts
  by dispatching the outgoing sequence flows (the token continues), emitting an
  `EscalationRaised` engine event, and sending
  `{:child_pi_escalation_passthrough, ...}` to the parent handler Task if this
  PI has a parent. The PI remains in `:running` state — the escalation is a
  side-effect, not a terminal event.

  ## Distinction from Escalation End Event

  The Intermediate Throw Event means "escalate and keep working". The token
  continues on the single outgoing sequence flow. The PI does not terminate.
  Parent scopes receive the escalation passthrough and may catch it on a boundary.

  If a parent's *interrupting* boundary catches an intermediate throw escalation,
  the parent interrupts the Call Activity / SubProcess that triggered it. The
  child PI is then aborted externally (`:aborted`), not escalated (`:escalated`).
  This is the correct BPMN 2.0 semantic: the child did not choose to end — it was
  killed by the parent's interruption.

  ## Token flow

  The FNI is persisted as `:finished`. `next_flow_node_ids` contains the IDs of
  all nodes reachable via outgoing unconditional sequence flows (typically one).
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.EscalationResolver
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:escalation_throw, map(), FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    event_def = flow_node.type_data.event_definition
    escalation_info = EscalationResolver.resolve_escalation_info(event_def, context.definitions)

    escalation_info =
      Map.put(escalation_info, :triggerer_flow_node_instance_id, context.flow_node_instance_id)

    output_payload = token.payload

    type_properties = %{
      escalation_code: escalation_info[:escalation_code],
      escalation_name: escalation_info[:escalation_name]
    }

    with {:ok, targets} <- resolve_outgoing(flow_node, context),
         next_ids = Enum.map(targets, & &1.id),
         {:ok, lifecycle_result} <-
           FniLifecycle.finish(context, flow_node, output_payload, type_properties) do
      {:escalation_throw, escalation_info,
       %FlowNodeResult{
         output_payload: output_payload,
         next_flow_node_ids: next_ids,
         type_properties: type_properties,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, targets}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
