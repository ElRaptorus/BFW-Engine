defmodule BfwEngine.Execution.FlowNodes.BusinessRuleTask do
  @moduledoc """
  Handler for `<bpmn:businessRuleTask>`.

  Two execution modes selected by the standard BPMN `implementation`
  attribute:

  - `"feel"` — Evaluate an inline FEEL expression from `<bpmn:script>`.
    Same evaluation path as ScriptTask's inline mode.
  - `"dmn"` — Resolve a deployed DMN model via `DecisionResolver`, load
    its parsed AST from `DMN.ModelCache`, and evaluate via
    `DMN.Evaluator.evaluate/4`. The evaluation runs in a supervised
    `Task` with a configurable timeout (`:dmn_evaluation_timeout_ms`,
    default 30 s). The full `EvaluationResult` — including hit policy,
    matched rules, and the structured trace — is stored in the
    FNI's `type_properties` for auditing and debugger consumption.

  Plugin delegation (`implementation="plugin"`) was removed in Business Rule Tasks exclusively evaluate business rules via FEEL or
  DMN. Plugins observe BRT execution via engine events and analyze
  results through the facade — they never replace the execution path.

  ## Data pipeline

      token -> in_mappings -> payload_contract -> mode dispatch -> out_mappings -> result_contract -> PayloadCap -> downstream

  DMN dispatch sub-pipeline:

      DecisionResolver -> ModelCache.fetch -> Evaluator.evaluate (Task timeout)
        -> result_variable wrapping -> type_properties assembly

  All contract violations, evaluation failures, and timeouts transition
  the FNI to `:fatal`. Business Rule Tasks are always synchronous.
  """

  @behaviour BfwEngine.Execution.FlowNodeHandler

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.DMN
  alias BfwEngine.DMN.EvaluationResult
  alias BfwEngine.DMN.EvaluationTrace
  alias BfwEngine.Execution.DecisionResolver
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.MappingHelper
  alias BfwEngine.Execution.PayloadCap
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
         {:ok, result_output, type_properties} <-
           dispatch_mode(flow_node, type_data, mapped_input, context),
         {:ok, mapped_output} <- apply_output_pipeline(type_data, result_output, context),
         :ok <- PayloadCap.check(mapped_output, field: :business_rule_result),
         {:ok, next_ids} <- resolve_outgoing(flow_node, context),
         {:ok, lifecycle_result} <-
           FniLifecycle.finish(context, flow_node, mapped_output, type_properties) do
      {:ok,
       %FlowNodeResult{
         output_payload: mapped_output,
         next_flow_node_ids: next_ids,
         type_properties: type_properties,
         metadata: %{persisted: true, lifecycle: lifecycle_result}
       }}
    end
  end

  # -- Mode dispatch ----------------------------------------------------------

  defp dispatch_mode(flow_node, %{implementation: "feel"} = type_data, payload, context) do
    evaluate_feel(type_data.script, payload, flow_node, context)
  end

  defp dispatch_mode(_flow_node, %{implementation: "dmn"} = type_data, payload, _context) do
    dispatch_dmn(type_data, payload)
  end

  defp dispatch_mode(_flow_node, %{implementation: implementation}, _payload, _context) do
    {:error, {:unknown_brt_implementation, implementation}}
  end

  # -- FEEL mode --------------------------------------------------------------

  defp evaluate_feel(nil, _payload, _flow_node, _context) do
    {:error, {:missing_script, "implementation='feel' but no <script> element present"}}
  end

  defp evaluate_feel("", _payload, _flow_node, _context) do
    {:error, {:missing_script, "implementation='feel' but <script> element is blank"}}
  end

  defp evaluate_feel(script, payload, _flow_node, context) do
    feel_context = FeelContext.from_handler_context(context, payload)

    case Expressions.eval(script, feel_context) do
      {:ok, result} when is_map(result) ->
        {:ok, result, %{mode: "feel"}}

      {:ok, scalar} ->
        {:ok, %{"result" => scalar}, %{mode: "feel"}}

      {:error, reason} ->
        {:error, {:script_eval_failed, script, reason}}
    end
  end

  # -- DMN mode ---------------------------------------------------------------

  defp dispatch_dmn(type_data, payload) do
    with {:ok, resolved} <- resolve_decision(type_data.decision_ref),
         {:ok, definitions} <- fetch_model(resolved.decision_version_id),
         {:ok, evaluation_result} <-
           evaluate_with_timeout(definitions, payload, type_data, resolved.decision_version_id) do
      result_output = shape_result(evaluation_result.result, type_data.result_variable)

      type_properties = %{
        mode: "dmn",
        decision_ref: type_data.decision_ref,
        decision_element_id: type_data.decision_element_id,
        decision_version_id: resolved.decision_version_id,
        definitions_id: evaluation_result.definitions_id,
        definitions_namespace: evaluation_result.definitions_namespace,
        version: resolved.version,
        hit_policy: Atom.to_string(evaluation_result.hit_policy),
        matched_rules: evaluation_result.matched_rules,
        trace: EvaluationTrace.to_json_map(evaluation_result.trace),
        duration_us: evaluation_result.duration_microseconds
      }

      {:ok, result_output, type_properties}
    end
  end

  defp resolve_decision(decision_ref) do
    case DecisionResolver.adapter().resolve_latest_version(decision_ref) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, :decision_definition_not_found} ->
        {:error, {:decision_not_found, decision_ref}}

      {:error, :no_version_available} ->
        {:error, {:decision_version_not_found, decision_ref}}

      {:error, :decision_disabled} ->
        {:error, {:decision_disabled, decision_ref}}

      {:error, reason} ->
        {:error, {:decision_resolution_failed, reason}}
    end
  end

  defp fetch_model(decision_version_id) do
    case DMN.ModelCache.fetch(decision_version_id) do
      {:ok, definitions} -> {:ok, definitions}
      {:error, reason} -> {:error, {:dmn_cache_load_failed, reason}}
    end
  end

  defp evaluate_with_timeout(definitions, payload, type_data, decision_version_id) do
    timeout = Application.get_env(:core_execution, :dmn_evaluation_timeout_ms, 30_000)

    evaluator_opts = [
      include_unmatched_details: type_data.trace_unmatched_rules,
      decision_version_id: decision_version_id
    ]

    decision_element_id = type_data.decision_element_id

    task =
      Task.async(fn ->
        DMN.Evaluator.evaluate(definitions, decision_element_id, payload, evaluator_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, %EvaluationResult{} = result}} ->
        {:ok, result}

      {:ok, {:error, error_type, metadata}} ->
        {:error, {:dmn_evaluation_failed, error_type, metadata}}

      {:ok, {:error, reason}} ->
        {:error, {:dmn_evaluation_failed, reason}}

      nil ->
        {:error,
         {:dmn_evaluation_timeout, %{timeout_ms: timeout, decision_ref: type_data.decision_ref}}}
    end
  end

  defp shape_result(result, nil) when is_map(result), do: result
  defp shape_result(result, nil), do: %{"result" => result}
  defp shape_result(result, result_variable), do: %{result_variable => result}

  # -- Input pipeline: in_mappings -> payload_contract ------------------------

  defp apply_input_pipeline(type_data, payload, context) do
    with {:ok, mapped} <- MappingHelper.apply_in_mappings(type_data.in_mappings, payload, context),
         :ok <- validate_contract(type_data.payload_contract, mapped) do
      {:ok, mapped}
    else
      {:error, {:feel_eval_failed, _source, _reason} = detail} ->
        {:error, {:in_mapping_failed, detail}}

      {:error, violations} ->
        {:error, {:business_rule_task_contract_violation, violations}}
    end
  end

  # -- Output pipeline: out_mappings -> result_contract -----------------------

  defp apply_output_pipeline(type_data, output, context) do
    with {:ok, mapped} <-
           MappingHelper.apply_out_mappings(type_data.out_mappings, output, context),
         :ok <- validate_contract(type_data.result_contract, mapped) do
      {:ok, mapped}
    else
      {:error, {:feel_eval_failed, _source, _reason} = detail} ->
        {:error, {:out_mapping_failed, detail}}

      {:error, violations} ->
        {:error, {:business_rule_task_contract_violation, violations}}
    end
  end

  # -- Contract validation ----------------------------------------------------

  defp validate_contract(nil, _payload), do: :ok

  defp validate_contract(contract, payload),
    do: MappingHelper.validate_contract(contract, payload)

  # -- Helpers ----------------------------------------------------------------

  defp resolve_outgoing(flow_node, context) do
    case SequenceFlowResolver.resolve(flow_node, context.process_model) do
      {:ok, targets} -> {:ok, Enum.map(targets, & &1.id)}
      {:error, reason, meta} -> {:error, Map.put(meta, :reason, reason)}
    end
  end
end
