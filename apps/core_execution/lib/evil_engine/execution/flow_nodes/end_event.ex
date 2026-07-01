defmodule EvilEngine.Execution.FlowNodes.EndEvent do
  @moduledoc """
  Handler for untyped `<bpmn:endEvent>`.

  Immediate completion. Stores the End Event's ID and name in
  `type_properties` so the PI can build decorated `FinalToken`
  structs when the PI finishes.

  The PI's post-completion logic checks for zero outgoing flows +
  zero active FNIs to trigger PI termination. The End Event handler
  itself just consumes the token.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    output_payload = token.payload

    type_properties = %{
      end_event_id: flow_node.id,
      end_event_name: flow_node.name
    }

    case FniLifecycle.finish(context, flow_node, output_payload, type_properties) do
      {:ok, lifecycle_result} ->
        {:ok,
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
