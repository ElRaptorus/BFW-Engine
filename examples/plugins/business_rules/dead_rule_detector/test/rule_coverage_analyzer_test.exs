defmodule Examples.BusinessRules.DeadRuleDetector.RuleCoverageAnalyzerTest do
  use ExUnit.Case

  alias Examples.BusinessRules.DeadRuleDetector.RuleCoverageAnalyzer

  @all_rule_ids Enum.map(1..12, &"rule_#{&1}")

  defp trace_with_matched_rule_ids(rule_ids) do
    %{
      "decisions" => [
        %{
          "matched_rules" => Enum.map(rule_ids, fn rule_id -> %{"rule_id" => rule_id} end)
        }
      ]
    }
  end

  test "all rules matched yields zero dead rules and one hundred percent coverage" do
    traces = [trace_with_matched_rule_ids(@all_rule_ids)]

    report = RuleCoverageAnalyzer.analyze(traces, @all_rule_ids)

    assert report.total_rules == 12
    assert report.matched_rules == 12
    assert report.dead_rule_count == 0
    assert report.dead_rules == []
    assert report.coverage_percent == 100.0
    assert report.execution_count == 1
  end

  test "three dead rules are reported with coverage below one hundred percent" do
    matched_rule_ids = Enum.map(1..9, &"rule_#{&1}")
    traces = [trace_with_matched_rule_ids(matched_rule_ids)]

    report = RuleCoverageAnalyzer.analyze(traces, @all_rule_ids)

    assert report.dead_rule_count == 3
    assert report.dead_rules == ["rule_10", "rule_11", "rule_12"]
    assert report.coverage_percent == 75.0
    assert report.matched_rules == 9
  end

  test "empty traces mark every rule as dead with zero percent coverage" do
    report = RuleCoverageAnalyzer.analyze([], @all_rule_ids)

    assert report.execution_count == 0
    assert report.dead_rule_count == 12
    assert report.coverage_percent == 0.0
    assert report.matched_rules == 0
    assert MapSet.new(report.dead_rules) == MapSet.new(@all_rule_ids)
  end

  test "empty rule set does not crash and reports zero totals" do
    report = RuleCoverageAnalyzer.analyze([trace_with_matched_rule_ids(["rule_1"])], [])

    assert report.total_rules == 0
    assert report.dead_rule_count == 0
    assert report.dead_rules == []
    assert report.coverage_percent == 0.0
  end
end
