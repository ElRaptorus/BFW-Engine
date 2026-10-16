defmodule BfwEngine.Execution.FlowNodes.MessageEventHelper do
  @moduledoc """
  Shared logic used by all message event handlers.

  Extracts message-specific concerns: name resolution and correlation key/value
  evaluation. Contract validation is handled at the flow-node level by each
  handler using direction-aware contracts. Token transformation is
  handled by the generic `inputMapping`/`outputMapping` pipeline.
  """

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext

  @doc """
  Resolve the BPMN message name from a flow node's event definition
  `message_ref` by looking up the global `MessageDefinition` in the
  process model's definitions.

  For events: `flow_node.type_data.event_definition.message_ref`
  For tasks: `flow_node.type_data.message_ref`
  """
  @spec resolve_message_name(FlowNode.t(), Definitions.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_message_name(flow_node, %Definitions{} = definitions) do
    message_ref = extract_message_ref(flow_node)

    case find_message_definition(definitions, message_ref) do
      {:ok, message_def} ->
        if message_def.name && message_def.name != "" do
          {:ok, message_def.name}
        else
          {:error,
           %{
             reason: :message_name_blank,
             detail: "MessageDefinition #{message_ref} has no name"
           }}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Evaluate the process-level `<bfw:correlationKey>` FEEL expression
  against the current handler context and token payload.

  Returns `{:ok, value}` where value is a string, or `{:ok, :none}` if
  no correlation key is defined on the process. FEEL evaluation failures
  return `{:error, {:correlation_expression_failed, reason}}`.
  """
  @spec evaluate_correlation_key(struct(), HandlerContext.t(), map()) ::
          {:ok, String.t() | :none} | {:error, term()}
  def evaluate_correlation_key(process_model, context, token_payload) do
    correlation_key_expression = process_model.correlation_key

    if is_nil(correlation_key_expression) || correlation_key_expression == "" do
      {:ok, :none}
    else
      feel_context = FeelContext.from_handler_context(context, token_payload)

      case Expressions.eval(correlation_key_expression, feel_context) do
        {:ok, value} -> correlation_text(value)
        {:error, reason} -> {:error, {:correlation_expression_failed, reason}}
      end
    end
  rescue
    exception -> {:error, {:correlation_expression_failed, exception}}
  end

  @doc """
  Resolve the correlation value a throw-side handler (Intermediate Throw,
  Message End Event, Send Task) stamps onto the published message.

  `source` carries the `<bfw:correlationRetrievalExpression>`: the
  `EventDefinition.Message` of a throw event, or the
  `FlowNodeData.SendTask` of a Send Task. The expression is evaluated with
  `token` bound to `payload`, the published message body. Without an
  expression, the process-level `<bfw:correlationKey>` is evaluated against
  the same payload. FEEL `null` from either means no correlation value.

  Returns `{:ok, value}`, `{:ok, :none}`, or
  `{:error, {:correlation_expression_failed, reason}}`.
  """
  @spec resolve_throw_correlation(
          EventDefinition.Message.t() | FlowNodeData.SendTask.t(),
          map(),
          HandlerContext.t()
        ) :: {:ok, String.t() | :none} | {:error, term()}
  def resolve_throw_correlation(%{correlation_retrieval_expression: expression}, payload, context)
      when expression in [nil, ""],
      do: evaluate_correlation_key(context.process_model, context, payload)

  def resolve_throw_correlation(%{correlation_retrieval_expression: expression}, payload, context) do
    feel_context = FeelContext.from_handler_context(context, payload)

    case Expressions.eval(expression, feel_context) do
      {:ok, value} -> correlation_text(value)
      {:error, reason} -> {:error, {:correlation_expression_failed, reason}}
    end
  rescue
    exception -> {:error, {:correlation_expression_failed, exception}}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  @feel_temporal_kinds [
    :feel_date,
    :feel_time,
    :feel_datetime,
    :feel_duration_dt,
    :feel_duration_ym
  ]

  # A FEEL date, time, or duration correlates as its ISO 8601 text; FEEL null
  # means no correlation value.
  defp correlation_text(nil), do: {:ok, :none}

  defp correlation_text({kind, text}) when kind in @feel_temporal_kinds and is_binary(text),
    do: {:ok, text}

  defp correlation_text(value) when is_binary(value), do: {:ok, value}
  defp correlation_text(value), do: {:ok, to_string(value)}

  defp extract_message_ref(%FlowNode{type: type, type_data: type_data})
       when type in [:send_task, :receive_task] do
    type_data.message_ref
  end

  defp extract_message_ref(%FlowNode{type_data: type_data}) do
    type_data.event_definition.message_ref
  end

  defp find_message_definition(%Definitions{messages: messages}, message_ref)
       when is_binary(message_ref) do
    case Enum.find(messages, fn msg -> msg.id == message_ref end) do
      nil ->
        {:error,
         %{
           reason: :message_definition_not_found,
           detail: "No MessageDefinition with id=#{message_ref}"
         }}

      message_def ->
        {:ok, message_def}
    end
  end

  defp find_message_definition(_definitions, _message_ref) do
    {:error, %{reason: :no_message_ref, detail: "Flow node has no message_ref"}}
  end
end
