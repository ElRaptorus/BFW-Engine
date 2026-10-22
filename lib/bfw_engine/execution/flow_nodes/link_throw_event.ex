defmodule BfwEngine.Execution.FlowNodes.LinkThrowEvent do
  @moduledoc """
  Handler for Link Intermediate Throw Events.

  Resolves the matching Link Catch Event by `link_name` within the same
  process and routes the token directly to it, bypassing sequence-flow
  resolution. Errors when zero or multiple catches match.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    link_name = flow_node.type_data.event_definition.link_name

    case resolve_link_catch(link_name, flow_node.id, context.process_model) do
      {:ok, catch_node_id} ->
        output_payload = token.payload

        case FniLifecycle.finish(context, flow_node, output_payload, %{}) do
          {:ok, lifecycle_result} ->
            {:ok,
             %FlowNodeResult{
               output_payload: output_payload,
               next_flow_node_ids: [catch_node_id],
               metadata: %{persisted: true, lifecycle: lifecycle_result}
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_link_catch(link_name, throw_node_id, process_model) do
    catches =
      Enum.filter(process_model.flow_nodes, fn node ->
        node.type == :intermediate_catch_event and
          match?(
            %EventDefinition.Link{link_name: ^link_name},
            node.type_data.event_definition
          )
      end)

    case catches do
      [catch_node] ->
        {:ok, catch_node.id}

      [] ->
        {:error,
         %{
           reason: :no_matching_link_catch,
           flow_node_id: throw_node_id,
           link_name: link_name
         }}

      multiple ->
        {:error,
         %{
           reason: :ambiguous_link_catch,
           flow_node_id: throw_node_id,
           link_name: link_name,
           catch_count: length(multiple)
         }}
    end
  end
end
