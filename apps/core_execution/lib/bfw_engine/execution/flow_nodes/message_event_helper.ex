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
        {:ok, value} when is_binary(value) -> {:ok, value}
        {:ok, value} -> {:ok, to_string(value)}
        {:error, reason} -> {:error, {:correlation_expression_failed, reason}}
      end
    end
  rescue
    exception -> {:error, {:correlation_expression_failed, exception}}
  end

  @doc """
  Evaluate the `<bfw:correlationRetrievalExpression>` from an event definition
  against a payload. Used by throw-side handlers to extract the correlation
  value from the outgoing message payload.

  Returns `{:ok, value}` or `{:ok, :none}` if no expression is defined.
  FEEL evaluation failures return `{:error, {:correlation_expression_failed, reason}}`.
  """
  @spec evaluate_correlation_retrieval_expression(EventDefinition.Message.t(), map(), map()) ::
          {:ok, String.t() | :none} | {:error, term()}
  def evaluate_correlation_retrieval_expression(event_definition, _payload, feel_context) do
    expression = event_definition.correlation_retrieval_expression

    if is_nil(expression) || expression == "" do
      {:ok, :none}
    else
      case Expressions.eval(expression, feel_context) do
        {:ok, value} when is_binary(value) -> {:ok, value}
        {:ok, value} -> {:ok, to_string(value)}
        {:error, reason} -> {:error, {:correlation_expression_failed, reason}}
      end
    end
  rescue
    exception -> {:error, {:correlation_expression_failed, exception}}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

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
