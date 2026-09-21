defmodule BfwEngine.Execution.FlowNodes.ManualTask do
  @moduledoc """
  Handler for `<bpmn:manualTask>`.

  Pass-through by default. When `bfw:requireConfirmation` is `true`,
  enters `waiting` state — behaves like a minimal User Task requiring
  a `FinishUserTask` call to advance.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.PayloadCap
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:wait, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} ->
        output_payload = token.payload
        next_ids = Enum.map(targets, & &1.id)

        if flow_node.type_data.require_confirmation do
          enter_with_confirmation(context, output_payload, next_ids)
        else
          finish_pass_through(context, flow_node, output_payload, next_ids)
        end

      {:error, reason, meta} ->
        {:error, Map.put(meta, :reason, reason)}
    end
  end

  defp enter_with_confirmation(context, output_payload, next_ids) do
    type_properties = %{require_confirmation: true}

    case FniLifecycle.transition_to_waiting(context, type_properties) do
      :ok ->
        {:wait,
         %FlowNodeResult{
           output_payload: output_payload,
           next_flow_node_ids: next_ids,
           type_properties: type_properties,
           metadata: %{persisted: true}
         }}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}
    end
  end

  defp finish_pass_through(context, flow_node, output_payload, next_ids) do
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
  end

  @spec handle_complete(FlowNode.t(), map(), map(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, :payload_too_large, map()} | {:error, term()}
  @impl true
  def handle_complete(flow_node, _entry, payload, context) do
    with :ok <- PayloadCap.check(payload, field: :user_task_result),
         {:ok, next_flow_node_ids} <- resolve_outgoing(flow_node, context) do
      case FniLifecycle.finish(context, flow_node, payload, %{}) do
        {:ok, lifecycle_result} ->
          {:ok,
           %FlowNodeResult{
             output_payload: payload,
             next_flow_node_ids: next_flow_node_ids,
             metadata: %{persisted: true, lifecycle: lifecycle_result}
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :payload_too_large, details} ->
        {:error, :payload_too_large, details}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec handle_cancel(FlowNode.t(), map(), term(), HandlerContext.t()) :: :ok
  @impl true
  def handle_cancel(_flow_node, _entry, _reason, _context), do: :ok

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
