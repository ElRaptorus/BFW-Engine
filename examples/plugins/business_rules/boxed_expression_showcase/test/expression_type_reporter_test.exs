defmodule Examples.BusinessRules.BoxedExpressionShowcase.ExpressionTypeReporterTest do
  use ExUnit.Case

  alias Examples.BusinessRules.BoxedExpressionShowcase.ExpressionTypeReporter

  @all_decision_names [
    "Department Multiplier",
    "Performance Bonus",
    "Certification Allowance",
    "Certification Total",
    "Benefits Package",
    "Salary Bands",
    "Eligible for Promotion",
    "Qualified Certifications",
    "Certification Details",
    "All Certs Premium",
    "Has Premium Cert",
    "Total Compensation"
  ]

  @expected_types %{
    "Department Multiplier" => :decision_table,
    "Performance Bonus" => :boxed_invocation,
    "Certification Allowance" => :boxed_list,
    "Certification Total" => :literal_expression,
    "Benefits Package" => :boxed_context,
    "Salary Bands" => :relation,
    "Eligible for Promotion" => :boxed_conditional,
    "Qualified Certifications" => :boxed_filter,
    "Certification Details" => :boxed_for,
    "All Certs Premium" => :boxed_every,
    "Has Premium Cert" => :boxed_some,
    "Total Compensation" => :literal_expression
  }

  test "expression_type_for/1 maps each catalog decision to its expression type" do
    Enum.each(@expected_types, fn {decision_name, expected_type} ->
      assert ExpressionTypeReporter.expression_type_for(decision_name) == expected_type
    end)
  end

  test "expression_type_for/1 returns :unknown for unrecognized decision names" do
    assert ExpressionTypeReporter.expression_type_for("Nonexistent Decision") == :unknown
  end

  test "all_expression_types/0 returns sorted unique expression type atoms" do
    types = ExpressionTypeReporter.all_expression_types()

    assert types ==
             [
               :boxed_conditional,
               :boxed_context,
               :boxed_every,
               :boxed_filter,
               :boxed_for,
               :boxed_invocation,
               :boxed_list,
               :boxed_some,
               :decision_table,
               :literal_expression,
               :relation
             ]
  end

  test "build_report/1 with empty trace returns empty list" do
    assert ExpressionTypeReporter.build_report(%{}) == []
    assert ExpressionTypeReporter.build_report(%{"decisions" => []}) == []
  end

  test "build_report/1 with full 12-decision trace maps each entry correctly" do
    trace = %{
      "decisions" =>
        Enum.map(@all_decision_names, fn decision_name ->
          %{
            "decision_name" => decision_name,
            "hit_policy" => if(decision_name == "Department Multiplier", do: :unique, else: nil),
            "result" => sample_result_for(decision_name),
            "duration_microseconds" => 42
          }
        end)
    }

    report = ExpressionTypeReporter.build_report(trace)

    assert length(report) == 12

    Enum.each(report, fn entry ->
      assert entry.expression_type == Map.fetch!(@expected_types, entry.decision)
      assert entry.duration_us == 42
    end)

    assert Enum.find(report, &(&1.decision == "Total Compensation")).result == 104_250
    assert Enum.find(report, &(&1.decision == "Department Multiplier")).hit_policy == :unique
  end

  defp sample_result_for("Department Multiplier"), do: 1.15
  defp sample_result_for("Performance Bonus"), do: 4_000
  defp sample_result_for("Certification Allowance"), do: [2000, 3000, 0, 0]
  defp sample_result_for("Certification Total"), do: 5000
  defp sample_result_for("Benefits Package"), do: %{"healthTier" => "standard"}
  defp sample_result_for("Salary Bands"), do: [%{"level" => "junior"}]
  defp sample_result_for("Eligible for Promotion"), do: true
  defp sample_result_for("Qualified Certifications"), do: ["AWS", "PMP"]
  defp sample_result_for("Certification Details"), do: [%{"name" => "AWS"}]
  defp sample_result_for("All Certs Premium"), do: false
  defp sample_result_for("Has Premium Cert"), do: false
  defp sample_result_for("Total Compensation"), do: 104_250
  defp sample_result_for(_other), do: nil
end
