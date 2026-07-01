defmodule Examples.BusinessRules.DeadRuleDetector.RuleCoverageAnalyzer do
  @moduledoc """
  Pure functions that compare aggregated DMN execution traces against the full
  rule catalog to identify never-matched (dead) rules.
  """

  @doc """
  Builds a coverage report from execution traces and the complete rule id list.

  Each trace is expected to contain a `"decisions"` list; each decision may
  include `"matched_rules"` entries with a `"rule_id"` field.
  """
  @spec analyze([map()], [String.t()]) :: map()
  def analyze(traces, []) do
    %{
      total_rules: 0,
      matched_rules: 0,
      dead_rules: [],
      dead_rule_count: 0,
      coverage_percent: 0.0,
      execution_count: length(traces)
    }
  end

  def analyze(traces, all_rule_ids) do
    matched =
      traces
      |> Enum.flat_map(fn trace ->
        trace
        |> Map.get("decisions", [])
        |> Enum.flat_map(&Map.get(&1, "matched_rules", []))
        |> Enum.map(&Map.get(&1, "rule_id"))
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    all = MapSet.new(all_rule_ids)
    dead = MapSet.difference(all, matched)

    %{
      total_rules: MapSet.size(all),
      matched_rules: MapSet.size(matched),
      dead_rules: MapSet.to_list(dead) |> Enum.sort(),
      dead_rule_count: MapSet.size(dead),
      coverage_percent: Float.round(MapSet.size(matched) / max(MapSet.size(all), 1) * 100, 1),
      execution_count: length(traces)
    }
  end
end
