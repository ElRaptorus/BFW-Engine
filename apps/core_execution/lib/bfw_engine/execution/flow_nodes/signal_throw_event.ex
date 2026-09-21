defmodule BfwEngine.Execution.FlowNodes.SignalThrowEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateThrowEvent>` with a Signal event definition.

  Pipeline: resolve signal name → publish signal (broadcast, no payload) →
  resolve outgoing flows. Apply `in_mappings` if present (these transform
  the token, not a signal payload — signals carry no payload).

  No waiting, no subscription — throw is synchronous.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.SignalPublisher
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.SignalEventHelper
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Types.Token

  @impl true
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  def handle_enter(flow_node, token, context) do
    raw_payload = token.payload || %{}
    in_mappings = Map.get(flow_node.type_data, :in_mappings, [])

    with {:ok, mapped_payload} <-
           MappingHelper.apply_in_mappings(in_mappings, raw_payload, context),
         {:ok, signal_name} <-
           SignalEventHelper.resolve_signal_name(flow_node, context.definitions) do
      publish_and_proceed(flow_node, context, signal_name, mapped_payload)
    end
  end

  defp publish_and_proceed(flow_node, context, signal_name, payload) do
    {:ok, _publish_result} =
      SignalPublisher.publish_signal(%{
        name: signal_name,
        origin: %{
          source: "pi",
          process_instance_id: context.process_instance_id,
          flow_node_instance_id: context.flow_node_instance_id
        }
      })

    case resolve_outgoing(flow_node, context) do
      {:ok, next_ids} ->
        case FniLifecycle.finish(context, flow_node, payload, %{}) do
          {:ok, lifecycle_result} ->
            {:ok,
             %FlowNodeResult{
               output_payload: payload,
               next_flow_node_ids: next_ids,
               metadata: %{persisted: true, lifecycle: lifecycle_result}
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
