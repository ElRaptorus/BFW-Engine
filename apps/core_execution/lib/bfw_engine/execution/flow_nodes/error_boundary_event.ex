defmodule BfwEngine.Execution.FlowNodes.ErrorBoundaryEvent do
  @moduledoc """
  Handler for `<bpmn:boundaryEvent>` with an Error event definition.

  Unlike timer, message, and signal boundary handlers, the error boundary
  handler Task is **never triggered via its `receive` loop**. It exists
  solely so that the standard `dispatch_boundary_fni` machinery can
  pre-spawn a real FNI record visible to the debugger and WebSocket
  consumers from the moment the host activity starts.

  Error routing continues to happen in `BoundaryAwareHandler` (for
  `handle_enter` errors) and in `SubProcess` (for child PI errors).
  When those produce `{:boundary, ...}`, the PI's `handle_boundary_catch`
  finds the pre-spawned FNI, kills this handler Task, and finishes the
  FNI in-place.

  If the host activity completes normally, `cancel_boundary_fnis_for_host`
  kills the handler Task and transitions the FNI to `:aborted`.
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
            {:error_boundary_triggered, _error_info} -> :ok
          end
        end

        {:async, context.flow_node_instance_id, continuation,
         Map.put(type_properties, :persisted, true)}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end
end
