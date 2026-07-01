defmodule EvilEngine.Execution.FlowNodes.MessageStartEvent do
  @moduledoc """
  Handler for `<bpmn:startEvent>` with a Message event definition.

  By the time the PI is started, the message payload has already been
  injected as the start token by the `MessagePublisher` catch-wins-over-Start
  logic. The handler is a simple pass-through — identical to the untyped
  `StartEvent` handler.

  The important logic lives in `MessagePublisher` (Phase D2), not here.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Types.Token

  @doc """
  Validates the incoming payload against the result contract,
  then resolves outgoing sequence flows.
  Message Start Events receive the message payload via the PI start
  mechanism (not subscription); the handler is a simple pass-through.
  """
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    output_payload = token.payload

    with :ok <-
           MappingHelper.validate_contract(flow_node.type_data.result_contract, output_payload),
         {:ok, targets} <-
           resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <-
           FniLifecycle.finish(context, flow_node, output_payload, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: output_payload,
         next_flow_node_ids: Enum.map(targets, & &1.id),
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    else
      {:error, violations} when is_list(violations) ->
        {:error, %{reason: :result_contract_violation, violations: violations}}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, targets}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
