defmodule Examples.BusinessRules.DecisionAuditReporter.CoverageAnalyzerTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.DecisionAuditReporter.CoverageAnalyzer

  @all_rules ["rule_1", "rule_2", "rule_3", "rule_4", "rule_5", "rule_6"]

  defp build_details(matched_rules) do
    %{
      flow_node_instance_id: "fni-1",
      decision_ref: "employee-benefits",
      duration_us: 1000,
      matched_rules: matched_rules,
      trace: nil
    }
  end

  test "computes matched vs total rules" do
    result =
      CoverageAnalyzer.analyze(
        [build_details(["rule_1", "rule_2"]), build_details(["rule_2", "rule_3"])],
        @all_rules
      )

    assert result.total_rules == 6
    assert result.matched_rules == 3
    assert result.coverage_percent == 50.0
  end

  test "identifies dead rules correctly" do
    result = CoverageAnalyzer.analyze([build_details(["rule_1"])], @all_rules)

    assert result.dead_rules == ["rule_2", "rule_3", "rule_4", "rule_5", "rule_6"]
  end

  test "returns 0% coverage for empty FNI input" do
    result = CoverageAnalyzer.analyze([], @all_rules)

    assert result.matched_rules == 0
    assert result.coverage_percent == 0.0
    assert result.dead_rules == @all_rules
  end

  test "returns 100% coverage when all rules are matched" do
    result =
      CoverageAnalyzer.analyze(
        [
          build_details(["rule_1", "rule_2", "rule_3"]),
          build_details(["rule_4", "rule_5", "rule_6"])
        ],
        @all_rules
      )

    assert result.coverage_percent == 100.0
    assert result.dead_rules == []
  end

  test "returns 0% coverage when all_rule_ids is empty" do
    result = CoverageAnalyzer.analyze([build_details(["rule_1"])], [])

    assert result.total_rules == 0
    assert result.coverage_percent == 0.0
  end
end
