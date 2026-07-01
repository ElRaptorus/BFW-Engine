defmodule EvilEngine.Execution.FlowNodes.TerminateEndEvent do
  @moduledoc """
  Handler for `<bpmn:endEvent>` with a `<bpmn:terminateEventDefinition>`.

  Returns `{:terminate, FlowNodeResult}` — the PI reacts by finishing
  this FNI normally and then interrupting all remaining active/waiting
  FNIs, causing the process instance to complete immediately with the
  terminate token as part of the final result.

  The handler is intentionally minimal: the `{:terminate, ...}` tuple
  is the only thing that distinguishes it from a plain EndEvent. All
  PI-scope termination logic lives in `ProcessInstance`.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:terminate, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    output_payload = token.payload

    type_properties = %{
      end_event_id: flow_node.id,
      end_event_name: flow_node.name
    }

    case FniLifecycle.finish(context, flow_node, output_payload, type_properties) do
      {:ok, lifecycle_result} ->
        {:terminate,
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
