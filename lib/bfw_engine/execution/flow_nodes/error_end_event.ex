defmodule BfwEngine.Execution.FlowNodes.ErrorEndEvent do
  @moduledoc """
  Handler for `<bpmn:endEvent>` with a `<bpmn:errorEventDefinition>`.

  Returns `{:bpmn_error, error_info, FlowNodeResult}` — the PI reacts by
  persisting the FNI as `:error`, interrupting all remaining active/waiting
  sibling FNIs (same scope behavior as Terminate End Event), transitioning
  the PI to `:error` state, and notifying the parent with structured
  error_info so it can match against attached Boundary Error Events.

  Error resolution priority:
  1. Inline `bfw:errorCode` on the event definition (highest)
  2. Global `<bpmn:error errorCode="...">` referenced by `errorRef`
  3. `nil` (catch-all compatible — any boundary without a filter matches)
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:bpmn_error, map(), FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    error_info = resolve_error_info(flow_node, context)
    output_payload = token.payload

    type_properties = %{
      end_event_id: flow_node.id,
      end_event_name: flow_node.name,
      error_code: error_info[:error_code],
      error_message: error_info[:error_message]
    }

    case FniLifecycle.finish_as_error(context, flow_node, output_payload, type_properties) do
      {:ok, lifecycle_result} ->
        {:bpmn_error, error_info,
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

  defp resolve_error_info(flow_node, context) do
    event_def = flow_node.type_data.event_definition

    inline_code = event_def.error_code
    inline_message = event_def.error_message

    global_code = resolve_global_error_code(event_def.error_ref, context)

    %{
      error_code: inline_code || global_code,
      error_message: inline_message
    }
  end

  defp resolve_global_error_code(nil, _context), do: nil

  defp resolve_global_error_code(error_ref, context) do
    context.definitions.errors
    |> Enum.find(&(&1.id == error_ref))
    |> case do
      nil -> nil
      error_def -> error_def.error_code
    end
  end
end
