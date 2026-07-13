defmodule EvilEngine.DMN.Validator do
  @moduledoc """
  Validates a parsed `%Definitions{}` struct for structural correctness.

  Returns `{:ok, definitions}` or `{:error, violations}` where
  `violations` is a list of `{atom(), String.t()}` tuples.

  Phase 4 (CL1) adds validation for BKMs, KnowledgeRequirements,
  AuthorityRequirements, ItemDefinitions, Imports, DRG cycle detection,
  and formal parameter uniqueness.
  """

  alias EvilEngine.DMN.Model.BoxedConditional
  alias EvilEngine.DMN.Model.BoxedContext
  alias EvilEngine.DMN.Model.BoxedEvery
  alias EvilEngine.DMN.Model.BoxedFilter
  alias EvilEngine.DMN.Model.BoxedFor
  alias EvilEngine.DMN.Model.BoxedInvocation
  alias EvilEngine.DMN.Model.BoxedList
  alias EvilEngine.DMN.Model.BoxedSome
  alias EvilEngine.DMN.Model.BusinessKnowledgeModel
  alias EvilEngine.DMN.Model.DecisionService
  alias EvilEngine.DMN.Model.DecisionTable
  alias EvilEngine.DMN.Model.Definitions
  alias EvilEngine.DMN.Model.FunctionDefinition
  alias EvilEngine.DMN.Model.LiteralExpression
  alias EvilEngine.DMN.Model.Relation
  alias EvilEngine.DMN.QualifiedReference

  @dialyzer {:no_opaque, [check_binding_parameter_name: 3, validate_invocation_parameter_names: 2]}

  @valid_hit_policies [:unique, :first, :any, :collect, :rule_order, :output_order, :priority]
  @collect_aggregations [:sum, :min, :max, :count, nil]

  @builtin_feel_types ~w(string number boolean date time dateTime dayTimeDuration yearMonthDuration Any)

  @spec validate(Definitions.t()) :: {:ok, Definitions.t()} | {:error, :validation_failed, map()}
  def validate(%Definitions{} = definitions) do
    violations =
      validate_decisions(definitions) ++
        validate_business_knowledge_models(definitions) ++
        validate_knowledge_requirement_references(definitions) ++
        validate_authority_requirement_references(definitions) ++
        validate_information_requirement_references(definitions) ++
        validate_invocation_bkm_references(definitions) ++
        validate_decision_services(definitions) ++
        validate_item_definitions(definitions) ++
        validate_imports(definitions) ++
        validate_drg_cycles(definitions)

    case violations do
      [] -> {:ok, definitions}
      errors -> {:error, :validation_failed, %{violations: errors}}
    end
  end

  # -- Decision validation -----------------------------------------------------

  defp validate_decisions(definitions) do
    Enum.flat_map(definitions.decisions, &validate_decision/1)
  end

  defp validate_decision(decision) do
    expression_violations = validate_value_expression(decision)
    child_violations = validate_decision_expression(decision.expression)

    expression_violations ++ child_violations
  end

  defp validate_value_expression(%{expression: nil} = decision) do
    [{:invalid_decision,
      "[Decision] '#{decision.id}' has no value expression"}]
  end

  defp validate_value_expression(_decision), do: []

  defp validate_decision_expression(nil), do: []
  defp validate_decision_expression(%DecisionTable{} = table), do: validate_decision_table(table)
  defp validate_decision_expression(%LiteralExpression{} = literal), do: validate_literal_expression(literal)
  defp validate_decision_expression(%BoxedContext{} = context), do: validate_boxed_context(context)
  defp validate_decision_expression(%BoxedInvocation{} = invocation), do: validate_boxed_invocation(invocation)
  defp validate_decision_expression(%BoxedList{} = list), do: validate_boxed_list(list)
  defp validate_decision_expression(%Relation{} = relation), do: validate_relation(relation)
  defp validate_decision_expression(%BoxedConditional{} = conditional), do: validate_boxed_conditional(conditional)
  defp validate_decision_expression(%BoxedFilter{} = boxed_filter), do: validate_boxed_filter(boxed_filter)
  defp validate_decision_expression(%BoxedFor{} = boxed_for), do: validate_boxed_for(boxed_for)
  defp validate_decision_expression(%BoxedEvery{} = boxed_every), do: validate_boxed_every(boxed_every)
  defp validate_decision_expression(%BoxedSome{} = boxed_some), do: validate_boxed_some(boxed_some)

  defp validate_decision_expression(%FunctionDefinition{} = function_definition),
    do: validate_standalone_function_definition(function_definition)

  defp validate_decision_expression(_expression), do: []

  defp validate_standalone_function_definition(%FunctionDefinition{type: :feel} = function_definition) do
    validate_standalone_function_body(function_definition) ++
      validate_standalone_formal_parameter_uniqueness(function_definition)
  end

  defp validate_standalone_function_definition(%FunctionDefinition{type: function_type}) do
    [{:unsupported_function_kind,
      "[FunctionDefinition] standalone function definitions must use FEEL type, got: #{inspect(function_type)}"}]
  end

  defp validate_standalone_function_body(%FunctionDefinition{body: nil}) do
    [{:missing_function_body, "[FunctionDefinition] standalone function definition has no body"}]
  end

  defp validate_standalone_function_body(%FunctionDefinition{body: body}) do
    validate_decision_expression(body)
  end

  defp validate_standalone_formal_parameter_uniqueness(%FunctionDefinition{formal_parameters: parameters}) do
    parameter_names = Enum.map(parameters, & &1.name)
    unique_names = Enum.uniq(parameter_names)

    if length(parameter_names) == length(unique_names) do
      []
    else
      duplicates = parameter_names -- unique_names

      [{:duplicate_formal_parameters,
        "[FunctionDefinition] has duplicate formal parameter names: #{inspect(Enum.uniq(duplicates))}"}]
    end
  end

  defp validate_decision_table(%DecisionTable{} = table) do
    table_checks = [
      &check_hit_policy/1,
      &check_aggregation_requires_collect/1,
      &check_aggregation_valid/1,
      &check_inputs_present/1,
      &check_outputs_present/1
    ]

    structural_violations = Enum.flat_map(table_checks, fn check -> check.(table) end)
    structural_violations ++ validate_rules(table)
  end

  defp check_hit_policy(table) do
    if table.hit_policy in @valid_hit_policies,
      do: [],
      else: [{:invalid_hit_policy, "[DecisionTable] '#{table.id}' has invalid hit policy: #{inspect(table.hit_policy)}"}]
  end

  defp check_aggregation_requires_collect(table) do
    if table.aggregation != nil and table.hit_policy != :collect,
      do: [{:invalid_aggregation, "[DecisionTable] '#{table.id}' has aggregation but hit policy is not COLLECT"}],
      else: []
  end

  defp check_aggregation_valid(table) do
    if table.aggregation in @collect_aggregations,
      do: [],
      else: [{:invalid_aggregation, "[DecisionTable] '#{table.id}' has invalid aggregation: #{inspect(table.aggregation)}"}]
  end

  defp check_inputs_present(table) do
    if table.inputs == [],
      do: [{:missing_inputs, "[DecisionTable] '#{table.id}' must have at least one input"}],
      else: []
  end

  defp check_outputs_present(table) do
    if table.outputs == [],
      do: [{:missing_outputs, "[DecisionTable] '#{table.id}' must have at least one output"}],
      else: []
  end

  defp validate_rules(%DecisionTable{rules: []} = table) do
    [{:missing_rules, "[DecisionTable] '#{table.id}' must have at least one rule"}]
  end

  defp validate_rules(%DecisionTable{} = table) do
    expected_inputs = length(table.inputs)
    expected_outputs = length(table.outputs)

    Enum.flat_map(table.rules, fn rule ->
      input_count = length(rule.input_entries)
      output_count = length(rule.output_entries)

      input_mismatch =
        if input_count != expected_inputs do
          [{:rule_entry_mismatch,
            "[Rule] '#{rule.id}' has #{input_count} input entries but table has #{expected_inputs} inputs"}]
        else
          []
        end

      output_mismatch =
        if output_count != expected_outputs do
          [{:rule_entry_mismatch,
            "[Rule] '#{rule.id}' has #{output_count} output entries but table has #{expected_outputs} outputs"}]
        else
          []
        end

      input_mismatch ++ output_mismatch
    end)
  end

  defp validate_literal_expression(%LiteralExpression{text: text} = literal) do
    if blank?(text) do
      [{:blank_literal_expression,
        "[LiteralExpression] '#{literal.id || "(anonymous)"}' has a blank text — must contain a FEEL expression"}]
    else
      []
    end
  end

  # -- Boxed Context validation --

  defp validate_boxed_context(%BoxedContext{context_entries: []}) do
    [{:empty_context, "[BoxedContext] must have at least one context entry"}]
  end

  defp validate_boxed_context(%BoxedContext{context_entries: entries}) do
    entry_violations =
      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        validate_context_entry(entry, index)
      end)

    variable_names =
      entries
      |> Enum.map(fn entry -> entry.variable && entry.variable.name end)
      |> Enum.reject(&is_nil/1)

    duplicate_violations =
      if length(variable_names) == length(Enum.uniq(variable_names)) do
        []
      else
        duplicates = variable_names -- Enum.uniq(variable_names)
        [{:duplicate_context_variables,
          "[BoxedContext] has duplicate variable names: #{inspect(Enum.uniq(duplicates))}"}]
      end

    entry_violations ++ duplicate_violations
  end

  defp validate_context_entry(%{expression: nil}, index) do
    [{:missing_context_entry_expression,
      "[ContextEntry] entry at index #{index} has no expression"}]
  end

  defp validate_context_entry(%{expression: expression}, _index) do
    validate_decision_expression(expression)
  end

  # -- Boxed Invocation validation --

  defp validate_boxed_invocation(%BoxedInvocation{called_function: called_function} = invocation) do
    base_violations =
      if blank?(called_function) do
        [{:missing_called_function,
          "[BoxedInvocation] must have a non-blank called_function"}]
      else
        []
      end

    binding_violations = validate_invocation_bindings(invocation.bindings)
    base_violations ++ binding_violations
  end

  defp validate_invocation_bindings(bindings) do
    Enum.flat_map(bindings, fn binding ->
      parameter_violations =
        if is_nil(binding.parameter) do
          [{:missing_binding_parameter, "[Binding] must have a parameter"}]
        else
          []
        end

      expression_violations =
        if is_nil(binding.expression) do
          [{:missing_binding_expression, "[Binding] must have an expression"}]
        else
          validate_decision_expression(binding.expression)
        end

      parameter_violations ++ expression_violations
    end)
  end

  # -- Boxed List validation --

  defp validate_boxed_list(%BoxedList{elements: []}) do
    [{:empty_list, "[BoxedList] must have at least one element"}]
  end

  defp validate_boxed_list(%BoxedList{elements: elements}) do
    Enum.flat_map(elements, &validate_decision_expression/1)
  end

  # -- Relation validation --

  defp validate_relation(%Relation{columns: []}) do
    [{:empty_relation_columns, "[Relation] must have at least one column"}]
  end

  defp validate_relation(%Relation{columns: columns, rows: rows}) do
    expected_column_count = length(columns)

    row_violations =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row_expressions, row_index} ->
        if length(row_expressions) != expected_column_count do
          [{:relation_row_column_mismatch,
            "[Relation] row #{row_index} has #{length(row_expressions)} cells but #{expected_column_count} columns defined"}]
        else
          Enum.flat_map(row_expressions, &validate_decision_expression/1)
        end
      end)

    row_violations
  end

  # -- Boxed Conditional validation --

  defp validate_boxed_conditional(%BoxedConditional{} = conditional) do
    if_violations =
      if is_nil(conditional.if_expression) do
        [{:missing_conditional_branch, "[BoxedConditional] missing 'if' expression"}]
      else
        validate_decision_expression(conditional.if_expression)
      end

    then_violations =
      if is_nil(conditional.then_expression) do
        [{:missing_conditional_branch, "[BoxedConditional] missing 'then' expression"}]
      else
        validate_decision_expression(conditional.then_expression)
      end

    else_violations =
      if is_nil(conditional.else_expression) do
        [{:missing_conditional_branch, "[BoxedConditional] missing 'else' expression"}]
      else
        validate_decision_expression(conditional.else_expression)
      end

    if_violations ++ then_violations ++ else_violations
  end

  # -- Boxed Filter validation --

  defp validate_boxed_filter(%BoxedFilter{} = boxed_filter) do
    in_violations =
      if is_nil(boxed_filter.in_expression) do
        [{:missing_filter_expression, "[BoxedFilter] missing 'in' expression"}]
      else
        validate_decision_expression(boxed_filter.in_expression)
      end

    match_violations =
      if is_nil(boxed_filter.match_expression) do
        [{:missing_filter_expression, "[BoxedFilter] missing 'match' expression"}]
      else
        validate_decision_expression(boxed_filter.match_expression)
      end

    in_violations ++ match_violations
  end

  # -- Boxed For validation --

  defp validate_boxed_for(%BoxedFor{} = boxed_for) do
    variable_violations =
      if is_nil(boxed_for.iterator_variable) or boxed_for.iterator_variable == "" do
        [{:missing_iterator_variable, "[BoxedFor] must have a non-blank iterator_variable"}]
      else
        []
      end

    in_violations =
      if is_nil(boxed_for.in_expression) do
        [{:missing_iterator_expression, "[BoxedFor] missing 'in' expression"}]
      else
        validate_decision_expression(boxed_for.in_expression)
      end

    return_violations =
      if is_nil(boxed_for.return_expression) do
        [{:missing_iterator_expression, "[BoxedFor] missing 'return' expression"}]
      else
        validate_decision_expression(boxed_for.return_expression)
      end

    variable_violations ++ in_violations ++ return_violations
  end

  # -- Boxed Every validation --

  defp validate_boxed_every(%BoxedEvery{} = boxed_every) do
    variable_violations =
      if is_nil(boxed_every.iterator_variable) or boxed_every.iterator_variable == "" do
        [{:missing_iterator_variable, "[BoxedEvery] must have a non-blank iterator_variable"}]
      else
        []
      end

    in_violations =
      if is_nil(boxed_every.in_expression) do
        [{:missing_iterator_expression, "[BoxedEvery] missing 'in' expression"}]
      else
        validate_decision_expression(boxed_every.in_expression)
      end

    satisfies_violations =
      if is_nil(boxed_every.satisfies_expression) do
        [{:missing_iterator_expression, "[BoxedEvery] missing 'satisfies' expression"}]
      else
        validate_decision_expression(boxed_every.satisfies_expression)
      end

    variable_violations ++ in_violations ++ satisfies_violations
  end

  # -- Boxed Some validation --

  defp validate_boxed_some(%BoxedSome{} = boxed_some) do
    variable_violations =
      if is_nil(boxed_some.iterator_variable) or boxed_some.iterator_variable == "" do
        [{:missing_iterator_variable, "[BoxedSome] must have a non-blank iterator_variable"}]
      else
        []
      end

    in_violations =
      if is_nil(boxed_some.in_expression) do
        [{:missing_iterator_expression, "[BoxedSome] missing 'in' expression"}]
      else
        validate_decision_expression(boxed_some.in_expression)
      end

    satisfies_violations =
      if is_nil(boxed_some.satisfies_expression) do
        [{:missing_iterator_expression, "[BoxedSome] missing 'satisfies' expression"}]
      else
        validate_decision_expression(boxed_some.satisfies_expression)
      end

    variable_violations ++ in_violations ++ satisfies_violations
  end

  # -- BKM validation ----------------------------------------------------------

  defp validate_business_knowledge_models(definitions) do
    Enum.flat_map(definitions.business_knowledge_models, &validate_bkm/1)
  end

  defp validate_bkm(%BusinessKnowledgeModel{encapsulated_logic: nil} = bkm) do
    [{:invalid_bkm,
      "[BusinessKnowledgeModel] '#{bkm.id}' is missing encapsulated logic"}]
  end

  defp validate_bkm(%BusinessKnowledgeModel{encapsulated_logic: %FunctionDefinition{} = function_definition} = bkm) do
    validate_function_kind(bkm, function_definition) ++
      validate_function_body(bkm, function_definition) ++
      validate_formal_parameter_uniqueness(bkm, function_definition)
  end

  defp validate_function_kind(_bkm, %FunctionDefinition{type: :feel}), do: []

  defp validate_function_kind(bkm, %FunctionDefinition{type: function_type}) do
    [{:invalid_function_kind,
      "[BusinessKnowledgeModel] '#{bkm.id}' has unsupported function type: #{inspect(function_type)} (only :feel is supported in CL1)"}]
  end

  defp validate_function_body(bkm, %FunctionDefinition{body: nil}) do
    [{:invalid_bkm,
      "[BusinessKnowledgeModel] '#{bkm.id}' has a FunctionDefinition with no body"}]
  end

  defp validate_function_body(bkm, %FunctionDefinition{body: %DecisionTable{} = table}) do
    Enum.map(validate_decision_table(table), fn {atom, message} ->
      {atom, "[BusinessKnowledgeModel] '#{bkm.id}' encapsulated logic: #{message}"}
    end)
  end

  defp validate_function_body(bkm, %FunctionDefinition{body: %LiteralExpression{} = literal}) do
    Enum.map(validate_literal_expression(literal), fn {atom, message} ->
      {atom, "[BusinessKnowledgeModel] '#{bkm.id}' encapsulated logic: #{message}"}
    end)
  end

  defp validate_function_body(_bkm, %FunctionDefinition{body: body}) when not is_nil(body) do
    validate_decision_expression(body)
  end

  defp validate_formal_parameter_uniqueness(bkm, %FunctionDefinition{formal_parameters: parameters}) do
    parameter_names = Enum.map(parameters, & &1.name)
    unique_names = Enum.uniq(parameter_names)

    if length(parameter_names) == length(unique_names) do
      []
    else
      duplicates = parameter_names -- unique_names
      [{:duplicate_formal_parameters,
        "[BusinessKnowledgeModel] '#{bkm.id}' has duplicate formal parameter names: #{inspect(Enum.uniq(duplicates))}"}]
    end
  end

  # -- KnowledgeRequirement reference validation --------------------------------

  defp validate_knowledge_requirement_references(definitions) do
    bkm_ids = MapSet.new(definitions.business_knowledge_models, & &1.id)

    knowledge_carriers =
      Enum.map(definitions.decisions, fn decision ->
        {"Decision", decision.id, decision.knowledge_requirements}
      end) ++
        Enum.map(definitions.business_knowledge_models, fn bkm ->
          {"BusinessKnowledgeModel", bkm.id, bkm.knowledge_requirements}
        end)

    Enum.flat_map(knowledge_carriers, fn {element_type, element_id, requirements} ->
      validate_knowledge_requirements_for_element(requirements, element_type, element_id, bkm_ids)
    end)
  end

  defp validate_knowledge_requirements_for_element(requirements, element_type, element_id, bkm_ids) do
    Enum.flat_map(requirements, fn requirement ->
      ref_id = requirement.required_knowledge_id

      if MapSet.member?(bkm_ids, ref_id) or QualifiedReference.imported?(ref_id) do
        []
      else
        [{:invalid_knowledge_requirement,
          "[#{element_type}] '#{element_id}' references unknown BKM: '#{ref_id}'"}]
      end
    end)
  end

  # -- AuthorityRequirement reference validation --------------------------------

  defp validate_authority_requirement_references(definitions) do
    knowledge_source_ids = MapSet.new(definitions.knowledge_sources, & &1.id)
    decision_ids = MapSet.new(definitions.decisions, & &1.id)
    input_data_ids = MapSet.new(definitions.input_data, & &1.id)

    all_authority_carriers =
      Enum.map(definitions.decisions, fn decision ->
        {"Decision", decision.id, decision.authority_requirements}
      end) ++
        Enum.map(definitions.business_knowledge_models, fn bkm ->
          {"BusinessKnowledgeModel", bkm.id, bkm.authority_requirements}
        end) ++
        Enum.map(definitions.knowledge_sources, fn knowledge_source ->
          {"KnowledgeSource", knowledge_source.id, knowledge_source.authority_requirements}
        end)

    Enum.flat_map(all_authority_carriers, fn {element_type, element_id, authority_requirements} ->
      Enum.flat_map(authority_requirements, fn authority_requirement ->
        validate_single_authority_requirement(
          authority_requirement,
          element_type,
          element_id,
          knowledge_source_ids,
          decision_ids,
          input_data_ids
        )
      end)
    end)
  end

  defp validate_single_authority_requirement(
         authority_requirement,
         element_type,
         element_id,
         knowledge_source_ids,
         decision_ids,
         input_data_ids
       ) do
    authority_violation =
      check_optional_reference(
        authority_requirement.required_authority_id,
        knowledge_source_ids,
        "[#{element_type}] '#{element_id}' has AuthorityRequirement referencing unknown KnowledgeSource: "
      )

    decision_violation =
      check_optional_reference(
        authority_requirement.required_decision_id,
        decision_ids,
        "[#{element_type}] '#{element_id}' has AuthorityRequirement referencing unknown Decision: "
      )

    input_violation =
      check_optional_reference(
        authority_requirement.required_input_id,
        input_data_ids,
        "[#{element_type}] '#{element_id}' has AuthorityRequirement referencing unknown InputData: "
      )

    authority_violation ++ decision_violation ++ input_violation
  end

  defp check_optional_reference(nil, _valid_ids, _message_prefix), do: []

  defp check_optional_reference(reference_id, valid_ids, message_prefix) do
    if MapSet.member?(valid_ids, reference_id) do
      []
    else
      [{:invalid_authority_requirement, "#{message_prefix}'#{reference_id}'"}]
    end
  end

  # -- InformationRequirement reference validation ------------------------------

  defp validate_information_requirement_references(definitions) do
    decision_ids = MapSet.new(definitions.decisions, & &1.id)

    Enum.flat_map(definitions.decisions, fn decision ->
      Enum.flat_map(decision.information_requirements, fn requirement ->
        validate_information_requirement_decision_ref(
          requirement.required_decision_id,
          decision.id,
          decision_ids
        )
      end)
    end)
  end

  defp validate_information_requirement_decision_ref(nil, _decision_id, _decision_ids), do: []

  defp validate_information_requirement_decision_ref(required_decision_id, decision_id, decision_ids) do
    cond do
      MapSet.member?(decision_ids, required_decision_id) ->
        []

      QualifiedReference.imported?(required_decision_id) ->
        []

      true ->
        [{:invalid_information_requirement,
          "[Decision] '#{decision_id}' references unknown required Decision: '#{required_decision_id}'"}]
    end
  end

  # -- BoxedInvocation BKM reference validation ---------------------------------

  defp validate_invocation_bkm_references(definitions) do
    bkm_names = MapSet.new(definitions.business_knowledge_models, & &1.name)
    bkm_ids = MapSet.new(definitions.business_knowledge_models, & &1.id)

    bkms_by_name =
      Map.new(definitions.business_knowledge_models, fn bkm -> {bkm.name, bkm} end)

    bkms_by_id =
      Map.new(definitions.business_knowledge_models, fn bkm -> {bkm.id, bkm} end)

    decision_invocations =
      Enum.flat_map(definitions.decisions, fn decision ->
        collect_invocations_from_expression(decision.expression)
      end)

    bkm_invocations =
      Enum.flat_map(definitions.business_knowledge_models, fn bkm ->
        case bkm.encapsulated_logic do
          %FunctionDefinition{body: body} -> collect_invocations_from_expression(body)
          _ -> []
        end
      end)

    (decision_invocations ++ bkm_invocations)
    |> Enum.flat_map(fn invocation ->
      validate_invocation_bkm_ref(invocation, bkm_names, bkm_ids, bkms_by_name, bkms_by_id)
    end)
  end

  defp validate_invocation_bkm_ref(%BoxedInvocation{called_function: nil}, _, _, _, _), do: []

  defp validate_invocation_bkm_ref(%BoxedInvocation{} = invocation, bkm_names, bkm_ids, bkms_by_name, bkms_by_id) do
    name = invocation.called_function

    ref_violations =
      if MapSet.member?(bkm_names, name) or MapSet.member?(bkm_ids, name) do
        []
      else
        [{:invalid_invocation_reference,
          "[BoxedInvocation] references unknown BKM: '#{name}'"}]
      end

    resolved_bkm = Map.get(bkms_by_name, name) || Map.get(bkms_by_id, name)

    param_violations =
      case resolved_bkm do
        nil -> []
        bkm -> validate_invocation_parameter_names(invocation, bkm)
      end

    ref_violations ++ param_violations
  end

  defp validate_invocation_parameter_names(%BoxedInvocation{bindings: bindings}, bkm) do
    formal_names = extract_formal_parameter_names(bkm)

    if Enum.empty?(formal_names) do
      []
    else
      Enum.flat_map(bindings, &check_binding_parameter_name(&1, formal_names, bkm.name))
    end
  end

  defp extract_formal_parameter_names(bkm) do
    case bkm.encapsulated_logic do
      %FunctionDefinition{formal_parameters: parameters} -> MapSet.new(parameters, & &1.name)
      _ -> MapSet.new()
    end
  end

  defp check_binding_parameter_name(binding, formal_names, bkm_name) do
    binding_name = binding.parameter && binding.parameter.name

    if is_nil(binding_name) or MapSet.member?(formal_names, binding_name) do
      []
    else
      [{:invalid_invocation_parameter,
        "[BoxedInvocation] binding parameter '#{binding_name}' " <>
          "does not match any formal parameter of BKM '#{bkm_name}'"}]
    end
  end

  defp collect_invocations_from_expression(nil), do: []
  defp collect_invocations_from_expression(%DecisionTable{}), do: []
  defp collect_invocations_from_expression(%LiteralExpression{}), do: []

  defp collect_invocations_from_expression(%BoxedInvocation{} = invocation) do
    nested = Enum.flat_map(invocation.bindings, fn b -> collect_invocations_from_expression(b.expression) end)
    [invocation | nested]
  end

  defp collect_invocations_from_expression(%BoxedContext{context_entries: entries}) do
    Enum.flat_map(entries, fn entry -> collect_invocations_from_expression(entry.expression) end)
  end

  defp collect_invocations_from_expression(%BoxedList{elements: elements}) do
    Enum.flat_map(elements, &collect_invocations_from_expression/1)
  end

  defp collect_invocations_from_expression(%Relation{rows: rows}) do
    Enum.flat_map(rows, fn row -> Enum.flat_map(row, &collect_invocations_from_expression/1) end)
  end

  defp collect_invocations_from_expression(%BoxedConditional{} = conditional) do
    collect_invocations_from_expression(conditional.if_expression) ++
      collect_invocations_from_expression(conditional.then_expression) ++
      collect_invocations_from_expression(conditional.else_expression)
  end

  defp collect_invocations_from_expression(%BoxedFilter{} = boxed_filter) do
    collect_invocations_from_expression(boxed_filter.in_expression) ++
      collect_invocations_from_expression(boxed_filter.match_expression)
  end

  defp collect_invocations_from_expression(%BoxedFor{} = boxed_for) do
    collect_invocations_from_expression(boxed_for.in_expression) ++
      collect_invocations_from_expression(boxed_for.return_expression)
  end

  defp collect_invocations_from_expression(%BoxedEvery{} = boxed_every) do
    collect_invocations_from_expression(boxed_every.in_expression) ++
      collect_invocations_from_expression(boxed_every.satisfies_expression)
  end

  defp collect_invocations_from_expression(%BoxedSome{} = boxed_some) do
    collect_invocations_from_expression(boxed_some.in_expression) ++
      collect_invocations_from_expression(boxed_some.satisfies_expression)
  end

  defp collect_invocations_from_expression(%FunctionDefinition{body: body}) do
    collect_invocations_from_expression(body)
  end

  defp collect_invocations_from_expression(_other), do: []

  # -- DecisionService validation -----------------------------------------------

  defp validate_decision_services(definitions) do
    decision_ids = MapSet.new(definitions.decisions, & &1.id)
    input_data_ids = MapSet.new(definitions.input_data, & &1.id)

    Enum.flat_map(definitions.decision_services, fn service ->
      validate_decision_service(service, decision_ids, input_data_ids)
    end)
  end

  defp validate_decision_service(%DecisionService{} = service, decision_ids, input_data_ids) do
    validate_service_output_non_empty(service) ++
      validate_service_references_exist(service, decision_ids, input_data_ids) ++
      validate_service_no_output_in_encapsulated(service) ++
      validate_service_input_decisions_external(service)
  end

  defp validate_service_output_non_empty(%DecisionService{output_decisions: []}) do
    [{:invalid_decision_service, "[DecisionService] must have at least one outputDecision"}]
  end

  defp validate_service_output_non_empty(_service), do: []

  defp validate_service_references_exist(service, decision_ids, input_data_ids) do
    all_decision_refs =
      service.output_decisions ++
        service.encapsulated_decisions ++
        service.input_decisions

    decision_violations =
      Enum.flat_map(all_decision_refs, fn decision_ref ->
        if MapSet.member?(decision_ids, decision_ref) do
          []
        else
          [{:invalid_decision_service,
            "[DecisionService] '#{service.id}' references unknown Decision: '#{decision_ref}'"}]
        end
      end)

    input_data_violations =
      Enum.flat_map(service.input_data, fn input_ref ->
        if MapSet.member?(input_data_ids, input_ref) do
          []
        else
          [{:invalid_decision_service,
            "[DecisionService] '#{service.id}' references unknown InputData: '#{input_ref}'"}]
        end
      end)

    decision_violations ++ input_data_violations
  end

  defp validate_service_no_output_in_encapsulated(service) do
    encapsulated_set = MapSet.new(service.encapsulated_decisions)

    Enum.flat_map(service.output_decisions, fn output_id ->
      if MapSet.member?(encapsulated_set, output_id) do
        [{:invalid_decision_service,
          "[DecisionService] '#{service.id}' has '#{output_id}' in both outputDecisions and encapsulatedDecisions"}]
      else
        []
      end
    end)
  end

  defp validate_service_input_decisions_external(service) do
    internal_set =
      MapSet.new(service.output_decisions ++ service.encapsulated_decisions)

    Enum.flat_map(service.input_decisions, fn input_decision_id ->
      if MapSet.member?(internal_set, input_decision_id) do
        [{:invalid_decision_service,
          "[DecisionService] '#{service.id}' has '#{input_decision_id}' as inputDecision " <>
            "but it is also in outputDecisions or encapsulatedDecisions"}]
      else
        []
      end
    end)
  end

  # -- ItemDefinition validation ------------------------------------------------

  defp validate_item_definitions(definitions) do
    item_definition_names = MapSet.new(definitions.item_definitions, & &1.name)

    Enum.flat_map(definitions.item_definitions, fn item_definition ->
      validate_item_definition_type_ref(item_definition, item_definition_names)
    end)
  end

  defp validate_item_definition_type_ref(%{type_ref: nil}, _item_definition_names), do: []

  defp validate_item_definition_type_ref(item_definition, item_definition_names) do
    is_builtin = item_definition.type_ref in @builtin_feel_types
    is_defined = MapSet.member?(item_definition_names, item_definition.type_ref)

    if is_builtin or is_defined do
      []
    else
      [{:invalid_item_definition,
        "[ItemDefinition] '#{item_definition.id}' has unresolvable typeRef: '#{item_definition.type_ref}'"}]
    end
  end

  # -- Import validation --------------------------------------------------------

  defp validate_imports(definitions) do
    Enum.flat_map(definitions.imports, fn import_element ->
      if blank?(import_element.namespace) do
        [{:invalid_import,
          "[Import] '#{import_element.id || "(anonymous)"}' has a blank namespace"}]
      else
        []
      end
    end)
  end

  # -- DRG cycle detection (decisions + BKMs) -----------------------------------

  defp validate_drg_cycles(definitions) do
    decision_violations = detect_decision_cycles(definitions)
    bkm_violations = detect_bkm_cycles(definitions)
    decision_violations ++ bkm_violations
  end

  defp detect_decision_cycles(definitions) do
    decisions_by_id = Map.new(definitions.decisions, &{&1.id, &1})

    initial_state = %{visited: MapSet.new(), visiting: MapSet.new(), violations: []}

    final_state =
      Enum.reduce(definitions.decisions, initial_state, fn decision, state ->
        if MapSet.member?(state.visited, decision.id) do
          state
        else
          dfs_decision(decision.id, decisions_by_id, state)
        end
      end)

    final_state.violations
  end

  defp dfs_decision(decision_id, decisions_by_id, state) do
    cond do
      MapSet.member?(state.visited, decision_id) ->
        state

      MapSet.member?(state.visiting, decision_id) ->
        violation =
          {:drg_cycle,
           "[DRG] cycle detected among decisions involving: '#{decision_id}'"}

        %{state | violations: [violation | state.violations]}

      true ->
        dfs_decision_visit(decision_id, decisions_by_id, state)
    end
  end

  defp dfs_decision_visit(decision_id, decisions_by_id, state) do
    case Map.fetch(decisions_by_id, decision_id) do
      :error ->
        state

      {:ok, decision} ->
        visiting_state = %{state | visiting: MapSet.put(state.visiting, decision_id)}

        dependency_ids =
          decision.information_requirements
          |> Enum.map(& &1.required_decision_id)
          |> Enum.reject(&is_nil/1)

        after_deps_state =
          Enum.reduce(dependency_ids, visiting_state, fn dependency_id, accumulated_state ->
            dfs_decision(dependency_id, decisions_by_id, accumulated_state)
          end)

        %{
          after_deps_state
          | visited: MapSet.put(after_deps_state.visited, decision_id),
            visiting: MapSet.delete(after_deps_state.visiting, decision_id)
        }
    end
  end

  defp detect_bkm_cycles(definitions) do
    bkms_by_id = Map.new(definitions.business_knowledge_models, &{&1.id, &1})

    initial_state = %{visited: MapSet.new(), visiting: MapSet.new(), violations: []}

    final_state =
      Enum.reduce(definitions.business_knowledge_models, initial_state, fn bkm, state ->
        if MapSet.member?(state.visited, bkm.id) do
          state
        else
          dfs_bkm(bkm.id, bkms_by_id, state)
        end
      end)

    final_state.violations
  end

  defp dfs_bkm(bkm_id, bkms_by_id, state) do
    cond do
      MapSet.member?(state.visited, bkm_id) ->
        state

      MapSet.member?(state.visiting, bkm_id) ->
        violation =
          {:bkm_cycle,
           "[BKM] cycle detected among BKMs involving: '#{bkm_id}'"}

        %{state | violations: [violation | state.violations]}

      true ->
        dfs_bkm_visit(bkm_id, bkms_by_id, state)
    end
  end

  defp dfs_bkm_visit(bkm_id, bkms_by_id, state) do
    case Map.fetch(bkms_by_id, bkm_id) do
      :error ->
        state

      {:ok, bkm} ->
        visiting_state = %{state | visiting: MapSet.put(state.visiting, bkm_id)}

        dependency_ids = Enum.map(bkm.knowledge_requirements, & &1.required_knowledge_id)

        after_deps_state =
          Enum.reduce(dependency_ids, visiting_state, fn dependency_id, accumulated_state ->
            dfs_bkm(dependency_id, bkms_by_id, accumulated_state)
          end)

        %{
          after_deps_state
          | visited: MapSet.put(after_deps_state.visited, bkm_id),
            visiting: MapSet.delete(after_deps_state.visiting, bkm_id)
        }
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp blank?(nil), do: true
  defp blank?(string) when is_binary(string), do: String.trim(string) == ""
  defp blank?(_), do: false
end
