defmodule EvilEngine.Execution.FlowNodes.SignalEndEvent do
  @moduledoc """
  Handler for `<bpmn:endEvent>` with a Signal event definition.

  Same signal publishing as `SignalThrowEvent`, but returns empty
  `next_flow_node_ids` (end events have no outgoing flows) and
  populates `type_properties` with `end_event_id` and `end_event_name`
  for `FinalToken` decoration.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.SignalPublisher
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes.SignalEventHelper
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Types.Token

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
      publish_and_finish(flow_node, context, signal_name, mapped_payload)
    end
  end

  defp publish_and_finish(flow_node, context, signal_name, payload) do
    {:ok, _publish_result} =
      SignalPublisher.publish_signal(%{
        name: signal_name,
        origin: %{
          source: "pi",
          process_instance_id: context.process_instance_id,
          flow_node_instance_id: context.flow_node_instance_id
        }
      })

    type_properties = %{
      end_event_id: flow_node.id,
      end_event_name: flow_node.name
    }

    case FniLifecycle.finish(context, flow_node, payload, type_properties) do
      {:ok, lifecycle_result} ->
        {:ok,
         %FlowNodeResult{
           output_payload: payload,
           next_flow_node_ids: [],
           type_properties: type_properties,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
