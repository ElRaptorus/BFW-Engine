defmodule EvilEngine.DMN.Evaluator.DecisionTableEvaluator do
  @moduledoc """
  Shared decision table evaluation primitives used by both the main
  `Evaluator` (with tracing) and `BkmInvoker` (compact, no tracing).

  Contains: expression evaluation, input entry matching, output entry
  extraction, and the compact evaluate-without-tracing pipeline.
  """

  require Logger

  alias EvilEngine.DMN.Evaluator.HitPolicies
  alias EvilEngine.DMN.Model.DecisionTable
  alias EvilEngine.DMN.Model.Input
  alias EvilEngine.DMN.Model.InputEntry
  alias EvilEngine.Expressions

  # --- Expression evaluation helpers ------------------------------------------

  @doc """
  Evaluates a precompiled expression reference, falling back to raw text
  evaluation when no compiled reference is available.
  """
  @spec eval_expression(reference | nil, String.t() | nil, map()) ::
          {:ok, term()} | {:error, String.t()}
  def eval_expression(reference, _text, context) when not is_nil(reference) do
    Expressions.evaluate(reference, context)
  end

  def eval_expression(nil, text, context) do
    Expressions.eval(text, context)
  end

  @doc """
  Evaluates a decision table input's expression against the given context.
  Uses the precompiled reference when available, otherwise falls back to
  raw expression text evaluation.
  """
  @spec eval_input_expression(Input.t(), String.t(), map()) ::
          {:ok, term()} | {:error, String.t()}
  def eval_input_expression(
        %Input{compiled_expression_ref: reference, input_expression: expression},
        _display_expression,
        context
      )
      when not is_nil(reference) and not is_nil(expression) do
    Expressions.evaluate(reference, context)
  end

  def eval_input_expression(_input, expression, context) do
    Expressions.eval(expression, context)
  end

  # --- Input entry matching ---------------------------------------------------

  @doc """
  Tests whether a single input entry (unary test) matches the given value.
  Dash (`"-"`) and empty string are wildcard matches. Logs a warning on
  unexpected evaluation results and treats them as no-match.
  """
  @spec evaluate_input_entry(InputEntry.t(), term()) :: boolean()
  def evaluate_input_entry(%InputEntry{text: "-"}, _value), do: true
  def evaluate_input_entry(%InputEntry{text: ""}, _value), do: true

  def evaluate_input_entry(%InputEntry{compiled_ref: reference, text: text}, value)
      when not is_nil(reference) do
    unary_context = %{"__unary_input__" => value}

    case Expressions.evaluate(reference, unary_context) do
      {:ok, true} ->
        true

      {:ok, false} ->
        false

      other ->
        Logger.warning(
          "DMN unary test evaluation failed, treating as no-match: " <>
            "expression=#{inspect(text)}, value=#{inspect(value)}, result=#{inspect(other)}"
        )

        false
    end
  end

  def evaluate_input_entry(%InputEntry{text: text}, value) do
    case Expressions.evaluate_unary(text, value) do
      {:ok, true} ->
        true

      {:ok, false} ->
        false

      other ->
        Logger.warning(
          "DMN unary test evaluation failed, treating as no-match: " <>
            "expression=#{inspect(text)}, value=#{inspect(value)}, result=#{inspect(other)}"
        )

        false
    end
  end

  # --- Output entry extraction ------------------------------------------------

  @doc """
  Evaluates all output entries for a matched rule, returning a map of
  `output_key => value`. Falls back to raw entry text when evaluation fails.
  """
  @spec evaluate_output_entries([struct()], [struct()]) :: map()
  def evaluate_output_entries(output_entries, outputs) do
    output_entries
    |> Enum.with_index()
    |> Map.new(fn {entry, index} ->
      output = Enum.at(outputs, index)
      key = named_output_key(output, index)

      value =
        case eval_expression(entry.compiled_ref, entry.text, %{}) do
          {:ok, evaluated_value} ->
            evaluated_value

          error ->
            Logger.warning(
              "DMN output entry evaluation failed, falling back to raw text: " <>
                "output=#{inspect(key)}, expression=#{inspect(entry.text)}, error=#{inspect(error)}"
            )

            entry.text
        end

      {key, value}
    end)
  end

  # --- Output key naming ------------------------------------------------------

  @doc """
  Returns a display key for a decision table output column.
  Priority: `name` > `label` > `"output_{index}"`.
  """
  @spec named_output_key(struct() | nil, non_neg_integer()) :: String.t()
  def named_output_key(nil, index), do: "output_#{index}"

  def named_output_key(output, index) do
    cond do
      is_binary(output.name) and output.name != "" -> output.name
      is_binary(output.label) and output.label != "" -> output.label
      true -> "output_#{index}"
    end
  end

  # --- Input values constraint validation ------------------------------------

  @doc """
  Validates resolved input values against each column's `inputValues`
  allowed-values constraint (DMN §8.3.1). Returns `:ok` if all values
  are within the allowed domain, or `{:error, :input_value_violation, %{...}}`
  on the first failing column.

  Columns without `input_values` are skipped.
  """
  @spec validate_input_constraints([Input.t()], [term()]) ::
          :ok | {:error, atom(), map()}
  def validate_input_constraints(inputs, resolved_values) do
    inputs
    |> Enum.zip(resolved_values)
    |> Enum.find_value(:ok, fn {input, value} ->
      check_single_input_constraint(input, value)
    end)
  end

  defp check_single_input_constraint(%Input{input_values: nil}, _value), do: nil
  defp check_single_input_constraint(%Input{input_values: ""}, _value), do: nil

  defp check_single_input_constraint(%Input{compiled_input_values_ref: reference, input_values: text} = input, value)
       when not is_nil(reference) do
    unary_context = %{"__unary_input__" => value}

    case Expressions.evaluate(reference, unary_context) do
      {:ok, true} ->
        nil

      {:ok, false} ->
        {:error, :input_value_violation,
         %{
           input_id: input.id,
           input_label: input.label,
           value: value,
           allowed_values: text,
           message: "Value #{inspect(value)} is not in allowed values: #{text}"
         }}

      _other ->
        nil
    end
  end

  defp check_single_input_constraint(%Input{input_values: text} = input, value) do
    case Expressions.evaluate_unary(text, value) do
      {:ok, true} ->
        nil

      {:ok, false} ->
        {:error, :input_value_violation,
         %{
           input_id: input.id,
           input_label: input.label,
           value: value,
           allowed_values: text,
           message: "Value #{inspect(value)} is not in allowed values: #{text}"
         }}

      _other ->
        nil
    end
  end

  # --- Compact evaluation pipeline (no tracing) -------------------------------

  @doc """
  Resolves all input expressions for a decision table. Returns the
  resolved values without tracing information.
  """
  @spec resolve_table_inputs(DecisionTable.t(), map()) ::
          {:ok, [term()]} | {:error, String.t()}
  def resolve_table_inputs(table, context) do
    results =
      Enum.map(table.inputs, fn input ->
        expression = input.input_expression || input.label || input.id
        eval_input_expression(input, expression, context)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, _} = error ->
        error

      nil ->
        {:ok, Enum.map(results, fn {:ok, value} -> value end)}
    end
  end

  @doc """
  Matches rules against resolved input values. Returns matched rules
  as `{rule, output_values}` tuples without tracing information.

  When a deploy-time rule index is available, candidate rules are
  pre-filtered via O(1) index lookup on indexed columns before
  falling back to FEEL evaluation on non-indexed columns.
  """
  @spec match_table_rules(DecisionTable.t(), [term()]) ::
          {:ok, [{struct(), map()}]}
  def match_table_rules(table, resolved_inputs) do
    candidate_rules = filter_by_rule_index(table, resolved_inputs)

    matched =
      candidate_rules
      |> Enum.filter(fn {rule, indexed_columns} ->
        rule_matches_non_indexed?(rule, resolved_inputs, indexed_columns)
      end)
      |> Enum.map(fn {rule, _indexed_columns} ->
        {rule, evaluate_output_entries(rule.output_entries, table.outputs)}
      end)

    {:ok, matched}
  end

  defp rule_matches_non_indexed?(rule, resolved_inputs, indexed_columns) do
    rule.input_entries
    |> Enum.with_index()
    |> Enum.all?(fn {entry, column_index} ->
      column_index in indexed_columns or
        evaluate_input_entry(entry, Enum.at(resolved_inputs, column_index))
    end)
  end

  defp filter_by_rule_index(%DecisionTable{rule_index: nil} = table, _resolved_inputs) do
    indexed_columns = MapSet.new()
    Enum.map(table.rules, fn rule -> {rule, indexed_columns} end)
  end

  defp filter_by_rule_index(%DecisionTable{rule_index: rule_index} = table, resolved_inputs) do
    indexed_columns = MapSet.new(Map.keys(rule_index))

    candidate_rule_indices =
      rule_index
      |> Enum.reduce(nil, fn {column_index, %{values: value_map, wildcards: wildcard_set}},
                             accumulator ->
        value = Enum.at(resolved_inputs, column_index)
        matching_indices = Map.get(value_map, value, MapSet.new())
        column_candidates = MapSet.union(matching_indices, wildcard_set)

        case accumulator do
          nil -> column_candidates
          existing -> MapSet.intersection(existing, column_candidates)
        end
      end)

    candidate_rule_indices = candidate_rule_indices || MapSet.new()

    table.rules
    |> Enum.with_index()
    |> Enum.filter(fn {_rule, rule_index_number} ->
      MapSet.member?(candidate_rule_indices, rule_index_number)
    end)
    |> Enum.map(fn {rule, _rule_index_number} -> {rule, indexed_columns} end)
  end

  @doc """
  Full compact decision table evaluation pipeline (resolve inputs, match
  rules, apply hit policy). Used by `BkmInvoker` for BKM bodies that are
  decision tables.
  """
  @spec evaluate_compact(DecisionTable.t(), map()) ::
          {:ok, term()} | {:error, atom(), map()} | {:error, String.t()}
  def evaluate_compact(table, context) do
    with {:ok, resolved_inputs} <- resolve_table_inputs(table, context),
         :ok <- validate_input_constraints(table.inputs, resolved_inputs),
         {:ok, matched_rules} <- match_table_rules(table, resolved_inputs),
         {:ok, result} <- HitPolicies.apply(table.hit_policy, table.aggregation, matched_rules, table) do
      {:ok, unwrap_single_output(result, table)}
    end
  end

  @doc """
  Evaluates default output values for a decision table when no rules match.

  Returns `nil` if no output column declares a `default_output_value`.
  Otherwise, evaluates each column's default FEEL expression and returns
  the result as a map of `output_key => value`.
  """
  @spec evaluate_default_outputs(DecisionTable.t()) :: {:ok, term()}
  def evaluate_default_outputs(%DecisionTable{outputs: outputs} = table) do
    if Enum.all?(outputs, &is_nil(&1.default_output_value)) do
      {:ok, nil}
    else
      default_map =
        outputs
        |> Enum.with_index()
        |> Map.new(fn {output, index} ->
          key = named_output_key(output, index)
          value = evaluate_single_default(output)
          {key, value}
        end)

      {:ok, unwrap_single_output(default_map, table)}
    end
  end

  defp evaluate_single_default(%{default_output_value: nil}), do: nil
  defp evaluate_single_default(%{default_output_value: ""}), do: nil

  defp evaluate_single_default(%{compiled_default_ref: reference, default_output_value: text})
       when not is_nil(reference) do
    case Expressions.evaluate(reference, %{}) do
      {:ok, value} -> value
      _error -> text
    end
  end

  defp evaluate_single_default(%{default_output_value: text}) do
    case Expressions.eval(text, %{}) do
      {:ok, value} -> value
      _error -> text
    end
  end

  @doc """
  Unwraps single-output decision tables: if the table has exactly one
  output column and the result is a single-entry map, returns the value
  directly instead of the map wrapper.
  """
  @spec unwrap_single_output(term(), DecisionTable.t()) :: term()
  def unwrap_single_output(result, %DecisionTable{outputs: [_single]}) when is_map(result) do
    case Map.values(result) do
      [single_value] -> single_value
      _ -> result
    end
  end

  def unwrap_single_output(result, _table), do: result
end
