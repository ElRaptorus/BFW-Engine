defmodule EvilEngine.Execution.FlowNodes.StartEvent do
  @moduledoc """
  Handler for untyped `<bpmn:startEvent>`.

  Immediate completion — token payload passes through unchanged.
  Typed start events (Message, Signal, Timer, Conditional) will
  extend this handler in Phase 2.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        output_payload = token.payload
        next_ids = Enum.map(targets, & &1.id)

        case FniLifecycle.finish(context, flow_node, output_payload, %{}) do
          {:ok, lifecycle_result} ->
            {:ok,
             %FlowNodeResult{
               output_payload: output_payload,
               next_flow_node_ids: next_ids,
               metadata: %{persisted: true, lifecycle: lifecycle_result}
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason, meta} ->
        {:error, Map.put(meta, :reason, reason)}
    end
  end
end
