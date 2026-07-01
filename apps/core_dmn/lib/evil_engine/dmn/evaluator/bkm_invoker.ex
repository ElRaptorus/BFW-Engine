defmodule EvilEngine.DMN.Evaluator.BkmInvoker do
  @moduledoc """
  Resolves and invokes BusinessKnowledgeModel function definitions
  referenced via `KnowledgeRequirement` edges.

  BKM invocation is pre-evaluation: the BKM body is evaluated
  before the calling decision's expression, and the result is
  stored in the evaluation context under the BKM's variable name.
  BKM-to-BKM chains are resolved recursively with cycle detection.

  Returns `{:ok, updated_context, [BkmTrace.t()]}` so the caller
  can attach invocation traces to the owning `DecisionTrace`.
  """

  alias EvilEngine.DMN.EvaluationTrace.BkmTrace
  alias EvilEngine.DMN.Evaluator, as: DmnEvaluator
  alias EvilEngine.DMN.Evaluator.DecisionTableEvaluator
  alias EvilEngine.DMN.ImportResolver
  alias EvilEngine.DMN.Model.BusinessKnowledgeModel
  alias EvilEngine.DMN.Model.DecisionTable
  alias EvilEngine.DMN.Model.Definitions
  alias EvilEngine.DMN.Model.FunctionDefinition
  alias EvilEngine.DMN.Model.KnowledgeRequirement
  alias EvilEngine.DMN.Model.LiteralExpression
  alias EvilEngine.DMN.QualifiedReference

  @dialyzer {:no_opaque, resolve_and_invoke: 5}

  @type resolved_imports :: %{String.t() => Definitions.t()}

  @spec resolve_and_invoke(
          [KnowledgeRequirement.t()],
          Definitions.t(),
          map(),
          resolved_imports(),
          MapSet.t()
        ) ::
          {:ok, map(), [BkmTrace.t()]}
          | {:error, :bkm_not_found, %{bkm_id: String.t()}}
          | {:error, :bkm_cycle, %{bkm_ids: [String.t()]}}
          | {:error, atom(), map()}
  def resolve_and_invoke(knowledge_requirements, definitions, context, resolved_imports \\ %{}, visiting \\ MapSet.new())

  def resolve_and_invoke([], _definitions, context, _resolved_imports, _visiting), do: {:ok, context, []}

  def resolve_and_invoke([requirement | rest], definitions, context, resolved_imports, visiting) do
    bkms_by_id = Map.new(definitions.business_knowledge_models, &{&1.id, &1})

    with {:ok, result, variable_name, bkm_trace} <-
           invoke_by_id(
             requirement.required_knowledge_id,
             bkms_by_id,
             definitions,
             context,
             resolved_imports,
             visiting
           ) do
      updated_context = Map.put(context, variable_name, result)

      case resolve_and_invoke(rest, definitions, updated_context, resolved_imports, visiting) do
        {:ok, final_context, rest_traces} ->
          {:ok, final_context, [bkm_trace | rest_traces]}

        error ->
          error
      end
    end
  end

  @doc """
  Returns the name under which the BKM's output is stored in the
  evaluation context.

  Priority: `variable.name` > `name` > `id`.
  """
  @spec output_variable_name(BusinessKnowledgeModel.t()) :: String.t()
  def output_variable_name(%BusinessKnowledgeModel{variable: %{name: name}})
      when is_binary(name),
      do: name

  def output_variable_name(%BusinessKnowledgeModel{name: name})
      when is_binary(name),
      do: name

  def output_variable_name(%BusinessKnowledgeModel{id: bkm_id}), do: bkm_id

  # -- Private: resolution & invocation ----------------------------------------

  defp invoke_by_id(bkm_id, bkms_by_id, definitions, context, resolved_imports, visiting) do
    if QualifiedReference.imported?(bkm_id) do
      invoke_imported_bkm(bkm_id, definitions, context, resolved_imports, visiting)
    else
      invoke_local_bkm(bkm_id, bkms_by_id, definitions, context, resolved_imports, visiting)
    end
  end

  defp invoke_local_bkm(bkm_id, bkms_by_id, definitions, context, resolved_imports, visiting) do
    case Map.fetch(bkms_by_id, bkm_id) do
      :error ->
        {:error, :bkm_not_found, %{bkm_id: bkm_id}}

      {:ok, bkm} ->
        if MapSet.member?(visiting, bkm_id) do
          cycle_path = [bkm_id | Enum.reverse(MapSet.to_list(visiting))]
          {:error, :bkm_cycle, %{bkm_ids: cycle_path}}
        else
          invoke_bkm(bkm, definitions, context, resolved_imports, MapSet.put(visiting, bkm_id))
        end
    end
  end

  defp invoke_imported_bkm(qualified_reference, definitions, context, resolved_imports, visiting) do
    case ImportResolver.resolve_imported_element(qualified_reference, definitions, resolved_imports) do
      {:ok, {:business_knowledge_model, imported_bkm}} ->
        if MapSet.member?(visiting, qualified_reference) do
          cycle_path = [qualified_reference | Enum.reverse(MapSet.to_list(visiting))]
          {:error, :bkm_cycle, %{bkm_ids: cycle_path}}
        else
          imported_definitions = find_definitions_for_import(qualified_reference, resolved_imports)
          invoke_bkm(imported_bkm, imported_definitions, context, resolved_imports, MapSet.put(visiting, qualified_reference))
        end

      {:ok, {other_type, _}} ->
        {:error, :bkm_not_found,
         %{bkm_id: qualified_reference,
           message: "Expected BKM but found #{other_type}"}}

      {:error, _, _} = error ->
        error
    end
  end

  defp find_definitions_for_import(qualified_reference, resolved_imports) do
    namespace = QualifiedReference.namespace(qualified_reference)

    case Map.fetch(resolved_imports, namespace) do
      {:ok, definitions} -> definitions
      :error -> %Definitions{raw_xml: ""}
    end
  end

  defp invoke_bkm(bkm, definitions, calling_context, resolved_imports, visiting) do
    started_at = System.monotonic_time(:microsecond)
    body_context = bind_formal_parameters(bkm.encapsulated_logic, calling_context)
    formal_params = build_formal_parameter_trace(bkm.encapsulated_logic, calling_context)
    bkms_by_id = Map.new(definitions.business_knowledge_models, &{&1.id, &1})

    with {:ok, enriched_context, dependent_traces} <-
           resolve_dependent_bkms(
             bkm.knowledge_requirements,
             bkms_by_id,
             definitions,
             calling_context,
             body_context,
             resolved_imports,
             visiting
           ),
         {:ok, result} <- evaluate_function_body(bkm.encapsulated_logic, enriched_context, definitions) do
      duration = System.monotonic_time(:microsecond) - started_at

      trace = %BkmTrace{
        bkm_id: bkm.id,
        bkm_name: bkm.name,
        formal_parameters: formal_params,
        result: result,
        duration_microseconds: duration,
        dependent_bkm_traces: dependent_traces
      }

      {:ok, result, output_variable_name(bkm), trace}
    end
  end

  defp build_formal_parameter_trace(%FunctionDefinition{formal_parameters: parameters}, context) do
    Enum.map(parameters, fn parameter ->
      %{name: parameter.name, bound_value: Map.get(context, parameter.name)}
    end)
  end

  defp bind_formal_parameters(%FunctionDefinition{formal_parameters: parameters}, context) do
    Map.new(parameters, fn parameter -> {parameter.name, Map.get(context, parameter.name)} end)
  end

  defp resolve_dependent_bkms(
         [],
         _bkms_by_id,
         _definitions,
         _calling_context,
         body_context,
         _resolved_imports,
         _visiting
       ),
       do: {:ok, body_context, []}

  defp resolve_dependent_bkms(
         [requirement | rest],
         bkms_by_id,
         definitions,
         calling_context,
         body_context,
         resolved_imports,
         visiting
       ) do
    with {:ok, result, variable_name, bkm_trace} <-
           invoke_by_id(
             requirement.required_knowledge_id,
             bkms_by_id,
             definitions,
             calling_context,
             resolved_imports,
             visiting
           ) do
      updated_body_context = Map.put(body_context, variable_name, result)

      case resolve_dependent_bkms(
             rest,
             bkms_by_id,
             definitions,
             calling_context,
             updated_body_context,
             resolved_imports,
             visiting
           ) do
        {:ok, final_context, rest_traces} ->
          {:ok, final_context, [bkm_trace | rest_traces]}

        error ->
          error
      end
    end
  end

  # -- Private: function body evaluation ---------------------------------------

  defp evaluate_function_body(
         %FunctionDefinition{body: %LiteralExpression{} = literal},
         context,
         _definitions
       ) do
    case DecisionTableEvaluator.eval_expression(literal.compiled_ref, literal.text, context) do
      {:ok, _value} = success -> success
      {:error, reason} -> {:error, :bkm_expression_eval_failed, %{expression: literal.text, reason: reason}}
    end
  end

  defp evaluate_function_body(
         %FunctionDefinition{body: %DecisionTable{} = table},
         context,
         _definitions
       ) do
    case DecisionTableEvaluator.evaluate_compact(table, context) do
      {:ok, _value} = success -> success
      {:error, _code, _metadata} = structured_error -> structured_error
      {:error, reason} -> {:error, :bkm_expression_eval_failed, %{reason: reason}}
    end
  end

  defp evaluate_function_body(%FunctionDefinition{body: body}, context, definitions)
       when not is_nil(body) do
    case DmnEvaluator.evaluate_expression_body(body, context, definitions) do
      {:ok, value, _bkm_traces} -> {:ok, value}
      {:error, _, _} = error -> error
    end
  end

  defp evaluate_function_body(%FunctionDefinition{body: nil}, _context, _definitions) do
    {:error, :bkm_empty_body, %{message: "FunctionDefinition has no body"}}
  end

end
