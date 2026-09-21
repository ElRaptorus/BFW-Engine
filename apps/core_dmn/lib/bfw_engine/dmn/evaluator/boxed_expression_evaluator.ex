defmodule BfwEngine.DMN.Evaluator.BoxedExpressionEvaluator do
  @moduledoc """
  Evaluates CL3 boxed expressions: Context, List, Relation,
  Conditional, Filter, For, Every, Some, and Invocation.

  Each function returns `{:ok, value, bkm_traces}` where `bkm_traces`
  is a list of `BkmTrace` structs collected from nested BoxedInvocation
  evaluations. Non-invocation expressions propagate traces from their
  sub-expressions unchanged.

  All recursive expression evaluation is delegated back to
  `Evaluator.evaluate_expression_body/3` to maintain the single
  dispatch point for all expression types.
  """

  alias BfwEngine.DMN.EvaluationTrace.BkmTrace
  alias BfwEngine.DMN.Evaluator, as: DmnEvaluator
  alias BfwEngine.DMN.Evaluator.BkmInvoker
  alias BfwEngine.DMN.Model.BoxedConditional
  alias BfwEngine.DMN.Model.BoxedContext
  alias BfwEngine.DMN.Model.BoxedEvery
  alias BfwEngine.DMN.Model.BoxedFilter
  alias BfwEngine.DMN.Model.BoxedFor
  alias BfwEngine.DMN.Model.BoxedInvocation
  alias BfwEngine.DMN.Model.BoxedList
  alias BfwEngine.DMN.Model.BoxedSome
  alias BfwEngine.DMN.Model.Definitions
  alias BfwEngine.DMN.Model.KnowledgeRequirement
  alias BfwEngine.DMN.Model.Relation

  @type traced_result :: {:ok, term(), [BkmTrace.t()]} | {:error, atom(), map()}

  # --- Boxed Context ----------------------------------------------------------

  @spec evaluate_context(BoxedContext.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_context(%BoxedContext{context_entries: entries}, context, definitions) do
    result =
      Enum.reduce_while(entries, {:ok, context, :all_named, []}, fn entry, accumulator ->
        fold_context_entry(entry, accumulator, definitions)
      end)

    case result do
      {:ok, final_context, :all_named, traces} ->
        context_only = Map.drop(final_context, Map.keys(context))
        {:ok, context_only, traces}

      {:ok, _final_context, {:result_value, value}, traces} ->
        {:ok, value, traces}

      {:error, _, _} = error ->
        error
    end
  end

  defp fold_context_entry(entry, {:ok, accumulated_context, _last_result, accumulated_traces}, definitions) do
    case DmnEvaluator.evaluate_expression_body(entry.expression, accumulated_context, definitions) do
      {:ok, value, new_traces} ->
        {:cont, apply_context_entry_value(entry, accumulated_context, value, accumulated_traces ++ new_traces)}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  defp apply_context_entry_value(%{variable: nil}, accumulated_context, value, traces) do
    {:ok, accumulated_context, {:result_value, value}, traces}
  end

  defp apply_context_entry_value(%{variable: %{name: variable_name}}, accumulated_context, value, traces) do
    {:ok, Map.put(accumulated_context, variable_name, value), :all_named, traces}
  end

  # --- Boxed Invocation -------------------------------------------------------

  @spec evaluate_invocation(BoxedInvocation.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_invocation(%BoxedInvocation{} = invocation, context, definitions) do
    bkm_lookup = build_bkm_lookup(definitions.business_knowledge_models)

    with {:ok, bkm} <- fetch_bkm_by_name(bkm_lookup, invocation.called_function),
         {:ok, bound_params, binding_traces} <- evaluate_invocation_bindings(invocation.bindings, context, definitions),
         {:ok, result_context, bkm_traces} <-
           BkmInvoker.resolve_and_invoke(
             [%KnowledgeRequirement{required_knowledge_id: bkm.id}],
             definitions,
             Map.merge(context, bound_params)
           ) do
      bkm_variable = BkmInvoker.output_variable_name(bkm)
      {:ok, Map.get(result_context, bkm_variable), binding_traces ++ bkm_traces}
    end
  end

  defp build_bkm_lookup(bkms) do
    Enum.reduce(bkms, %{}, fn bkm, lookup ->
      lookup
      |> Map.put_new(bkm.name, bkm)
      |> Map.put_new(bkm.id, bkm)
      |> Map.put_new(BkmInvoker.output_variable_name(bkm), bkm)
    end)
  end

  defp fetch_bkm_by_name(bkm_lookup, called_function) do
    case Map.fetch(bkm_lookup, called_function) do
      {:ok, bkm} -> {:ok, bkm}
      :error -> {:error, :bkm_not_found, %{bkm_id: called_function}}
    end
  end

  defp evaluate_invocation_bindings(bindings, context, definitions) do
    Enum.reduce_while(bindings, {:ok, %{}, []}, fn binding, {:ok, accumulated, accumulated_traces} ->
      fold_invocation_binding(binding, accumulated, accumulated_traces, context, definitions)
    end)
  end

  defp fold_invocation_binding(binding, accumulated, accumulated_traces, context, definitions) do
    case DmnEvaluator.evaluate_expression_body(binding.expression, context, definitions) do
      {:ok, value, new_traces} ->
        parameter_name = binding.parameter.name
        {:cont, {:ok, Map.put(accumulated, parameter_name, value), accumulated_traces ++ new_traces}}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  # --- Boxed List -------------------------------------------------------------

  @spec evaluate_list(BoxedList.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_list(%BoxedList{elements: elements}, context, definitions) do
    results =
      Enum.reduce_while(elements, {:ok, [], []}, fn element, {:ok, accumulated, accumulated_traces} ->
        case DmnEvaluator.evaluate_expression_body(element, context, definitions) do
          {:ok, value, new_traces} -> {:cont, {:ok, [value | accumulated], accumulated_traces ++ new_traces}}
          {:error, _, _} = error -> {:halt, error}
        end
      end)

    case results do
      {:ok, reversed, traces} -> {:ok, Enum.reverse(reversed), traces}
      {:error, _, _} = error -> error
    end
  end

  # --- Relation ---------------------------------------------------------------

  @spec evaluate_relation(Relation.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_relation(%Relation{columns: columns, rows: rows}, context, definitions) do
    column_names = Enum.map(columns, & &1.name)

    row_results =
      Enum.reduce_while(rows, {:ok, [], []}, fn row_expressions, {:ok, accumulated_rows, accumulated_traces} ->
        fold_relation_row(row_expressions, column_names, context, definitions, accumulated_rows, accumulated_traces)
      end)

    reverse_ok_list(row_results)
  end

  defp fold_relation_row(row_expressions, column_names, context, definitions, accumulated_rows, accumulated_traces) do
    case evaluate_relation_cells(row_expressions, context, definitions) do
      {:ok, cells, new_traces} ->
        row_map = Enum.zip(column_names, cells) |> Map.new()
        {:cont, {:ok, [row_map | accumulated_rows], accumulated_traces ++ new_traces}}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  defp evaluate_relation_cells(row_expressions, context, definitions) do
    row_expressions
    |> Enum.reduce_while({:ok, [], []}, fn expression, {:ok, accumulated_cells, accumulated_traces} ->
      fold_relation_cell(expression, accumulated_cells, accumulated_traces, context, definitions)
    end)
    |> reverse_ok_list()
  end

  defp fold_relation_cell(expression, accumulated_cells, accumulated_traces, context, definitions) do
    case DmnEvaluator.evaluate_expression_body(expression, context, definitions) do
      {:ok, value, new_traces} -> {:cont, {:ok, [value | accumulated_cells], accumulated_traces ++ new_traces}}
      {:error, _, _} = error -> {:halt, error}
    end
  end

  # --- Boxed Conditional ------------------------------------------------------

  @spec evaluate_conditional(BoxedConditional.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_conditional(%BoxedConditional{} = conditional, context, definitions) do
    case DmnEvaluator.evaluate_expression_body(conditional.if_expression, context, definitions) do
      {:ok, true, if_traces} ->
        case DmnEvaluator.evaluate_expression_body(conditional.then_expression, context, definitions) do
          {:ok, value, then_traces} -> {:ok, value, if_traces ++ then_traces}
          {:error, _, _} = error -> error
        end

      {:ok, _non_true, if_traces} ->
        case DmnEvaluator.evaluate_expression_body(conditional.else_expression, context, definitions) do
          {:ok, value, else_traces} -> {:ok, value, if_traces ++ else_traces}
          {:error, _, _} = error -> error
        end

      {:error, _, _} = error ->
        error
    end
  end

  # --- Boxed Filter -----------------------------------------------------------

  @spec evaluate_filter(BoxedFilter.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_filter(%BoxedFilter{} = boxed_filter, context, definitions) do
    case DmnEvaluator.evaluate_expression_body(boxed_filter.in_expression, context, definitions) do
      {:ok, source_list, in_traces} when is_list(source_list) ->
        source_list
        |> Enum.reduce_while({:ok, [], in_traces}, &fold_filter_item(&1, &2, boxed_filter, context, definitions))
        |> reverse_ok_list()

      {:ok, _not_a_list, _traces} ->
        {:error, :filter_source_not_list, %{message: "in_expression must evaluate to a list"}}

      {:error, _, _} = error ->
        error
    end
  end

  defp fold_filter_item(item, {:ok, accumulated, accumulated_traces}, boxed_filter, context, definitions) do
    item_context = Map.put(context, "item", item)

    case DmnEvaluator.evaluate_expression_body(boxed_filter.match_expression, item_context, definitions) do
      {:ok, true, new_traces} -> {:cont, {:ok, [item | accumulated], accumulated_traces ++ new_traces}}
      {:ok, _, new_traces} -> {:cont, {:ok, accumulated, accumulated_traces ++ new_traces}}
      {:error, _, _} = error -> {:halt, error}
    end
  end

  # --- Boxed For --------------------------------------------------------------

  @spec evaluate_for(BoxedFor.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_for(%BoxedFor{} = boxed_for, context, definitions) do
    case DmnEvaluator.evaluate_expression_body(boxed_for.in_expression, context, definitions) do
      {:ok, source_list, in_traces} when is_list(source_list) ->
        source_list
        |> Enum.reduce_while({:ok, [], in_traces}, &fold_for_item(&1, &2, boxed_for, context, definitions))
        |> reverse_ok_list()

      {:ok, _not_a_list, _traces} ->
        {:error, :iterator_source_not_list, %{message: "in_expression must evaluate to a list"}}

      {:error, _, _} = error ->
        error
    end
  end

  defp fold_for_item(item, {:ok, accumulated, accumulated_traces}, boxed_for, context, definitions) do
    iter_context = Map.put(context, boxed_for.iterator_variable, item)

    case DmnEvaluator.evaluate_expression_body(boxed_for.return_expression, iter_context, definitions) do
      {:ok, value, new_traces} -> {:cont, {:ok, [value | accumulated], accumulated_traces ++ new_traces}}
      {:error, _, _} = error -> {:halt, error}
    end
  end

  # --- Boxed Every ------------------------------------------------------------

  @spec evaluate_every(BoxedEvery.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_every(%BoxedEvery{} = boxed_every, context, definitions) do
    case DmnEvaluator.evaluate_expression_body(boxed_every.in_expression, context, definitions) do
      {:ok, source_list, in_traces} when is_list(source_list) ->
        initial = {:ok, true, in_traces}
        Enum.reduce_while(source_list, initial, &fold_every_item(&1, &2, boxed_every, context, definitions))

      {:ok, _not_a_list, _traces} ->
        {:error, :iterator_source_not_list, %{message: "in_expression must evaluate to a list"}}

      {:error, _, _} = error ->
        error
    end
  end

  defp fold_every_item(item, {:ok, _, accumulated_traces}, boxed_every, context, definitions) do
    iter_context = Map.put(context, boxed_every.iterator_variable, item)

    case DmnEvaluator.evaluate_expression_body(boxed_every.satisfies_expression, iter_context, definitions) do
      {:ok, true, new_traces} -> {:cont, {:ok, true, accumulated_traces ++ new_traces}}
      {:ok, _, new_traces} -> {:halt, {:ok, false, accumulated_traces ++ new_traces}}
      {:error, _, _} = error -> {:halt, error}
    end
  end

  # --- Boxed Some -------------------------------------------------------------

  @spec evaluate_some(BoxedSome.t(), map(), Definitions.t()) :: traced_result()
  def evaluate_some(%BoxedSome{} = boxed_some, context, definitions) do
    case DmnEvaluator.evaluate_expression_body(boxed_some.in_expression, context, definitions) do
      {:ok, source_list, in_traces} when is_list(source_list) ->
        initial = {:ok, false, in_traces}
        Enum.reduce_while(source_list, initial, &fold_some_item(&1, &2, boxed_some, context, definitions))

      {:ok, _not_a_list, _traces} ->
        {:error, :iterator_source_not_list, %{message: "in_expression must evaluate to a list"}}

      {:error, _, _} = error ->
        error
    end
  end

  defp fold_some_item(item, {:ok, _, accumulated_traces}, boxed_some, context, definitions) do
    iter_context = Map.put(context, boxed_some.iterator_variable, item)

    case DmnEvaluator.evaluate_expression_body(boxed_some.satisfies_expression, iter_context, definitions) do
      {:ok, true, new_traces} -> {:halt, {:ok, true, accumulated_traces ++ new_traces}}
      {:ok, _, new_traces} -> {:cont, {:ok, false, accumulated_traces ++ new_traces}}
      {:error, _, _} = error -> {:halt, error}
    end
  end

  # --- Helpers ----------------------------------------------------------------

  defp reverse_ok_list({:ok, reversed, traces}), do: {:ok, Enum.reverse(reversed), traces}
  defp reverse_ok_list({:error, _, _} = error), do: error
end
