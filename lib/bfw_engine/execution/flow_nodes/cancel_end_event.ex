defmodule BfwEngine.Execution.FlowNodes.CancelEndEvent do
  @moduledoc """
  Handler for `<bpmn:endEvent>` with a Cancel event definition.

  Returns `{:cancel, FlowNodeResult}`. The PI state machine reacts by:

  1. Finishing the Cancel End FNI normally.
  2. Interrupting all remaining active/waiting FNIs in the scope
     (`:cancelled_by_cancel_end`).
  3. Running LIFO compensation for all completed activities using the
     existing `CompensationOrchestrator`.
  4. After compensation completes (or immediately if no compensable
     activities exist): transitioning the child PI to `:cancelled` and
     notifying the parent Transaction handler.

  ## Hazard semantics

  This handler must only be dispatched inside a Transaction subprocess
  scope. A runtime guard rejects Cancel End Events reached outside a
  transaction (produces `{:error, :cancel_end_outside_transaction}`).

  If compensation handlers fatal during the automatic compensation run,
  the child PI transitions to `:fatal` instead of `:cancelled` (hazard
  outcome per BPMN 2.0 §13.4.6).

  ## Idempotency

  If a second Cancel End fires (parallel branches) while cancellation is
  already in progress, the PI state machine absorbs the duplicate as a
  no-op.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:cancel, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    if inside_transaction_scope?(flow_node, context) do
      output_payload = token.payload

      type_properties = %{
        end_event_id: flow_node.id,
        end_event_name: flow_node.name
      }

      case FniLifecycle.finish(context, flow_node, output_payload, type_properties) do
        {:ok, lifecycle_result} ->
          {:cancel,
           %FlowNodeResult{
             output_payload: output_payload,
             next_flow_node_ids: [],
             type_properties: type_properties,
             metadata: %{persisted: true, lifecycle: lifecycle_result}
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :cancel_end_outside_transaction}
    end
  end

  @impl true
  def handle_fatal(_entry), do: :ok

  @impl true
  def handle_aborted(_entry), do: :ok

  defp inside_transaction_scope?(_flow_node, context) do
    Map.get(context.process_model, :is_transaction_scope, false)
  end
end
