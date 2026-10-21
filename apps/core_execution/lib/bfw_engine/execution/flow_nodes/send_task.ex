defmodule BfwEngine.Execution.FlowNodes.SendTask do
  @moduledoc """
  Handler for `<bpmn:sendTask>`.

  Functionally equivalent to `MessageThrowEvent`: publishes the message
  and proceeds. The differences:

  - `message_ref` is on `flow_node.type_data` (not on an event definition)
  - Wrapped by `BoundaryAwareHandler` (it's an activity, so error
    boundaries apply)
  - Data pipeline: `inputMapping` → `payloadContract` → **publish** →
    proceed. The published body is the mapping result; the outgoing token
    is that result merged over the input token.
  - `bfw:correlationRetrievalExpression` sits on the task's own
    `<extensionElements>` (there is no event definition)
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.MessagePublisher
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FlowNodes.MessageEventHelper
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.PayloadCap
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @doc """
  Applies input mappings, enforces PayloadCap, resolves the message name,
  evaluates correlation (retrieval expression with fallback to the
  process-level correlation key), resolves the outgoing sequence flows, and
  publishes the message. A flow resolution failure fatals the task before
  anything is published.
  """
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    raw_payload = token.payload || %{}
    type_data = flow_node.type_data
    in_mappings = Map.get(type_data, :in_mappings, [])

    with {:ok, mapped_payload} <-
           MappingHelper.apply_in_mappings(in_mappings, raw_payload, context),
         :ok <- PayloadCap.check(mapped_payload, field: :message_payload),
         :ok <-
           MappingHelper.validate_contract(
             type_data.payload_contract,
             mapped_payload,
             :payload_contract_violation
           ),
         {:ok, message_name} <-
           MessageEventHelper.resolve_message_name(flow_node, context.definitions),
         {:ok, correlation_value} <-
           MessageEventHelper.resolve_throw_correlation(type_data, mapped_payload, context),
         {:ok, next_ids} <- resolve_outgoing(flow_node, context) do
      publish_message(context, message_name, mapped_payload, correlation_value)

      finish(
        flow_node,
        context,
        next_ids,
        MappingHelper.merge_over_input(raw_payload, mapped_payload)
      )
    else
      {:error, :payload_too_large, details} ->
        {:error, Map.put(details, :reason, :payload_too_large)}

      {:error, _reason} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp publish_message(context, message_name, payload, correlation_value) do
    ets_correlation =
      case correlation_value do
        :none -> nil
        value -> value
      end

    {:ok, _publish_result} =
      MessagePublisher.publish_message(%{
        name: message_name,
        payload: payload,
        correlation_value: ets_correlation,
        origin: %{
          source: "pi",
          process_instance_id: context.process_instance_id,
          flow_node_instance_id: context.flow_node_instance_id
        }
      })

    :ok
  end

  defp finish(flow_node, context, next_ids, outgoing_payload) do
    case FniLifecycle.finish(context, flow_node, outgoing_payload, %{}) do
      {:ok, lifecycle_result} ->
        {:ok,
         %FlowNodeResult{
           output_payload: outgoing_payload,
           next_flow_node_ids: next_ids,
           metadata: %{persisted: true, lifecycle: lifecycle_result}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
