defmodule BfwEngine.Execution.FlowNodes.UserTask do
  @moduledoc """
  Handler for `<bpmn:userTask>`.

  Always enters `waiting` state. The PI holds until an external
  `finish_user_task` or `cancel_inbox_task` call completes the FNI.

  ## Data pipeline

      token -> in_mappings -> payload_contract -> bfw:dueDate, bfw:assignees -> wait for user ->
      %{"actionId", "values"} -> out_mappings -> result_contract -> PayloadCap -> downstream

  `bfw:dueDate` (unless it is an ISO 8601 date-time or date literal) and
  `bfw:assignees` are evaluated with `token` bound to the mapped input. The
  due date is an ISO 8601 date-time string: an offset literal as written,
  anything else in UTC (offset-less → UTC, date → midnight UTC).

  Error semantics differ from ServiceTask:
  - `payload_contract` violation on input, corrupt FEEL in the input mapper, or a
    `bfw:dueDate` that yields no date or date-time (including `null`)
    (`user_task_due_date_failed`) -> the task fails: Error Boundaries and Error
    Event Subprocess starts may catch it, otherwise the FNI is `:fatal`
  - `result_contract` violation on output -> FNI stays `:waiting` (retryable, user corrects submission)
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  require Logger

  alias BfwEngine.Execution.ProcessInstance.LaneResolution

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.PayloadCap
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:wait, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    type_data = flow_node.type_data

    with {:ok, targets} <- resolve_outgoing(flow_node, context),
         {:ok, mapped_input} <- apply_input_pipeline(type_data, token.payload, context),
         {:ok, due_date} <- resolve_due_date(flow_node, mapped_input, context) do
      assignees = resolve_assignees(type_data.assignees_expression, mapped_input, context)

      type_properties = %{
        form_fields: type_data.form_fields,
        form_actions: type_data.form_actions,
        assignees: assignees,
        result_contract: type_data.result_contract,
        due_date: due_date,
        priority: type_data.priority
      }

      case FniLifecycle.transition_to_waiting(context, type_properties) do
        :ok ->
          {:wait,
           %FlowNodeResult{
             output_payload: mapped_input,
             next_flow_node_ids: Enum.map(targets, & &1.id),
             type_properties: type_properties,
             metadata: %{persisted: true}
           }}

        {:error, :persistence_failed} ->
          {:error, :persistence_failed}
      end
    end
  end

  @spec handle_complete(FlowNode.t(), map(), map(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()} | {:error, :payload_too_large, map()}
  @impl true
  def handle_complete(flow_node, _entry, payload, context) do
    type_data = flow_node.type_data
    values = if is_map(payload), do: payload, else: %{}
    envelope = %{"actionId" => context.user_task_action_id, "values" => values}

    with {:ok, mapped_output} <-
           MappingHelper.apply_out_mappings(type_data.out_mappings, envelope, context),
         :ok <-
           MappingHelper.validate_contract(
             type_data.result_contract,
             mapped_output,
             :contract_violation
           ),
         :ok <- PayloadCap.check(mapped_output, field: :user_task_result),
         {:ok, targets} <- resolve_outgoing(flow_node, context) do
      case FniLifecycle.finish(context, flow_node, mapped_output, %{}) do
        {:ok, lifecycle_result} ->
          {:ok,
           %FlowNodeResult{
             output_payload: mapped_output,
             next_flow_node_ids: Enum.map(targets, & &1.id),
             metadata: %{persisted: true, lifecycle: lifecycle_result}
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :payload_too_large, details} ->
        {:error, :payload_too_large, details}

      {:error, {:contract_violation, violations}} ->
        violations = normalize_violations(violations)
        emit_user_task_validation_failed(context, flow_node, violations)
        {:error, {:contract_violation, violations}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec handle_cancel(FlowNode.t(), map(), term(), HandlerContext.t()) :: :ok
  @impl true
  def handle_cancel(_flow_node, _entry, _reason, _context), do: :ok

  # -- Input pipeline: in_mappings -> payload_contract -----------------------

  defp apply_input_pipeline(type_data, payload, context) do
    with {:ok, mapped} <- MappingHelper.apply_in_mappings(type_data.in_mappings, payload, context),
         :ok <-
           MappingHelper.validate_contract(
             type_data.payload_contract,
             mapped,
             :user_task_input_contract_violation
           ) do
      {:ok, mapped}
    end
  end

  # -- Events ----------------------------------------------------------------

  # An unusable result contract is reported as one violation at the document root, so the finish caller and the
  # event see the same `{message, path}` shape as for a failed constraint.
  defp normalize_violations({:invalid_contract_schema, message}) do
    [%{message: "The contract is not a valid JSON Schema: #{message}", path: "#"}]
  end

  defp normalize_violations(violations) when is_list(violations) do
    Enum.map(violations, fn {message, path} -> %{message: message, path: path} end)
  end

  defp emit_user_task_validation_failed(context, flow_node, violations) do
    EngineEventBus.publish(%Event.UserTaskValidationFailed{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      flow_node_id: flow_node.id,
      violations: violations,
      lane_name: LaneResolution.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })
  end

  # -- Helpers ---------------------------------------------------------------

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, targets}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end

  defp resolve_due_date(%FlowNode{type_data: %{due_date: due_date}}, _mapped_input, _context)
       when due_date in [nil, ""],
       do: {:ok, nil}

  # A literal date-time with an offset is stored as written; any other
  # literal or FEEL result is stored as ISO 8601 UTC.
  defp resolve_due_date(
         %FlowNode{id: flow_node_id, type_data: %{due_date: due_date}},
         mapped_input,
         context
       ) do
    case {DateTime.from_iso8601(due_date), utc_date_time(due_date)} do
      {{:ok, _datetime, _offset}, _utc} -> {:ok, due_date}
      {_with_offset, {:ok, datetime}} -> {:ok, DateTime.to_iso8601(datetime)}
      _not_a_literal -> evaluate_due_date(flow_node_id, due_date, mapped_input, context)
    end
  end

  defp evaluate_due_date(flow_node_id, expression, mapped_input, context) do
    feel_context = FeelContext.from_handler_context(context, mapped_input)

    with {:ok, value} <- Expressions.eval(expression, feel_context),
         {:ok, datetime} <- due_date_from_value(value) do
      {:ok, DateTime.to_iso8601(datetime)}
    else
      {:error, reason} ->
        {:error,
         {:user_task_due_date_failed,
          %{flow_node_id: flow_node_id, expression: expression, reason: reason}}}
    end
  end

  defp due_date_from_value({:feel_date, text} = value) when is_binary(text),
    do: date_value_as_utc(text, value)

  defp due_date_from_value(text) when is_binary(text), do: date_value_as_utc(text, text)
  defp due_date_from_value(value), do: Expressions.to_datetime(value)

  defp date_value_as_utc(text, value) do
    case utc_date_time(text) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:not_a_date_time, value}}
    end
  end

  # An offset-less date-time is read as UTC, a date as midnight UTC.
  defp utc_date_time(text) do
    with {:error, _no_offset} <- date_time_with_offset(text),
         {:error, _not_a_date_time} <- naive_date_time_as_utc(text) do
      date_as_utc_midnight(text)
    end
  end

  defp date_time_with_offset(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp naive_date_time_as_utc(text) do
    with {:ok, naive_date_time} <- NaiveDateTime.from_iso8601(text),
         do: DateTime.from_naive(naive_date_time, "Etc/UTC")
  end

  defp date_as_utc_midnight(text) do
    with {:ok, date} <- Date.from_iso8601(text), do: DateTime.new(date, ~T[00:00:00], "Etc/UTC")
  end

  defp resolve_assignees(nil, _mapped_input, _context), do: []

  defp resolve_assignees(expression, mapped_input, context) do
    feel_context = FeelContext.from_handler_context(context, mapped_input)

    case Expressions.eval(expression, feel_context) do
      {:ok, result} when is_list(result) ->
        result

      {:ok, result} when is_binary(result) ->
        [result]

      {:ok, _other} ->
        []

      {:error, reason} ->
        Logger.warning("UserTask assignees expression failed: #{inspect(reason)}")
        []
    end
  end
end
