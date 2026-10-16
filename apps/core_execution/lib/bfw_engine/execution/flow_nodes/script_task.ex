defmodule BfwEngine.Execution.FlowNodes.ScriptTask do
  @moduledoc """
  Handler for `<bpmn:scriptTask>`.

  Evaluates an inline FEEL expression (`<script>`) or dispatches to a
  plugin-registered named script (`bfw:scriptRef`). When both are set,
  `scriptRef` takes precedence.

  ## Data pipeline

      token -> in_mappings -> payload_contract -> script/plugin -> out_mappings -> result_contract -> PayloadCap -> downstream

  All contract violations and FEEL evaluation failures transition
  the FNI to `:fatal`. Script Tasks are always synchronous — no
  `{:async, ref}` return, no handler parking.

  ## scriptFormat

  Stored for BPMN fidelity and passed through to plugins via
  `flow_node.type_data.script_format`. The engine does not enforce
  its value — inline scripts always evaluate as FEEL.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.ProcessInstance.ErrorInfo
  alias BfwEngine.Execution.ScriptDispatch
  alias BfwEngine.Execution.SequenceFlowResolver
  alias BfwEngine.Expressions
  alias BfwEngine.Expressions.Context, as: FeelContext
  alias BfwEngine.Types.Token

  @spec handle_enter(FlowNode.t(), Token.t(), HandlerContext.t()) ::
          {:ok, FlowNodeResult.t()} | {:error, term()}
  @impl true
  def handle_enter(flow_node, token, context) do
    type_data = flow_node.type_data

    with {:ok, mapped_input} <- apply_input_pipeline(type_data, token.payload, context),
         {:ok, script_output} <- execute_script(flow_node, type_data, mapped_input, context),
         {:ok, mapped_output} <- apply_output_pipeline(type_data, script_output, context),
         {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <- FniLifecycle.finish(context, flow_node, mapped_output, %{}) do
      {:ok,
       %FlowNodeResult{
         output_payload: mapped_output,
         next_flow_node_ids: next_ids,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  defp execute_script(flow_node, %{script_ref: script_ref} = type_data, payload, context)
       when is_binary(script_ref) and script_ref != "" do
    dispatch_to_named_script(flow_node, script_ref, type_data, payload, context)
  end

  defp execute_script(flow_node, %{script: script}, payload, context)
       when is_binary(script) and script != "" do
    evaluate_feel_script(script, payload, flow_node, context)
  end

  defp execute_script(_flow_node, _type_data, _payload, _context) do
    {:error, {:missing_script, "neither script nor scriptRef is set"}}
  end

  defp dispatch_to_named_script(flow_node, script_ref, type_data, payload, context) do
    case ScriptDispatch.adapter().lookup_script(script_ref) do
      {:ok, handler_module} ->
        invoke_named_script(
          handler_module,
          flow_node,
          script_ref,
          %{type_data: type_data},
          payload,
          context
        )

      {:error, :not_found} ->
        {:error, {:no_handler_for_script_ref, script_ref}}
    end
  end

  # A raise in plugin code must reach error boundaries like a returned error,
  # not crash the handler Task (which would fatal the whole instance).
  defp invoke_named_script(
         handler_module,
         flow_node,
         script_ref,
         flow_node_stub,
         payload,
         context
       ) do
    case handler_module.handle_enter(flow_node_stub, payload, context) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} -> {:error, {:named_script_failed, script_ref, reason}}
      other -> {:error, {:invalid_named_script_return, other}}
    end
  catch
    kind, value ->
      {:error,
       ErrorInfo.handler_raised(
         %{flow_node_id: flow_node.id, handler_type: "scriptRef", handler_key: script_ref},
         kind,
         value
       )}
  end

  defp evaluate_feel_script(script, payload, _flow_node, context) do
    feel_context = FeelContext.from_handler_context(context, payload)

    case Expressions.eval(script, feel_context) do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:ok, scalar} ->
        {:ok, %{"result" => scalar}}

      {:error, reason} ->
        {:error, {:script_eval_failed, script, reason}}
    end
  end

  defp apply_input_pipeline(type_data, payload, context) do
    with {:ok, mapped} <- MappingHelper.apply_in_mappings(type_data.in_mappings, payload, context),
         :ok <-
           MappingHelper.validate_contract(
             type_data.payload_contract,
             mapped,
             :script_task_input_contract_violation
           ) do
      {:ok, mapped}
    end
  end

  defp apply_output_pipeline(type_data, output, context) do
    with {:ok, mapped} <-
           MappingHelper.apply_out_mappings(type_data.out_mappings, output, context),
         :ok <-
           MappingHelper.validate_contract(
             type_data.result_contract,
             mapped,
             :script_task_contract_violation
           ) do
      {:ok, mapped}
    end
  end

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
