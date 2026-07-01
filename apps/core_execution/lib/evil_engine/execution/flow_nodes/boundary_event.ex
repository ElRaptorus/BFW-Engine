defmodule EvilEngine.Execution.FlowNodes.BoundaryEvent do
  @moduledoc """
  Generic fallback handler for `<bpmn:boundaryEvent>`.

  Used for boundary event types that do not have a dedicated
  subscription-model handler (currently: error boundaries). The PI
  resolves the boundary node's outgoing targets directly via
  `BoundaryOrchestrator` — this handler is retained as a fallback in
  `HandlerDispatch` for structural completeness but is not dispatched
  in the normal boundary fire path.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Types.Token

  @doc "Forwards the error token along the boundary event's outgoing sequence flows."
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    with {:ok, targets} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <- FniLifecycle.finish(context, flow_node, token.payload, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: token.payload,
         next_flow_node_ids: Enum.map(targets, & &1.id),
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
