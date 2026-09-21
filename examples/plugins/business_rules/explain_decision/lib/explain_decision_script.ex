defmodule Examples.BusinessRules.ExplainDecision.Script do
  @moduledoc """
  Named script that turns a DMN evaluation trace on the token into a human-readable explanation.
  """

  @behaviour BfwEngine.Plugin.NamedScript

  @doc "Builds an explanation string from the trace.decisions list on the script payload."
  @impl true
  def handle_enter(_flow_node, payload, _context) when is_map(payload) do
    trace = Map.get(payload, "trace", %{})
    decisions = Map.get(trace, "decisions", [])

    explanation =
      decisions
      |> Enum.map(&explain_single_decision/1)
      |> Enum.join("\n\n")

    {:ok, %{"explanation" => explanation, "decision_count" => length(decisions)}}
  end

  def handle_enter(_flow_node, _payload, _context) do
    {:ok, %{"explanation" => "", "decision_count" => 0}}
  end

  defp explain_single_decision(decision_trace) when is_map(decision_trace) do
    decision_name = Map.get(decision_trace, "decision_name", "Unknown")
    inputs = Map.get(decision_trace, "inputs", [])
    matched_rules = Map.get(decision_trace, "matched_rules", [])
    result = Map.get(decision_trace, "result")

    input_summary =
      inputs
      |> Enum.map(&format_input_line/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

    rule_count = length(matched_rules)

    "Decision '#{decision_name}': Given #{input_summary} → " <>
      "#{rule_count} rule(s) matched → Result: #{inspect(result)}"
  end

  defp explain_single_decision(_decision_trace) do
    "Decision 'Unknown': Given  → 0 rule(s) matched → Result: nil"
  end

  defp format_input_line(input) when is_map(input) do
    label = Map.get(input, "input_label") || Map.get(input, "input_id", "input")
    value = Map.get(input, "resolved_value")
    "#{label} = #{inspect(value)}"
  end

  defp format_input_line(_input), do: ""
end
