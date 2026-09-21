defmodule BfwEngine.Execution.FlowNodes.EscalationBoundaryEvent do
  @moduledoc """
  Handler for `<bpmn:boundaryEvent>` with an Escalation event definition.

  Mirrors `ErrorBoundaryEvent`: a pre-spawned passive handler Task that parks
  the FNI in `:waiting` state. The handler's `receive` loop is a placeholder —
  actual routing flows through `BoundaryOrchestrator.handle_boundary_catch/5`,
  which finds the pre-spawned FNI, kills this handler Task, and finishes the
  FNI in-place.

  ## Interrupting vs Non-Interrupting

  - **Interrupting (`cancel_activity: true`, the default):** When an escalation
    fires, the host activity is cancelled, the boundary FNI is finished as
    `:finished`, and an outgoing sequence flow spawns a new token. If multiple
    escalations arrive at the same interrupting boundary, the first one wins;
    subsequent arrivals are no-ops (host FNI already `:interrupted`).

  - **Non-Interrupting (`cancel_activity: false`):** The boundary FNI is
    finished as `:finished` and an outgoing token is spawned. The host
    activity continues running. Multiple escalations from parallel branches
    each trigger an independent boundary path.

  If the host activity completes normally, `cancel_boundary_fnis_for_host`
  kills this handler Task and transitions the FNI to `:aborted`.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:async, String.t(), (-> term()), map()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, _token, context) do
    cancel_activity = flow_node.type_data.cancel_activity

    type_properties = %{
      host_flow_node_instance_id: context.host_flow_node_instance_id,
      cancel_activity: cancel_activity
    }

    case FniLifecycle.park_async(context, type_properties) do
      :ok ->
        continuation = fn ->
          receive do
            {:escalation_boundary_triggered, _escalation_info} -> :ok
          end
        end

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end
end
