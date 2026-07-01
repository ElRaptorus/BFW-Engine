defmodule EvilEngine.Execution.FlowNodes.MessageThrowEvent do
  @moduledoc """
  Handler for `<bpmn:intermediateThrowEvent>` with a Message event definition.

  Pipeline: apply `inputMapping` → validate `payloadContract` →
  evaluate `correlationRetrievalExpression` → publish → resolve outgoing flows.

  No waiting, no subscription — throw is synchronous.
  """

  @behaviour EvilEngine.Execution.FlowNodeHandler

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.Events.MessagePublisher
  alias EvilEngine.Execution.FlowNodeResult
  alias EvilEngine.Execution.FlowNodes.MessageEventHelper
  alias EvilEngine.Execution.FniLifecycle
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.MappingHelper
  alias EvilEngine.Execution.PayloadCap
  alias EvilEngine.Execution.SequenceFlowResolver
  alias EvilEngine.Expressions.Context, as: FeelContext
  alias EvilEngine.Types.Token

  # -------------------------------------------------------------------
  # FlowNodeHandler callbacks
  # -------------------------------------------------------------------

  @doc """
  Applies input mappings, enforces PayloadCap, resolves the message name,
  validates the payload contract, evaluates correlation (retrieval expression
  with fallback to process-level correlationKey), publishes the message, and
  resolves outgoing sequence flows.
  """
  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    event_definition = flow_node.type_data.event_definition
    raw_payload = token.payload || %{}
    in_mappings = Map.get(flow_node.type_data, :in_mappings, [])

    with {:ok, mapped_payload} <-
           MappingHelper.apply_in_mappings(in_mappings, raw_payload, context),
         :ok <- PayloadCap.check(mapped_payload, field: :message_payload),
         {:ok, message_name} <-
           MessageEventHelper.resolve_message_name(flow_node, context.definitions),
         :ok <-
           MappingHelper.validate_contract(flow_node.type_data.payload_contract, mapped_payload),
         {:ok, correlation_value} <-
           resolve_throw_correlation(event_definition, mapped_payload, context) do
      publish_and_proceed(flow_node, context, message_name, mapped_payload, correlation_value)
    else
      {:error, :payload_too_large, details} ->
        {:error, Map.put(details, :reason, :payload_too_large)}

      {:error, violations} when is_list(violations) ->
        {:error, %{reason: :payload_contract_violation, violations: violations}}

      {:error, _reason} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp resolve_throw_correlation(event_definition, payload, context) do
    feel_context = FeelContext.from_handler_context(context, payload)

    case MessageEventHelper.evaluate_correlation_retrieval_expression(
           event_definition,
           payload,
           feel_context
         ) do
      {:ok, :none} ->
        MessageEventHelper.evaluate_correlation_key(context.process_model, context, payload)

      result ->
        result
    end
  end

  defp publish_and_proceed(flow_node, context, message_name, payload, correlation_value) do
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
