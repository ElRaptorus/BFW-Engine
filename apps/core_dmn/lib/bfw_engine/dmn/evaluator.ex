defmodule BfwEngine.DMN.Evaluator do
  @moduledoc """
  Evaluates a single decision within a parsed DMN model.

  ## Usage

      {:ok, result} = Evaluator.evaluate(definitions, "Decision_discount", %{"age" => 25})
      result.result  #=> %{"discount" => 5}
      result.trace   #=> %EvaluationTrace{decisions: [...]}
  """

  alias BfwEngine.DMN.EvaluationResult
  alias BfwEngine.DMN.EvaluationTrace
  alias BfwEngine.DMN.EvaluationTrace.BkmTrace
  alias BfwEngine.DMN.EvaluationTrace.ImportTrace
  alias BfwEngine.DMN.Evaluator.BkmInvoker
  alias BfwEngine.DMN.Evaluator.BoxedExpressionEvaluator
  alias BfwEngine.DMN.Evaluator.DecisionServiceEvaluator
  alias BfwEngine.DMN.Evaluator.DecisionTableEvaluator
  alias BfwEngine.DMN.Evaluator.DependencyResolver
  alias BfwEngine.DMN.Evaluator.HitPolicies
  alias BfwEngine.DMN.ImportResolver
  alias BfwEngine.DMN.Model.BoxedConditional
  alias BfwEngine.DMN.Model.BoxedContext
  alias BfwEngine.DMN.Model.BoxedEvery
  alias BfwEngine.DMN.Model.BoxedFilter
  alias BfwEngine.DMN.Model.BoxedFor
  alias BfwEngine.DMN.Model.BoxedInvocation
  alias BfwEngine.DMN.Model.BoxedList
  alias BfwEngine.DMN.Model.BoxedSome
  alias BfwEngine.DMN.Model.Decision
  alias BfwEngine.DMN.Model.DecisionTable
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.FunctionDefinition
  alias BfwEngine.DMN.Model.InformationRequirement
  alias BfwEngine.DMN.Model.InputData
  alias BfwEngine.DMN.Model.LiteralExpression
  alias BfwEngine.DMN.Model.Relation
  alias BfwEngine.DMN.Model.Types
  alias BfwEngine.DMN.QualifiedReference
  alias BfwEngine.DMN.ServiceEvaluationResult
  alias BfwEngine.DMN.TypeResolver

  @type evaluate_opts :: [
          include_unmatched_details: boolean(),
          import_resolver: ImportResolver.resolver(),
          max_import_depth: non_neg_integer(),
          decision_version_id: String.t() | nil,
          _current_depth: non_neg_integer()
        ]

  @spec evaluate(Definitions.t(), String.t() | nil, map(), evaluate_opts()) ::
          {:ok, EvaluationResult.t()} | {:error, atom(), map()}
  def evaluate(%Definitions{} = definitions, decision_id, input_context, opts \\ []) do
    decision_version_id = Keyword.get(opts, :decision_version_id)

    :telemetry.span(
      [:bfw_engine, :dmn, :evaluate],
      %{decision_model_id: decision_id, decision_version_id: decision_version_id},
      fn ->
        result = do_evaluate(definitions, decision_id, input_context, opts)

        case result do
          {:ok, %EvaluationResult{} = evaluation_result} ->
            metadata = %{
              decision_model_id: decision_id,
              decision_version_id: decision_version_id,
              hit_policy: evaluation_result.hit_policy,
              matched_rule_count: length(evaluation_result.matched_rules),
              decision_count: length(evaluation_result.trace.decisions)
            }

            {result, metadata}

          error ->
            {error, %{decision_model_id: decision_id, decision_version_id: decision_version_id}}
        end
      end
    )
  end

  defp do_evaluate(definitions, decision_id, input_context, opts) do
    start_time = System.monotonic_time(:microsecond)

    with {:ok, coerced_input_context, coercion_traces} <-
           TypeResolver.coerce_input_context_with_trace(definitions, input_context),
         {:ok, target_decision} <- resolve_decision(definitions, decision_id),
         {:ok, evaluation_order} <-
           DependencyResolver.resolve_evaluation_order(target_decision.id, definitions),
         {:ok, resolved_imports} <- resolve_imports_if_needed(definitions, opts),
         {:ok, decision_traces, final_result} <-
           evaluate_decision_chain(
             definitions,
             evaluation_order,
             coerced_input_context,
             resolved_imports,
             opts
           ) do
      target_decision_trace = List.last(decision_traces)
      elapsed = System.monotonic_time(:microsecond) - start_time

      evaluation_result = %EvaluationResult{
        decision_model_id: target_decision.id,
        decision_name: target_decision.name,
        hit_policy: extract_hit_policy(target_decision),
        result: final_result,
        matched_rules: extract_matched_rule_ids(target_decision_trace),
        trace: %EvaluationTrace{
          decisions: decision_traces,
          input_coercions: coercion_traces
        },
        evaluated_at: DateTime.utc_now(),
        duration_microseconds: elapsed,
        definitions_id: definitions.id,
        definitions_namespace: definitions.namespace,
        decision_version_id: Keyword.get(opts, :decision_version_id)
      }

      {:ok, evaluation_result}
    end
  end

  @doc """
  Evaluates a Decision Service within the given DMN model.

  Returns only the output decision results (encapsulated decisions
  are internal and not exposed). Delegates to `DecisionServiceEvaluator`.
  """
  @spec evaluate_service(Definitions.t(), String.t(), map(), evaluate_opts()) ::
          {:ok, ServiceEvaluationResult.t()} | {:error, atom(), map()}
  def evaluate_service(%Definitions{} = definitions, service_id, input_context, opts \\ []) do
    decision_version_id = Keyword.get(opts, :decision_version_id)

    :telemetry.span(
      [:bfw_engine, :dmn, :evaluate],
      %{
        decision_model_id: nil,
        decision_version_id: decision_version_id,
        service_id: service_id
      },
      fn ->
        result = DecisionServiceEvaluator.evaluate(definitions, service_id, input_context, opts)

        case result do
          {:ok, %ServiceEvaluationResult{} = service_result} ->
            metadata = %{
              decision_model_id: nil,
              decision_version_id: decision_version_id,
              service_id: service_id,
              output_decision_count: map_size(service_result.outputs)
            }

            {result, metadata}

          error ->
            {error,
             %{
               decision_model_id: nil,
               decision_version_id: decision_version_id,
               service_id: service_id
             }}
        end
      end
    )
  end

  defp evaluate_decision_chain(definitions, evaluation_order, shared_context, resolved_imports, opts) do
    decisions_by_id = Map.new(definitions.decisions, &{&1.id, &1})
    input_data_by_id = Map.new(definitions.input_data, &{&1.id, &1})

    Enum.reduce_while(evaluation_order, {:ok, [], shared_context}, fn decision_id,
                                                                      {:ok, traces,
                                                                       context} ->
      case Map.fetch(decisions_by_id, decision_id) do
        :error ->
          {:halt,
           {:error, :decision_not_in_chain,
            %{decision_id: decision_id, available_ids: Map.keys(decisions_by_id)}}}

        {:ok, %Decision{} = decision} ->
          evaluate_single_decision_in_chain(decision, context, traces, input_data_by_id,
            decisions_by_id, definitions, resolved_imports, opts)
      end
    end)
    |> case do
      {:ok, reversed_traces, _final_context} ->
        traces = Enum.reverse(reversed_traces)
        %EvaluationTrace.DecisionTrace{result: final_result} = List.last(traces)
        {:ok, traces, final_result}

      {:error, _, _} = error ->
        error

      {:error, _} = error ->
        error
    end
  end

  defp evaluate_single_decision_in_chain(decision, context, traces, input_data_by_id,
         decisions_by_id, definitions, resolved_imports, opts) do
    with :ok <- validate_decision_structure(decision),
         {:ok, decision_context, import_traces, bkm_traces} <-
           build_decision_context(
             context, decision, input_data_by_id, decisions_by_id,
             definitions, resolved_imports, opts
           ),
         {:ok, result, decision_trace} <-
           evaluate_decision(decision, decision_context, definitions, opts) do
      decision_trace = %{decision_trace | import_traces: import_traces, bkm_traces: bkm_traces}
      variable_name = Decision.output_variable_name(decision)
      updated_context = Map.put(context, variable_name, result)
      {:cont, {:ok, [decision_trace | traces], updated_context}}
    else
      {:error, _, _} = error -> {:halt, error}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp build_decision_context(
         shared_context, decision, input_data_by_id, decisions_by_id,
         definitions, resolved_imports, opts
       ) do
    with {:ok, context} <- bind_required_inputs(shared_context, decision, input_data_by_id),
         {:ok, context, reversed_import_traces} <-
           bind_required_decisions(
             context, decision, decisions_by_id,
             definitions, resolved_imports, opts
           ),
         {:ok, context, bkm_traces} <- bind_required_knowledge(context, decision, definitions, resolved_imports) do
      {:ok, context, Enum.reverse(reversed_import_traces), bkm_traces}
    end
  end

  defp bind_required_knowledge(context, %Decision{knowledge_requirements: []}, _definitions, _resolved_imports),
    do: {:ok, context, []}

  defp bind_required_knowledge(context, decision, definitions, resolved_imports) do
    case BkmInvoker.resolve_and_invoke(decision.knowledge_requirements, definitions, context, resolved_imports) do
      {:ok, updated_context, bkm_traces} -> {:ok, updated_context, bkm_traces}
      error -> error
    end
  end

  defp bind_required_inputs(shared_context, decision, input_data_by_id) do
    Enum.reduce_while(
      decision.information_requirements,
      {:ok, shared_context},
      &bind_required_input_requirement(&1, &2, input_data_by_id)
    )
  end

  defp bind_required_input_requirement(
         %InformationRequirement{required_input_id: nil},
         {:ok, context},
         _input_data_by_id
       ),
       do: {:cont, {:ok, context}}

  defp bind_required_input_requirement(
         %InformationRequirement{required_input_id: input_data_id},
         {:ok, context},
         input_data_by_id
       ) do
    case Map.fetch(input_data_by_id, input_data_id) do
      :error ->
        {:halt,
         {:error, :missing_required_input,
          %{input_data_id: input_data_id, input_data_name: input_data_id}}}

      {:ok, %InputData{name: input_data_name}} ->
        verify_required_input_present(context, input_data_id, input_data_name)
    end
  end

  defp verify_required_input_present(context, input_data_id, input_data_name) do
    if Map.has_key?(context, input_data_name) do
      {:cont, {:ok, context}}
    else
      {:halt,
       {:error, :missing_required_input,
        %{input_data_id: input_data_id, input_data_name: input_data_name}}}
    end
  end

  defp bind_required_decisions(shared_context, decision, decisions_by_id, definitions, resolved_imports, opts) do
    Enum.reduce_while(
      decision.information_requirements,
      {:ok, shared_context, []},
      fn requirement, {:ok, context, accumulated_import_traces} ->
        bind_required_decision_requirement(
          requirement, context, accumulated_import_traces, decision, decisions_by_id,
          definitions, resolved_imports, opts
        )
      end
    )
  end

  defp bind_required_decision_requirement(
         %InformationRequirement{required_decision_id: nil},
         context,
         accumulated_import_traces,
         _decision, _decisions_by_id, _definitions, _resolved_imports, _opts
       ),
       do: {:cont, {:ok, context, accumulated_import_traces}}

  defp bind_required_decision_requirement(
         %InformationRequirement{required_decision_id: required_decision_id},
         context,
         accumulated_import_traces,
         decision,
         decisions_by_id,
         definitions,
         resolved_imports,
         opts
       ) do
    if QualifiedReference.imported?(required_decision_id) do
      case evaluate_and_bind_imported_decision(
             required_decision_id, context, decision.id,
             definitions, resolved_imports, opts
           ) do
        {:cont, {:ok, updated_context, import_trace}} ->
          {:cont, {:ok, updated_context, [import_trace | accumulated_import_traces]}}

        {:cont, {:ok, updated_context}} ->
          {:cont, {:ok, updated_context, accumulated_import_traces}}

        {:halt, error} ->
          {:halt, error}
      end
    else
      case bind_local_required_decision(required_decision_id, context, decision, decisions_by_id) do
        {:cont, {:ok, updated_context}} ->
          {:cont, {:ok, updated_context, accumulated_import_traces}}

        {:halt, error} ->
          {:halt, error}
      end
    end
  end

  defp bind_local_required_decision(required_decision_id, context, decision, decisions_by_id) do
    case Map.fetch(decisions_by_id, required_decision_id) do
      :error ->
        {:halt,
         {:error, :missing_required_decision,
          %{decision_id: required_decision_id, required_by: decision.id}}}

      {:ok, required_decision} ->
        variable_name = Decision.output_variable_name(required_decision)

        if Map.has_key?(context, variable_name) do
          {:cont, {:ok, context}}
        else
          {:halt,
           {:error, :missing_required_decision,
            %{decision_id: required_decision_id, required_by: decision.id}}}
        end
    end
  end

  defp evaluate_and_bind_imported_decision(
         qualified_reference, context, requiring_decision_id,
         definitions, resolved_imports, opts
       ) do
    case ImportResolver.resolve_imported_element(qualified_reference, definitions, resolved_imports) do
      {:ok, {:decision, imported_decision}} ->
        imported_definitions = find_definitions_for_namespace(qualified_reference, resolved_imports)
        do_evaluate_imported_decision(
          imported_decision, imported_definitions, context,
          requiring_decision_id, qualified_reference, opts
        )

      {:ok, _other_element_type} ->
        {:cont, {:ok, context}}

      {:error, :import_not_found, metadata} ->
        {:halt, {:error, :import_not_found, metadata}}

      {:error, :element_not_found, metadata} ->
        {:halt,
         {:error, :missing_required_decision,
          %{
            decision_id: qualified_reference,
            required_by: requiring_decision_id,
            detail: metadata
          }}}

      {:error, :invalid_qualified_reference, metadata} ->
        {:halt, {:error, :invalid_qualified_reference, metadata}}
    end
  end

  defp do_evaluate_imported_decision(imported_decision, nil, _context, requiring_decision_id, _qualified_ref, _opts) do
    {:halt,
     {:error, :import_not_found,
      %{namespace: "unknown", required_by: requiring_decision_id, decision_id: imported_decision.id}}}
  end

  defp do_evaluate_imported_decision(imported_decision, imported_definitions, context, _requiring_decision_id, qualified_ref, opts) do
    current_depth = Keyword.get(opts, :_current_depth, 0)
    next_depth = current_depth + 1

    max_depth = Keyword.get_lazy(opts, :max_import_depth, fn ->
      Application.get_env(:core_dmn, :max_import_depth, 10)
    end)

    if next_depth > max_depth do
      {:halt,
       {:error, :max_import_depth_exceeded,
        %{depth: next_depth, max: max_depth, definition_id: imported_definitions.id}}}
    else
      nested_opts = Keyword.put(opts, :_current_depth, next_depth)
      do_evaluate_imported_decision_call(imported_decision, imported_definitions, context, qualified_ref, nested_opts)
    end
  end

  defp do_evaluate_imported_decision_call(imported_decision, imported_definitions, context, qualified_ref, opts) do
    started_at = System.monotonic_time(:microsecond)

    case evaluate(imported_definitions, imported_decision.id, context, opts) do
      {:ok, %EvaluationResult{result: result, trace: evaluation_trace}} ->
        duration = System.monotonic_time(:microsecond) - started_at
        namespace = QualifiedReference.namespace(qualified_ref)

        import_trace = %ImportTrace{
          namespace: namespace,
          decision_id: imported_decision.id,
          source_definitions_id: imported_definitions.id,
          evaluation_trace: evaluation_trace,
          result: result,
          duration_microseconds: duration
        }

        variable_name = Decision.output_variable_name(imported_decision)
        {:cont, {:ok, Map.put(context, variable_name, result), import_trace}}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  defp find_definitions_for_namespace(qualified_reference, resolved_imports) do
    case QualifiedReference.split(qualified_reference) do
      {:imported, namespace, _element_id} -> Map.get(resolved_imports, namespace)
      _ -> nil
    end
  end

  defp resolve_decision(%Definitions{decisions: [single]}, nil), do: {:ok, single}

  defp resolve_decision(%Definitions{decisions: decisions}, nil) when length(decisions) > 1 do
    {:error, :ambiguous_decision, %{message: "Multiple decisions found — specify a decision_id"}}
  end

  defp resolve_decision(%Definitions{decisions: []}, _) do
    {:error, :no_decisions, %{message: "DMN model contains no decisions"}}
  end

  defp resolve_decision(%Definitions{decisions: decisions}, decision_id) do
    case Enum.find(decisions, &(&1.id == decision_id)) do
      nil -> {:error, :decision_not_found, %{decision_id: decision_id}}
      decision -> {:ok, decision}
    end
  end

  # --- Import resolution -----------------------------------------------------

  defp resolve_imports_if_needed(%Definitions{imports: []}, _opts), do: {:ok, %{}}

  defp resolve_imports_if_needed(%Definitions{} = definitions, opts) do
    resolver = Keyword.get_lazy(opts, :import_resolver, &ImportResolver.build_model_cache_resolver/0)
    ImportResolver.resolve_imports(definitions, resolver)
  end

  # --- Decision structure validation -----------------------------------------

  defp validate_decision_structure(%Decision{expression: nil} = decision) do
    {:error, :missing_decision_logic,
     %{decision_id: decision.id, message: "Decision '#{decision.id}' has no value expression"}}
  end

  defp validate_decision_structure(_decision), do: :ok

  # --- Path A: Decision Table -----------------------------------------------

  defp evaluate_decision(
         %Decision{expression: %DecisionTable{} = table} = decision,
         input_context,
         definitions,
         opts
       ) do
    include_unmatched = Keyword.get(opts, :include_unmatched_details, false)
    start_time = System.monotonic_time(:microsecond)

    with {:ok, input_traces, resolved_inputs} <- resolve_input_values(table, input_context),
         :ok <- DecisionTableEvaluator.validate_input_constraints(table.inputs, resolved_inputs),
         {:ok, matched_rules, unmatched_count, matched_traces, unmatched_traces} <-
           match_rules(table, resolved_inputs, include_unmatched),
         {:ok, result} <- HitPolicies.apply(table.hit_policy, table.aggregation, matched_rules, table) do
      elapsed = System.monotonic_time(:microsecond) - start_time
      warnings = TypeResolver.check_output_types(result, table.outputs, definitions)

      decision_trace = %EvaluationTrace.DecisionTrace{
        decision_model_id: decision.id,
        decision_name: decision.name,
        hit_policy: table.hit_policy,
        inputs: input_traces,
        matched_rules: matched_traces,
        unmatched_rules: unmatched_traces,
        unmatched_rules_count: unmatched_count,
        result: result,
        duration_microseconds: elapsed,
        warnings: warnings
      }

      {:ok, result, decision_trace}
    end
  end

  # --- Path B: Literal Expression (G8) --------------------------------------

  defp evaluate_decision(
         %Decision{expression: %LiteralExpression{} = literal} = decision,
         input_context,
         definitions,
         _opts
       ) do
    start_time = System.monotonic_time(:microsecond)

    case eval_expression(literal.compiled_ref, literal.text, input_context) do
      {:ok, result} ->
        elapsed = System.monotonic_time(:microsecond) - start_time

        decision_trace = %EvaluationTrace.DecisionTrace{
          decision_model_id: decision.id,
          decision_name: decision.name,
          hit_policy: :literal,
          inputs: build_non_table_input_traces(decision, input_context, definitions),
          matched_rules: [],
          unmatched_rules_count: 0,
          result: result,
          duration_microseconds: elapsed
        }

        {:ok, result, decision_trace}

      {:error, reason} ->
        {:error, :literal_expression_eval_failed, %{text: literal.text, reason: reason}}
    end
  end

  # --- Path C: Generic boxed expression (CL3) -------------------------------

  defp evaluate_decision(
         %Decision{expression: expression} = decision,
         input_context,
         definitions,
         _opts
       ) do
    start_time = System.monotonic_time(:microsecond)

    case evaluate_expression_body(expression, input_context, definitions) do
      {:ok, result, bkm_traces} ->
        elapsed = System.monotonic_time(:microsecond) - start_time

        decision_trace = %EvaluationTrace.DecisionTrace{
          decision_model_id: decision.id,
          decision_name: decision.name,
          hit_policy: :boxed_expression,
          inputs: build_non_table_input_traces(decision, input_context, definitions),
          matched_rules: [],
          unmatched_rules_count: 0,
          result: result,
          duration_microseconds: elapsed,
          bkm_traces: bkm_traces
        }

        {:ok, result, decision_trace}

      {:error, _, _} = error ->
        error
    end
  end

  # === Recursive expression body evaluation (CL3) ===========================

  @doc """
  Evaluates any DMN expression body (DecisionTable, LiteralExpression,
  or any CL3 boxed expression type) within the given evaluation context.

  Used internally by the evaluator and externally by `BkmInvoker` for
  CL3 BKM bodies that are not plain decision tables or literal expressions.
  """
  @spec evaluate_expression_body(Types.expression_body(), map(), Definitions.t()) ::
          {:ok, term(), [BkmTrace.t()]} | {:error, atom(), map()}
  def evaluate_expression_body(%DecisionTable{} = table, context, definitions) do
    with {:ok, _traces, resolved_inputs} <- resolve_input_values(table, context),
         :ok <- DecisionTableEvaluator.validate_input_constraints(table.inputs, resolved_inputs),
         {:ok, matched_rules, _unmatched_count, _matched_traces, _unmatched_traces} <-
           match_rules(table, resolved_inputs, false),
         {:ok, result} <- HitPolicies.apply(table.hit_policy, table.aggregation, matched_rules, table) do
      warnings = TypeResolver.check_output_types(result, table.outputs, definitions)
      _ = warnings
      {:ok, result, []}
    end
  end

  def evaluate_expression_body(%LiteralExpression{} = literal, context, _definitions) do
    case eval_expression(literal.compiled_ref, literal.text, context) do
      {:ok, value} -> {:ok, value, []}
      {:error, reason} -> {:error, :literal_expression_eval_failed, %{text: literal.text, reason: reason}}
    end
  end

  def evaluate_expression_body(%BoxedContext{} = boxed_context, context, definitions) do
    BoxedExpressionEvaluator.evaluate_context(boxed_context, context, definitions)
  end

  def evaluate_expression_body(%BoxedInvocation{} = invocation, context, definitions) do
    BoxedExpressionEvaluator.evaluate_invocation(invocation, context, definitions)
  end

  def evaluate_expression_body(%BoxedList{} = list, context, definitions) do
    BoxedExpressionEvaluator.evaluate_list(list, context, definitions)
  end

  def evaluate_expression_body(%Relation{} = relation, context, definitions) do
    BoxedExpressionEvaluator.evaluate_relation(relation, context, definitions)
  end

  def evaluate_expression_body(%FunctionDefinition{} = function_definition, _context, _definitions) do
    {:ok, {:function, function_definition}, []}
  end

  def evaluate_expression_body(%BoxedConditional{} = conditional, context, definitions) do
    BoxedExpressionEvaluator.evaluate_conditional(conditional, context, definitions)
  end

  def evaluate_expression_body(%BoxedFilter{} = boxed_filter, context, definitions) do
    BoxedExpressionEvaluator.evaluate_filter(boxed_filter, context, definitions)
  end

  def evaluate_expression_body(%BoxedFor{} = boxed_for, context, definitions) do
    BoxedExpressionEvaluator.evaluate_for(boxed_for, context, definitions)
  end

  def evaluate_expression_body(%BoxedEvery{} = boxed_every, context, definitions) do
    BoxedExpressionEvaluator.evaluate_every(boxed_every, context, definitions)
  end

  def evaluate_expression_body(%BoxedSome{} = boxed_some, context, definitions) do
    BoxedExpressionEvaluator.evaluate_some(boxed_some, context, definitions)
  end

  def evaluate_expression_body(unsupported, _context, _definitions) do
    {:error, :unsupported_expression, %{type: unsupported.__struct__}}
  end

  # --- Input value resolution ------------------------------------------------

  defp resolve_input_values(table, input_context) do
    results =
      Enum.map(table.inputs, fn input ->
        expression = input.input_expression || input.label || input.id

        case eval_input_expression(input, expression, input_context) do
          {:ok, value} ->
            trace = %EvaluationTrace.InputTrace{
              input_id: input.id,
              input_label: input.label,
              expression: expression,
              resolved_value: value
            }

            {:ok, value, trace}

          {:error, reason} ->
            {:error, :input_expression_eval_failed, %{expression: expression, reason: reason}}
        end
      end)

    case Enum.find(results, &match?({:error, _, _}, &1)) do
      {:error, _, _} = error ->
        error

      nil ->
        values = Enum.map(results, fn {:ok, value, _trace} -> value end)
        traces = Enum.map(results, fn {:ok, _value, trace} -> trace end)
        {:ok, traces, values}
    end
  end

  # --- Rule matching ---------------------------------------------------------

  defp match_rules(table, resolved_inputs, include_unmatched) do
    {matched, unmatched_count, matched_traces, unmatched_traces} =
      table.rules
      |> Enum.with_index()
      |> Enum.reduce({[], 0, [], []}, fn {rule, index},
                                         {matched_acc, unmatched_acc, matched_traces_acc, unmatched_traces_acc} ->
        case evaluate_rule(rule, index, table.inputs, table.outputs, resolved_inputs) do
          {:match, output_values, entry_traces} ->
            rule_trace = %EvaluationTrace.RuleTrace{
              rule_id: rule.id,
              rule_index: index,
              description: rule.description,
              input_evaluations: entry_traces,
              output_values: output_values
            }

            {[{rule, output_values} | matched_acc], unmatched_acc,
             [rule_trace | matched_traces_acc], unmatched_traces_acc}

          {:no_match, entry_traces} ->
            accumulate_unmatched(
              rule, index, entry_traces, include_unmatched,
              matched_acc, unmatched_acc, matched_traces_acc, unmatched_traces_acc
            )
        end
      end)

    {:ok, Enum.reverse(matched), unmatched_count,
     Enum.reverse(matched_traces), Enum.reverse(unmatched_traces)}
  end

  defp accumulate_unmatched(rule, index, entry_traces, true,
         matched_acc, unmatched_acc, matched_traces_acc, unmatched_traces_acc) do
    rule_trace = %EvaluationTrace.RuleTrace{
      rule_id: rule.id,
      rule_index: index,
      description: rule.description,
      input_evaluations: entry_traces,
      output_values: %{}
    }

    {matched_acc, unmatched_acc + 1, matched_traces_acc, [rule_trace | unmatched_traces_acc]}
  end

  defp accumulate_unmatched(_rule, _index, _entry_traces, false,
         matched_acc, unmatched_acc, matched_traces_acc, unmatched_traces_acc) do
    {matched_acc, unmatched_acc + 1, matched_traces_acc, unmatched_traces_acc}
  end

  defp evaluate_rule(rule, _index, inputs, outputs, resolved_inputs) do
    entry_results =
      rule.input_entries
      |> Enum.zip(inputs)
      |> Enum.zip(resolved_inputs)
      |> Enum.map(fn {{entry, input}, value} ->
        matched = evaluate_input_entry(entry, value)

        trace = %EvaluationTrace.InputEntryTrace{
          input_id: input.id,
          expression: entry.text,
          tested_value: value,
          matched: matched
        }

        {matched, trace}
      end)

    all_matched = Enum.all?(entry_results, fn {matched, _trace} -> matched end)
    traces = Enum.map(entry_results, fn {_matched, trace} -> trace end)

    if all_matched do
      output_values = evaluate_output_entries(rule.output_entries, outputs)
      {:match, output_values, traces}
    else
      {:no_match, traces}
    end
  end

  defdelegate evaluate_input_entry(input_entry, value), to: DecisionTableEvaluator
  defdelegate evaluate_output_entries(output_entries, outputs), to: DecisionTableEvaluator

  @doc false
  defdelegate named_output_key(output, index), to: DecisionTableEvaluator

  defp eval_input_expression(input, display_expression, input_context) do
    DecisionTableEvaluator.eval_input_expression(input, display_expression, input_context)
  end

  defp eval_expression(reference, text, context) do
    DecisionTableEvaluator.eval_expression(reference, text, context)
  end

  # --- Helpers ---------------------------------------------------------------

  defp extract_hit_policy(%Decision{expression: %DecisionTable{hit_policy: hit_policy}}),
    do: hit_policy

  defp extract_hit_policy(%Decision{expression: %LiteralExpression{}}), do: :literal
  defp extract_hit_policy(%Decision{expression: _expression}), do: :boxed_expression
  defp extract_hit_policy(_), do: :unknown

  defp extract_matched_rule_ids(%EvaluationTrace.DecisionTrace{matched_rules: traces}) do
    Enum.map(traces, & &1.rule_id)
  end

  defp build_non_table_input_traces(
         %Decision{information_requirements: requirements},
         input_context,
         %Definitions{} = definitions
       ) do
    relevant_variable_names = resolve_required_variable_names(requirements, definitions)

    entries =
      if MapSet.size(relevant_variable_names) == 0 do
        input_context
      else
        Enum.filter(input_context, fn {key, _value} ->
          MapSet.member?(relevant_variable_names, to_string(key))
        end)
      end

    Enum.map(entries, fn {key, value} ->
      %EvaluationTrace.InputTrace{
        input_id: to_string(key),
        input_label: to_string(key),
        expression: to_string(key),
        resolved_value: value
      }
    end)
  end

  defp resolve_required_variable_names(requirements, definitions) do
    input_data_by_id = Map.new(definitions.input_data, &{&1.id, &1})
    decisions_by_id = Map.new(definitions.decisions, &{&1.id, &1})

    requirements
    |> Enum.map(&resolve_requirement_variable_name(&1, input_data_by_id, decisions_by_id))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp resolve_requirement_variable_name(requirement, input_data_by_id, _decisions_by_id)
       when requirement.required_input_id != nil do
    case Map.get(input_data_by_id, requirement.required_input_id) do
      %InputData{name: name} -> name
      nil -> nil
    end
  end

  defp resolve_requirement_variable_name(requirement, _input_data_by_id, decisions_by_id)
       when requirement.required_decision_id != nil do
    case Map.get(decisions_by_id, requirement.required_decision_id) do
      %Decision{} = decision -> Decision.output_variable_name(decision)
      nil -> nil
    end
  end

  defp resolve_requirement_variable_name(_requirement, _input_data_by_id, _decisions_by_id),
    do: nil

end
