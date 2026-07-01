defmodule EvilEngine.Execution.FlowNodes.EventBasedGateway do
  @moduledoc """
  Handler for `<bpmn:eventBasedGateway>`.

  Diverging gateway that immediately dispatches all outgoing sequence flows
  to their immediate catch events (timer, message, signal, conditional).
  The first catch event to complete wins; sibling catch FNIs are cancelled
  by `ProcessInstance.EventBasedGatewayOrchestrator`.
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
    {incoming_count, outgoing_count} =
      resolve_flow_counts(flow_node, context.process_model)

    cond do
      incoming_count > 1 ->
        {:error,
         %{
           reason: :event_based_gateway_converging_not_supported,
           flow_node_id: flow_node.id,
           incoming_count: incoming_count,
           message: "Event-based gateway with multiple incoming flows is not supported."
         }}

      outgoing_count < 1 ->
        {:error,
         %{
           reason: :dead_end,
           flow_node_id: flow_node.id,
           flow_node_type: flow_node.type,
           message: "Event-based gateway has no outgoing sequence flows."
         }}

      true ->
        handle_fork(flow_node, token, context)
    end
  end

  defp handle_fork(flow_node, token, context) do
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
        {:error, {reason, meta}}
    end
  end

  defp resolve_flow_counts(flow_node, process_model) do
    all_flows = process_model.sequence_flows || []

    incoming_count =
      case flow_node.incoming do
        ids when is_list(ids) and ids != [] ->
          length(ids)

        _ ->
          Enum.count(all_flows, &(&1.target_ref == flow_node.id))
      end

    outgoing_count =
      case flow_node.outgoing do
        ids when is_list(ids) and ids != [] ->
          length(ids)

        _ ->
          Enum.count(all_flows, &(&1.source_ref == flow_node.id))
      end

    {incoming_count, outgoing_count}
  end
end
