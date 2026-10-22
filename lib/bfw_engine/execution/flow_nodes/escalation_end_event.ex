defmodule BfwEngine.Execution.FlowNodes.EscalationEndEvent do
  @moduledoc """
  Handler for `<bpmn:endEvent>` with a `<bpmn:escalationEventDefinition>`.

  Returns `{:escalation_end, escalation_info, FlowNodeResult}` — the PI reacts
  by finishing this FNI as `:finished` (it completed its intended purpose),
  interrupting all remaining active/waiting sibling FNIs with reason
  `:escalation_end_event`, transitioning itself to `:escalated` state, and
  notifying the parent handler Task via `{:child_pi_escalation, ...}`.

  Escalation code resolution priority (throw-side):
  1. Global `<bpmn:escalation escalationCode="...">` resolved via `escalationRef`
  2. `nil` — unnamed escalation; catch-all boundaries will match it

  ## Distinction from Escalation Intermediate Throw Event

  The Escalation End Event terminates the process scope ("escalate and shut down").
  All active paths are interrupted. The PI ends as `:escalated`.

  The Escalation Intermediate Throw Event keeps the token moving on its outgoing
  sequence flow ("escalate and keep working"). The PI continues running.

  ## Sibling FNI state

  Siblings interrupted by an Escalation End Event transition to `:interrupted`
  (same as Terminate End Event), not `:error` (which is reserved for Error End
  Event). This reflects that the interruption is a deliberate, modeled outcome,
  not a fault. The audit trail clearly shows which FNI raised the escalation
  (`:finished`) and which were collateral (`:interrupted`).
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.EscalationResolver
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:escalation_end, map(), FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    event_def = flow_node.type_data.event_definition
    escalation_info = EscalationResolver.resolve_escalation_info(event_def, context.definitions)

    escalation_info =
      Map.put(escalation_info, :triggerer_flow_node_instance_id, context.flow_node_instance_id)

    output_payload = token.payload

    type_properties = %{
      end_event_id: flow_node.id,
      end_event_name: flow_node.name,
      escalation_code: escalation_info[:escalation_code],
      escalation_name: escalation_info[:escalation_name]
    }

    case FniLifecycle.finish(context, flow_node, output_payload, type_properties) do
      {:ok, lifecycle_result} ->
        {:escalation_end, escalation_info,
         %FlowNodeResult{
           output_payload: output_payload,
           next_flow_node_ids: [],
           type_properties: type_properties,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
