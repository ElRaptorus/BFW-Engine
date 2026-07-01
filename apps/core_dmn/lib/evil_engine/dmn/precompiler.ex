defmodule EvilEngine.DMN.Precompiler do
  @moduledoc """
  Precompiles all FEEL expressions in a DMN `%Definitions{}` struct.

  Called at deploy time (before cache insertion) to avoid re-parsing
  FEEL at every evaluation. Returns the definitions with compiled
  references embedded in the model structs.
  """

  alias EvilEngine.DMN.Evaluator.BkmInvoker
  alias EvilEngine.DMN.Model.Binding
  alias EvilEngine.DMN.Model.BoxedConditional
  alias EvilEngine.DMN.Model.BoxedContext
  alias EvilEngine.DMN.Model.BoxedEvery
  alias EvilEngine.DMN.Model.BoxedFilter
  alias EvilEngine.DMN.Model.BoxedFor
  alias EvilEngine.DMN.Model.BoxedInvocation
  alias EvilEngine.DMN.Model.BoxedList
  alias EvilEngine.DMN.Model.BoxedSome
  alias EvilEngine.DMN.Model.BusinessKnowledgeModel
  alias EvilEngine.DMN.Model.ContextEntry
  alias EvilEngine.DMN.Model.Decision
  alias EvilEngine.DMN.Model.DecisionTable
  alias EvilEngine.DMN.Model.Definitions
  alias EvilEngine.DMN.Model.FunctionDefinition
  alias EvilEngine.DMN.Model.Input
  alias EvilEngine.DMN.Model.InputEntry
  alias EvilEngine.DMN.Model.LiteralExpression
  alias EvilEngine.DMN.Model.Output
  alias EvilEngine.DMN.Model.OutputEntry
  alias EvilEngine.DMN.Model.Relation
  alias EvilEngine.DMN.Model.Types
  alias EvilEngine.Expressions

  @unary_input_placeholder %{"__unary_input__" => 0}

  alias EvilEngine.DMN.ImportResolver

  @type precompile_opts :: [import_resolver: ImportResolver.resolver()]

  @spec precompile(Definitions.t(), precompile_opts()) ::
          {:ok, Definitions.t()} | {:error, atom(), map()}
  def precompile(%Definitions{} = definitions, opts \\ []) do
    with {:ok, context_shape} <- build_context_shape(definitions, opts),
         {:ok, decisions} <- precompile_decisions(definitions.decisions, context_shape),
         {:ok, business_knowledge_models} <-
           precompile_bkms(definitions.business_knowledge_models, context_shape) do
      {:ok,
       %Definitions{
         definitions
         | decisions: decisions,
           business_knowledge_models: business_knowledge_models
       }}
    end
  end

  defp build_context_shape(%Definitions{} = definitions, opts) do
    input_data_shape =
      Enum.reduce(definitions.input_data, %{}, fn input_data, shape ->
        Map.put(shape, input_data.name, nil)
      end)

    decision_variable_shape =
      Enum.reduce(definitions.decisions, %{}, fn decision, shape ->
        Map.put(shape, Decision.output_variable_name(decision), nil)
      end)

    bkm_variable_shape =
      Enum.reduce(definitions.business_knowledge_models, %{}, fn bkm, shape ->
        variable_name = BkmInvoker.output_variable_name(bkm)
        Map.put(shape, variable_name, nil)
      end)

    case build_imported_context_shape(definitions, opts) do
      {:ok, imported_shape} ->
        shape =
          input_data_shape
          |> Map.merge(decision_variable_shape)
          |> Map.merge(bkm_variable_shape)
          |> Map.merge(imported_shape)

        {:ok, shape}

      {:error, _, _} = error ->
        error
    end
  end

  defp build_imported_context_shape(%Definitions{imports: []}, _opts), do: {:ok, %{}}

  defp build_imported_context_shape(%Definitions{} = definitions, opts) do
    resolver = Keyword.get_lazy(opts, :import_resolver, &ImportResolver.build_model_cache_resolver/0)

    case ImportResolver.resolve_imports(definitions, resolver) do
      {:ok, resolved_imports} ->
        shape =
          resolved_imports
          |> Map.values()
          |> Enum.flat_map(&extract_variable_names/1)
          |> Map.new(fn name -> {name, nil} end)

        {:ok, shape}

      {:error, reason, metadata} ->
        {:error, :import_shape_failed, Map.put(metadata, :reason, reason)}
    end
  end

  defp extract_variable_names(%Definitions{} = imported_definitions) do
    decision_names = Enum.map(imported_definitions.decisions, &Decision.output_variable_name/1)
    bkm_names = Enum.map(imported_definitions.business_knowledge_models, &BkmInvoker.output_variable_name/1)
    decision_names ++ bkm_names
  end

  defp precompile_decisions(decisions, context_shape) do
    reduce_ok_list(decisions, &precompile_decision(&1, context_shape))
  end

  defp precompile_bkms(business_knowledge_models, context_shape) do
    reduce_ok_list(business_knowledge_models, &precompile_bkm(&1, context_shape))
  end

  defp precompile_bkm(%BusinessKnowledgeModel{encapsulated_logic: nil} = business_knowledge_model, _context_shape) do
    {:ok, business_knowledge_model}
  end

  defp precompile_bkm(%BusinessKnowledgeModel{
         encapsulated_logic: %FunctionDefinition{} = function_definition
       } = business_knowledge_model, context_shape) do
    bkm_context_shape = build_bkm_context_shape(function_definition, context_shape)

    case precompile_function_body(function_definition.body, bkm_context_shape) do
      {:ok, body} ->
        {:ok,
         %BusinessKnowledgeModel{
           business_knowledge_model
           | encapsulated_logic: %FunctionDefinition{function_definition | body: body}
         }}

      error ->
        error
    end
  end

  defp build_bkm_context_shape(%FunctionDefinition{formal_parameters: parameters}, base_shape) do
    Enum.reduce(parameters, base_shape, fn parameter, shape ->
      Map.put(shape, parameter.name, nil)
    end)
  end

  defp precompile_decision(%Decision{expression: nil} = decision, _context_shape) do
    {:ok, decision}
  end

  defp precompile_decision(%Decision{expression: expression} = decision, context_shape) do
    case precompile_expression_body(expression, context_shape) do
      {:ok, compiled_expression} -> {:ok, %Decision{decision | expression: compiled_expression}}
      error -> error
    end
  end

  @spec precompile_expression_body(Types.expression_body(), map()) ::
          {:ok, Types.expression_body()} | {:error, atom(), map()}
  def precompile_expression_body(%DecisionTable{} = table, context_shape) do
    precompile_decision_table(table, context_shape)
  end

  def precompile_expression_body(%LiteralExpression{} = literal, context_shape) do
    precompile_literal_expression(literal, context_shape)
  end

  def precompile_expression_body(%BoxedContext{} = context, context_shape) do
    precompile_boxed_context(context, context_shape)
  end

  def precompile_expression_body(%BoxedInvocation{} = invocation, context_shape) do
    precompile_boxed_invocation(invocation, context_shape)
  end

  def precompile_expression_body(%BoxedList{} = list, context_shape) do
    precompile_boxed_list(list, context_shape)
  end

  def precompile_expression_body(%Relation{} = relation, context_shape) do
    precompile_relation(relation, context_shape)
  end

  def precompile_expression_body(%FunctionDefinition{} = function_definition, context_shape) do
    case precompile_function_body(function_definition.body, context_shape) do
      {:ok, body} -> {:ok, %FunctionDefinition{function_definition | body: body}}
      error -> error
    end
  end

  def precompile_expression_body(%BoxedConditional{} = conditional, context_shape) do
    precompile_boxed_conditional(conditional, context_shape)
  end

  def precompile_expression_body(%BoxedFilter{} = boxed_filter, context_shape) do
    precompile_boxed_filter(boxed_filter, context_shape)
  end

  def precompile_expression_body(%BoxedFor{} = boxed_for, context_shape) do
    precompile_boxed_for(boxed_for, context_shape)
  end

  def precompile_expression_body(%BoxedEvery{} = boxed_every, context_shape) do
    precompile_boxed_every(boxed_every, context_shape)
  end

  def precompile_expression_body(%BoxedSome{} = boxed_some, context_shape) do
    precompile_boxed_some(boxed_some, context_shape)
  end

  def precompile_expression_body(expression, _context_shape), do: {:ok, expression}

  defp precompile_function_body(%LiteralExpression{} = literal, context_shape) do
    precompile_literal_expression(literal, context_shape)
  end

  defp precompile_function_body(%DecisionTable{} = table, context_shape) do
    precompile_decision_table(table, context_shape)
  end

  defp precompile_function_body(%BoxedContext{} = context, context_shape) do
    precompile_boxed_context(context, context_shape)
  end

  defp precompile_function_body(%BoxedInvocation{} = invocation, context_shape) do
    precompile_boxed_invocation(invocation, context_shape)
  end

  defp precompile_function_body(%BoxedList{} = list, context_shape) do
    precompile_boxed_list(list, context_shape)
  end

  defp precompile_function_body(%Relation{} = relation, context_shape) do
    precompile_relation(relation, context_shape)
  end

  defp precompile_function_body(%BoxedConditional{} = conditional, context_shape) do
    precompile_boxed_conditional(conditional, context_shape)
  end

  defp precompile_function_body(%BoxedFilter{} = boxed_filter, context_shape) do
    precompile_boxed_filter(boxed_filter, context_shape)
  end

  defp precompile_function_body(%BoxedFor{} = boxed_for, context_shape) do
    precompile_boxed_for(boxed_for, context_shape)
  end

  defp precompile_function_body(%BoxedEvery{} = boxed_every, context_shape) do
    precompile_boxed_every(boxed_every, context_shape)
  end

  defp precompile_function_body(%BoxedSome{} = boxed_some, context_shape) do
    precompile_boxed_some(boxed_some, context_shape)
  end

  defp precompile_function_body(body, _context_shape), do: {:ok, body}

  # --- Boxed Context precompilation ---

  defp precompile_boxed_context(%BoxedContext{context_entries: entries} = context, context_shape) do
    case precompile_context_entries(entries, context_shape) do
      {:ok, compiled_entries} -> {:ok, %BoxedContext{context | context_entries: compiled_entries}}
      error -> error
    end
  end

  defp precompile_context_entries(entries, context_shape) do
    Enum.reduce_while(entries, {:ok, [], context_shape}, fn entry,
                                                           {:ok, compiled_entries, shape} ->
      case precompile_context_entry(entry, shape) do
        {:ok, compiled_entry} ->
          {:cont,
           {:ok, compiled_entries ++ [compiled_entry],
            extend_context_shape_after_entry(compiled_entry, shape)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled_entries, _shape} -> {:ok, compiled_entries}
      error -> error
    end
  end

  defp extend_context_shape_after_entry(
         %ContextEntry{variable: %{name: variable_name}},
         context_shape
       )
       when is_binary(variable_name) and variable_name != "" do
    Map.put(context_shape, variable_name, nil)
  end

  defp extend_context_shape_after_entry(%ContextEntry{}, context_shape), do: context_shape

  defp precompile_context_entry(%ContextEntry{expression: nil} = entry, _context_shape) do
    {:ok, entry}
  end

  defp precompile_context_entry(%ContextEntry{expression: expression} = entry, context_shape) do
    case precompile_expression_body(expression, context_shape) do
      {:ok, compiled} -> {:ok, %ContextEntry{entry | expression: compiled}}
      error -> error
    end
  end

  # --- Boxed Invocation precompilation ---

  defp precompile_boxed_invocation(%BoxedInvocation{bindings: bindings} = invocation, context_shape) do
    case reduce_ok_list(bindings, &precompile_binding(&1, context_shape)) do
      {:ok, compiled_bindings} -> {:ok, %BoxedInvocation{invocation | bindings: compiled_bindings}}
      error -> error
    end
  end

  defp precompile_binding(%Binding{expression: nil} = binding, _context_shape) do
    {:ok, binding}
  end

  defp precompile_binding(%Binding{expression: expression} = binding, context_shape) do
    case precompile_expression_body(expression, context_shape) do
      {:ok, compiled} -> {:ok, %Binding{binding | expression: compiled}}
      error -> error
    end
  end

  # --- Boxed List precompilation ---

  defp precompile_boxed_list(%BoxedList{elements: elements} = list, context_shape) do
    case reduce_ok_list(elements, &precompile_expression_body(&1, context_shape)) do
      {:ok, compiled_elements} -> {:ok, %BoxedList{list | elements: compiled_elements}}
      error -> error
    end
  end

  # --- Relation precompilation ---

  defp precompile_relation(%Relation{rows: rows} = relation, context_shape) do
    case reduce_ok_list(rows, &precompile_relation_row(&1, context_shape)) do
      {:ok, compiled_rows} -> {:ok, %Relation{relation | rows: compiled_rows}}
      error -> error
    end
  end

  defp precompile_relation_row(row_expressions, context_shape) do
    reduce_ok_list(row_expressions, &precompile_expression_body(&1, context_shape))
  end

  # --- Boxed Conditional precompilation ---

  defp precompile_boxed_conditional(%BoxedConditional{} = conditional, context_shape) do
    with {:ok, compiled_if} <- precompile_expression_body(conditional.if_expression, context_shape),
         {:ok, compiled_then} <- precompile_expression_body(conditional.then_expression, context_shape),
         {:ok, compiled_else} <- precompile_expression_body(conditional.else_expression, context_shape) do
      {:ok,
       %BoxedConditional{
         conditional
         | if_expression: compiled_if,
           then_expression: compiled_then,
           else_expression: compiled_else
       }}
    end
  end

  # --- Boxed Filter precompilation ---

  defp precompile_boxed_filter(%BoxedFilter{} = boxed_filter, context_shape) do
    match_shape = Map.put(context_shape, "item", nil)

    with {:ok, compiled_in} <- precompile_expression_body(boxed_filter.in_expression, context_shape),
         {:ok, compiled_match} <-
           precompile_expression_body(boxed_filter.match_expression, match_shape) do
      {:ok,
       %BoxedFilter{
         boxed_filter
         | in_expression: compiled_in,
           match_expression: compiled_match
       }}
    end
  end

  # --- Boxed For precompilation ---

  defp precompile_boxed_for(%BoxedFor{} = boxed_for, context_shape) do
    iterator_shape = Map.put(context_shape, boxed_for.iterator_variable, nil)

    with {:ok, compiled_in} <- precompile_expression_body(boxed_for.in_expression, context_shape),
         {:ok, compiled_return} <-
           precompile_expression_body(boxed_for.return_expression, iterator_shape) do
      {:ok,
       %BoxedFor{
         boxed_for
         | in_expression: compiled_in,
           return_expression: compiled_return
       }}
    end
  end

  # --- Boxed Every precompilation ---

  defp precompile_boxed_every(%BoxedEvery{} = boxed_every, context_shape) do
    iterator_shape = Map.put(context_shape, boxed_every.iterator_variable, nil)

    with {:ok, compiled_in} <- precompile_expression_body(boxed_every.in_expression, context_shape),
         {:ok, compiled_satisfies} <-
           precompile_expression_body(boxed_every.satisfies_expression, iterator_shape) do
      {:ok,
       %BoxedEvery{
         boxed_every
         | in_expression: compiled_in,
           satisfies_expression: compiled_satisfies
       }}
    end
  end

  # --- Boxed Some precompilation ---

  defp precompile_boxed_some(%BoxedSome{} = boxed_some, context_shape) do
    iterator_shape = Map.put(context_shape, boxed_some.iterator_variable, nil)

    with {:ok, compiled_in} <- precompile_expression_body(boxed_some.in_expression, context_shape),
         {:ok, compiled_satisfies} <-
           precompile_expression_body(boxed_some.satisfies_expression, iterator_shape) do
      {:ok,
       %BoxedSome{
         boxed_some
         | in_expression: compiled_in,
           satisfies_expression: compiled_satisfies
       }}
    end
  end

  defp precompile_decision_table(%DecisionTable{} = table, context_shape) do
    with {:ok, inputs} <- precompile_inputs(table.inputs, context_shape),
         {:ok, rules} <- precompile_rules(table.rules),
         {:ok, outputs} <- precompile_default_output_values(table.outputs) do
      rule_index = build_rule_index(rules)

      {:ok,
       %DecisionTable{table | inputs: inputs, rules: rules, outputs: outputs, rule_index: rule_index}}
    end
  end

  @doc """
  Builds a deploy-time rule index for decision table columns that use
  only simple equality literals (strings, integers, floats, booleans).

  For each indexable column, produces a map of `literal_value → MapSet`
  of rule indices. At evaluation time, the index enables O(1) candidate
  filtering per column before falling back to FEEL evaluation on
  non-indexed columns.

  Returns `nil` when no columns are indexable.
  """
  @spec build_rule_index([struct()]) :: DecisionTable.rule_index()
  def build_rule_index(rules) when is_list(rules) do
    return_if_empty(rules, fn ->
      column_count = rules |> List.first() |> Map.get(:input_entries) |> length()

      indexed_columns =
        for column_index <- 0..(column_count - 1),
            index = build_column_index(rules, column_index),
            index != nil,
            into: %{} do
          {column_index, index}
        end

      if map_size(indexed_columns) == 0, do: nil, else: indexed_columns
    end)
  end

  defp return_if_empty([], _fun), do: nil
  defp return_if_empty(_non_empty, fun), do: fun.()

  defp build_column_index(rules, column_index) do
    entries_with_indices =
      rules
      |> Enum.with_index()
      |> Enum.map(fn {rule, rule_index} ->
        entry = Enum.at(rule.input_entries, column_index)
        {entry, rule_index}
      end)

    if Enum.all?(entries_with_indices, fn {entry, _} -> indexable_entry?(entry) end) do
      {wildcards, literals} =
        Enum.split_with(entries_with_indices, fn {entry, _} -> wildcard_entry?(entry) end)

      wildcard_set = MapSet.new(wildcards, fn {_entry, rule_index} -> rule_index end)

      value_map =
        Enum.reduce(literals, %{}, fn {entry, rule_index}, accumulator ->
          literal = parse_equality_literal(entry.text)
          Map.update(accumulator, literal, MapSet.new([rule_index]), &MapSet.put(&1, rule_index))
        end)

      %{values: value_map, wildcards: wildcard_set}
    else
      nil
    end
  end

  defp indexable_entry?(%InputEntry{text: "-"}), do: true
  defp indexable_entry?(%InputEntry{text: ""}), do: true
  defp indexable_entry?(%InputEntry{text: text}), do: parse_equality_literal(text) != :not_indexable

  defp wildcard_entry?(%InputEntry{text: "-"}), do: true
  defp wildcard_entry?(%InputEntry{text: ""}), do: true
  defp wildcard_entry?(_entry), do: false

  @doc """
  Parses an input entry text as a simple equality literal.

  Returns the normalized value (string, integer, float, or boolean) if
  the text is a simple literal, or `:not_indexable` for expressions,
  ranges, comparisons, etc.
  """
  @spec parse_equality_literal(String.t()) :: String.t() | number() | boolean() | :not_indexable
  def parse_equality_literal(text) do
    trimmed = String.trim(text)

    cond do
      quoted_string?(trimmed) ->
        String.slice(trimmed, 1..-2//1)

      trimmed == "true" ->
        true

      trimmed == "false" ->
        false

      integer_literal?(trimmed) ->
        String.to_integer(trimmed)

      float_literal?(trimmed) ->
        String.to_float(trimmed)

      true ->
        :not_indexable
    end
  end

  defp quoted_string?(text) do
    String.length(text) >= 2 and
      String.starts_with?(text, "\"") and
      String.ends_with?(text, "\"")
  end

  defp integer_literal?(text) do
    case Integer.parse(text) do
      {_value, ""} -> true
      _ -> false
    end
  end

  defp float_literal?(text) do
    case Float.parse(text) do
      {_value, ""} -> true
      _ -> false
    end
  end

  defp precompile_default_output_values(outputs) do
    reduce_ok_list(outputs, &compile_default_output_value/1)
  end

  defp compile_default_output_value(%Output{default_output_value: nil} = output), do: {:ok, output}
  defp compile_default_output_value(%Output{default_output_value: ""} = output), do: {:ok, output}

  defp compile_default_output_value(%Output{default_output_value: text} = output) do
    case Expressions.compile(text) do
      {:ok, reference} -> {:ok, %Output{output | compiled_default_ref: reference}}
      {:error, reason} -> {:error, :feel_compile_failed, %{expression: text, reason: reason}}
    end
  end

  defp precompile_literal_expression(%LiteralExpression{} = literal, context_shape) do
    case Expressions.compile(literal.text, context_shape) do
      {:ok, reference} ->
        {:ok, %LiteralExpression{literal | compiled_ref: reference}}

      {:error, reason} ->
        {:error, :feel_compile_failed, %{expression: literal.text, reason: reason}}
    end
  end

  defp precompile_inputs(inputs, context_shape) do
    reduce_ok_list(inputs, &compile_input_expression(&1, context_shape))
  end

  defp compile_input_expression(%Input{input_expression: nil} = input, _context_shape), do: {:ok, input}

  defp compile_input_expression(%Input{input_expression: expression} = input, context_shape) do
    with {:ok, expression_ref} <- Expressions.compile(expression, context_shape),
         {:ok, compiled_input} <- compile_input_values(%Input{input | compiled_expression_ref: expression_ref}) do
      {:ok, compiled_input}
    else
      {:error, :feel_compile_failed, _metadata} = structured_error -> structured_error
      {:error, reason} -> {:error, :feel_compile_failed, %{expression: expression, reason: reason}}
    end
  end

  defp compile_input_values(%Input{input_values: nil} = input), do: {:ok, input}
  defp compile_input_values(%Input{input_values: ""} = input), do: {:ok, input}

  defp compile_input_values(%Input{input_values: values_text} = input) do
    wrapped_expression = "__unary_input__ in (#{values_text})"

    case Expressions.compile(wrapped_expression, @unary_input_placeholder) do
      {:ok, reference} -> {:ok, %Input{input | compiled_input_values_ref: reference}}
      {:error, reason} -> {:error, :feel_compile_failed, %{expression: values_text, reason: reason}}
    end
  end

  defp precompile_rules(rules) do
    reduce_ok_list(rules, fn rule ->
      with {:ok, input_entries} <- precompile_entries(rule.input_entries, :unary),
           {:ok, output_entries} <- precompile_entries(rule.output_entries, :expression) do
        {:ok, %{rule | input_entries: input_entries, output_entries: output_entries}}
      end
    end)
  end

  defp precompile_entries(entries, mode) do
    reduce_ok_list(entries, &compile_entry(&1, mode))
  end

  defp compile_entry(%InputEntry{text: "-"} = entry, _mode), do: {:ok, entry}
  defp compile_entry(%InputEntry{text: ""} = entry, _mode), do: {:ok, entry}

  defp compile_entry(%InputEntry{text: text} = entry, :unary) do
    wrapped_expression = "__unary_input__ in (#{text})"

    case Expressions.compile(wrapped_expression, @unary_input_placeholder) do
      {:ok, reference} -> {:ok, %InputEntry{entry | compiled_ref: reference}}
      {:error, reason} -> {:error, :feel_compile_failed, %{expression: text, reason: reason}}
    end
  end

  defp compile_entry(%OutputEntry{text: ""} = entry, _mode), do: {:ok, entry}

  defp compile_entry(%OutputEntry{text: text} = entry, _mode) do
    case Expressions.compile(text) do
      {:ok, reference} -> {:ok, %OutputEntry{entry | compiled_ref: reference}}
      {:error, reason} -> {:error, :feel_compile_failed, %{expression: text, reason: reason}}
    end
  end

  defp reduce_ok_list(items, mapper) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, accumulated} ->
      case mapper.(item) do
        {:ok, result} -> {:cont, {:ok, [result | accumulated]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end
end
