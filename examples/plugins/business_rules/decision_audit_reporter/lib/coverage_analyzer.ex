defmodule Examples.BusinessRules.DecisionAuditReporter.CoverageAnalyzer do
  @moduledoc """
  Pure functions that compare runtime-matched DMN rule IDs against the full
  catalog to identify never-matched (dead) rules.
  """

  @type coverage_result :: %{
          total_rules: non_neg_integer(),
          matched_rules: non_neg_integer(),
          dead_rules: [String.t()],
          coverage_percent: float()
        }

  @doc "Builds coverage from inspected flow node instances and the complete rule id list."
  @spec analyze([map()], [String.t()]) :: coverage_result()
  def analyze(_flow_node_instance_details, []) do
    %{
      total_rules: 0,
      matched_rules: 0,
      dead_rules: [],
      coverage_percent: 0.0
    }
  end

  def analyze(flow_node_instance_details, all_rule_ids) do
    matched =
      flow_node_instance_details
      |> Enum.flat_map(&Map.get(&1, :matched_rules, []))
      |> MapSet.new()

    all = MapSet.new(all_rule_ids)
    dead = MapSet.difference(all, matched)

    %{
      total_rules: MapSet.size(all),
      matched_rules: MapSet.size(matched),
      dead_rules: MapSet.to_list(dead) |> Enum.sort(),
      coverage_percent: Float.round(MapSet.size(matched) / max(MapSet.size(all), 1) * 100, 2)
    }
  end
end
