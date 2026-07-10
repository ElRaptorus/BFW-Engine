defmodule EvilEngine.Execution.FlowNodes.CompensateThrowEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateThrowEvent>` with a Compensation event
  definition.

  Returns `{:compensate, run_spec, FlowNodeResult}`. The PI reacts by
  resolving compensation targets from the registry, parking this FNI as
  `:waiting`, and sequentially dispatching handler activities in reverse
  completion order (LIFO). After all handlers finish, the PI finishes
  this FNI and dispatches its outgoing sequence flows.

  ## Token flow

  The throw FNI continues on its outgoing sequence flow(s) after all
  compensation handlers have completed. This matches BPMN 2.0 §10.6:
  "a compensation intermediate throwing event triggers compensation and
  then the current path of execution continues."
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:compensate, map(), FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    event_definition = flow_node.type_data.event_definition

    with {:ok, targets} <- resolve_outgoing(flow_node, context) do
      next_flow_node_ids = Enum.map(targets, & &1.id)

      run_spec = %{
        throw_type: :throw,
        event_definition: event_definition,
        outgoing_flow_node_ids: next_flow_node_ids
      }

      {:compensate, run_spec,
       %FlowNodeResult{
         output_payload: token.payload,
         next_flow_node_ids: next_flow_node_ids,
         type_properties: %{},
         metadata: %{}
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
