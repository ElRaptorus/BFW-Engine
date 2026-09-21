defmodule BfwEngine.DMN.Evaluator.HitPolicies do
  @moduledoc """
  Hit policy implementations for DMN decision tables.

  Each function receives the list of matched rules (as `{rule, output_values}`
  tuples) and returns the shaped result.
  """

  alias BfwEngine.DMN.Evaluator.DecisionTableEvaluator

  @spec apply(atom(), atom() | nil, [{struct(), map()}], struct()) ::
          {:ok, term()} | {:error, atom(), map()}

  def apply(:unique, _aggregation, [], table), do: DecisionTableEvaluator.evaluate_default_outputs(table)

  def apply(:unique, _aggregation, [{_rule, output}], _table), do: {:ok, output}

  def apply(:unique, _aggregation, matched, _table) when length(matched) > 1 do
    {:error, :hit_policy_violation,
     %{policy: :unique,
       message: "#{length(matched)} rules matched — UNIQUE requires exactly 0 or 1"}}
  end

  def apply(:first, _aggregation, [], table), do: DecisionTableEvaluator.evaluate_default_outputs(table)
  def apply(:first, _aggregation, [{_rule, output} | _], _table), do: {:ok, output}

  def apply(:any, _aggregation, [], table), do: DecisionTableEvaluator.evaluate_default_outputs(table)

  def apply(:any, _aggregation, matched, _table) do
    outputs = Enum.map(matched, fn {_rule, output} -> output end)

    if Enum.all?(outputs, &(&1 == hd(outputs))) do
      {:ok, hd(outputs)}
    else
      {:error, :hit_policy_violation, %{policy: :any, message: "Matched rules produce different outputs"}}
    end
  end

  def apply(:collect, aggregation, matched, _table) do
    outputs = Enum.map(matched, fn {_rule, output} -> output end)
    apply_aggregation(aggregation, outputs)
  end

  def apply(:rule_order, _aggregation, matched, _table) do
    {:ok, Enum.map(matched, fn {_rule, output} -> output end)}
  end

  def apply(:output_order, _aggregation, matched, table) do
    sorted = sort_by_output_priority(matched, table)
    {:ok, Enum.map(sorted, fn {_rule, output} -> output end)}
  end

  def apply(:priority, _aggregation, [], table), do: DecisionTableEvaluator.evaluate_default_outputs(table)

  def apply(:priority, _aggregation, matched, table) do
    sorted = sort_by_output_priority(matched, table)
    [{_rule, output} | _] = sorted
    {:ok, output}
  end

  # --- Aggregation for COLLECT -----------------------------------------------

  defp apply_aggregation(nil, outputs), do: {:ok, outputs}

  defp apply_aggregation(:sum, outputs) do
    {:ok, sum_numeric_outputs(outputs)}
  end

  defp apply_aggregation(:min, outputs) do
    {:ok, min_numeric_outputs(outputs)}
  end

  defp apply_aggregation(:max, outputs) do
    {:ok, max_numeric_outputs(outputs)}
  end

  defp apply_aggregation(:count, outputs) do
    {:ok, length(outputs)}
  end

  defp sum_numeric_outputs(outputs) do
    outputs
    |> Enum.flat_map(&Map.values/1)
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  defp min_numeric_outputs(outputs) do
    outputs
    |> Enum.flat_map(&Map.values/1)
    |> Enum.filter(&is_number/1)
    |> Enum.min(fn -> nil end)
  end

  defp max_numeric_outputs(outputs) do
    outputs
    |> Enum.flat_map(&Map.values/1)
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
  end

  # --- Output priority sorting (for OUTPUT ORDER and PRIORITY) ---------------

  defp sort_by_output_priority(matched, table) do
    priority_lists =
      Enum.map(table.outputs, fn output ->
        case output.output_values do
          nil -> nil
          values_string -> parse_priority_list(values_string)
        end
      end)

    Enum.sort_by(matched, fn {_rule, output_map} ->
      output_map
      |> Map.values()
      |> Enum.zip(priority_lists)
      |> Enum.map(&priority_rank/1)
    end)
  end

  defp priority_rank({_value, nil}), do: 0

  defp priority_rank({value, list}) do
    Enum.find_index(list, &(&1 == value)) || length(list)
  end

  defp parse_priority_list(values_string) do
    values_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&unquote_value/1)
  end

  defp unquote_value("\"" <> rest) do
    String.trim_trailing(rest, "\"")
  end

  defp unquote_value(value), do: value
end
