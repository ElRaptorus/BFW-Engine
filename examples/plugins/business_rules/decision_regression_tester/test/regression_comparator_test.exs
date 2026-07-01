defmodule Examples.BusinessRules.DecisionRegressionTester.RegressionComparatorTest do
  use ExUnit.Case

  alias Examples.BusinessRules.DecisionRegressionTester.RegressionComparator

  @input %{"annualIncome" => 50_000, "filingStatus" => "single"}

  test "identical results produce status :identical" do
    result = %{result: %{"taxRate" => 0.25}, matched_rules: ["Rule_single_middle"], hit_policy: :first}
    comparison = RegressionComparator.compare(result, result, @input)

    assert comparison.status == :identical
    assert comparison.v1 == comparison.v2
    assert comparison.input == @input
  end

  test "different results produce status :diverged with rule metadata" do
    result_v1 = %{
      result: %{"taxRate" => 0.25, "bracket" => "middle"},
      matched_rules: ["Rule_single_middle"],
      hit_policy: :first
    }

    result_v2 = %{
      result: %{"taxRate" => 0.22, "bracket" => "middle"},
      matched_rules: ["Rule_single_middle_v2"],
      hit_policy: :first
    }

    comparison = RegressionComparator.compare(result_v1, result_v2, @input)

    assert comparison.status == :diverged
    assert comparison.v1_matched_rules == ["Rule_single_middle"]
    assert comparison.v2_matched_rules == ["Rule_single_middle_v2"]
    assert comparison.v1_hit_policy == :first
    assert comparison.v2_hit_policy == :first
  end

  test "build_report/1 with all identical inputs reports no regression" do
    comparisons = [
      %{status: :identical, input: @input, v1: 1, v2: 1},
      %{status: :identical, input: %{"annualIncome" => 10_000}, v1: 0, v2: 0}
    ]

    report = RegressionComparator.build_report(comparisons)

    assert report.total_inputs == 2
    assert report.identical == 2
    assert report.diverged == 0
    assert report.regression_detected == false
    assert report.details == []
  end

  test "build_report/1 with diverged inputs reports correct counts" do
    comparisons = [
      %{status: :identical, input: @input, v1: 1, v2: 1},
      %{status: :diverged, input: %{"annualIncome" => 25_000}, v1: 1, v2: 2}
    ]

    report = RegressionComparator.build_report(comparisons)

    assert report.total_inputs == 2
    assert report.identical == 1
    assert report.diverged == 1
    assert report.regression_detected == true
    assert length(report.details) == 1
  end

  test "build_report/1 with empty list does not crash" do
    report = RegressionComparator.build_report([])

    assert report.total_inputs == 0
    assert report.identical == 0
    assert report.diverged == 0
    assert report.regression_detected == false
    assert report.details == []
  end
end
