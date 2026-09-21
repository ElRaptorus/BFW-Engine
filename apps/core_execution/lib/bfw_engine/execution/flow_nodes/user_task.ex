defmodule BfwEngine.Execution.FlowNodes.UserTask do
  @moduledoc """
  Handler for `<bpmn:userTask>`.

  Always enters `waiting` state. The PI holds until an external
  `FinishUserTask` or `CancelUserTask` call completes the FNI.

  ## Data pipeline

      token -> in_mappings -> payload_contract -> wait for user -> out_mappings -> result_contract -> PayloadCap -> downstream

  Error semantics differ from ServiceTask:
  - `payload_contract` violation on input -> FNI `:fatal` (upstream data broken, user cannot fix)
  - Corrupt FEEL in input/output mapper -> FNI `:fatal`
  - `result_contract` violation on output -> FNI stays `:waiting` (retryable, user corrects submission)
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  require Logger

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.PayloadCap
  alias BfwEngine.Execution.ProcessInstance.Helpers
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
         {:ok, mapped_input} <- apply_input_pipeline(type_data, token.payload, context) do
      assignees = resolve_assignees(type_data.assignees_expression, token.payload, context)

      type_properties = %{
        form_schema: type_data.form_schema,
        form_actions: type_data.form_actions,
        assignees: assignees,
        result_contract: type_data.result_contract,
        due_date: type_data.due_date,
        priority: type_data.priority
      }

      case FniLifecycle.transition_to_waiting(context, type_properties) do
        :ok ->
          EngineEventBus.publish(%Event.UserTaskCreated{
            flow_node_instance_id: context.flow_node_instance_id,
            process_instance_id: context.process_instance_id,
            root_process_instance_id: context.root_process_instance_id,
            flow_node_id: flow_node.id,
            assignees: assignees,
            lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
            occurred_at: DateTime.utc_now()
          })

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

    with {:ok, mapped_output} <-
           MappingHelper.apply_out_mappings(type_data.out_mappings, payload, context),
         :ok <- validate_result_contract(type_data.result_contract, mapped_output),
         :ok <- PayloadCap.check(mapped_output, field: :user_task_result),
         {:ok, targets} <- resolve_outgoing(flow_node, context) do
      emit_user_task_finished(context, flow_node, :completed)

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

      {:error, {:feel_eval_failed, _source, _reason} = detail} ->
        {:error, {:out_mapping_failed, detail}}

      {:error, violations} ->
        emit_user_task_validation_failed(context, flow_node, violations)
        {:error, {:contract_violation, violations}}
    end
  end

  @spec handle_cancel(FlowNode.t(), map(), term(), HandlerContext.t()) :: :ok
  @impl true
  def handle_cancel(flow_node, _entry, _reason, context) do
    emit_user_task_finished(context, flow_node, :aborted)
    :ok
  end

  # -- Input pipeline: in_mappings -> payload_contract -----------------------

  defp apply_input_pipeline(type_data, payload, context) do
    with {:ok, mapped} <- MappingHelper.apply_in_mappings(type_data.in_mappings, payload, context),
         :ok <- validate_payload_contract(type_data.payload_contract, mapped) do
      {:ok, mapped}
    else
      {:error, {:feel_eval_failed, _source, _reason} = detail} ->
        {:error, {:in_mapping_failed, detail}}

      {:error, violations} ->
        {:error, {:user_task_input_contract_violation, violations}}
    end
  end

  # -- Contract validation ---------------------------------------------------

  defp validate_payload_contract(nil, _payload), do: :ok

  defp validate_payload_contract(contract, payload),
    do: MappingHelper.validate_contract(contract, payload)

  defp validate_result_contract(nil, _payload), do: :ok

  defp validate_result_contract(contract, payload),
    do: MappingHelper.validate_contract(contract, payload)

  # -- Events ----------------------------------------------------------------

  defp emit_user_task_finished(context, flow_node, outcome) do
    EngineEventBus.publish(%Event.UserTaskFinished{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      root_process_instance_id: context.root_process_instance_id,
      flow_node_id: flow_node.id,
      outcome: outcome,
      lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
      occurred_at: DateTime.utc_now()
    })
  end

  defp emit_user_task_validation_failed(context, flow_node, violations) do
    EngineEventBus.publish(%Event.UserTaskValidationFailed{
      flow_node_instance_id: context.flow_node_instance_id,
      process_instance_id: context.process_instance_id,
      flow_node_id: flow_node.id,
      violations: violations,
      lane_name: Helpers.resolve_lane_name_from_context(context, flow_node),
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

  defp resolve_assignees(nil, _token_payload, _context), do: []

  defp resolve_assignees(expression, token_payload, context) do
    feel_context = FeelContext.from_handler_context(context, token_payload)

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
