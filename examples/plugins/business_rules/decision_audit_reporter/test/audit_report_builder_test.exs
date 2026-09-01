defmodule Examples.BusinessRules.DecisionAuditReporter.AuditReportBuilderTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.DecisionAuditReporter.AuditReportBuilder

  @all_rules ["rule_1", "rule_2", "rule_3", "rule_4", "rule_5", "rule_6"]

  defp build_details(overrides) do
    Map.merge(
      %{
        flow_node_instance_id: "fni-1",
        decision_ref: "employee-benefits",
        duration_us: 50_000,
        matched_rules: @all_rules,
        trace: nil
      },
      overrides
    )
  end

  test "assembles complete report with all sections" do
    boundary_results = %{
      "employee-benefits" => [
        %{
          test_case: "platinum",
          input: %{"yearsOfService" => 25},
          result: %{"tier" => "platinum"},
          error: nil
        }
      ]
    }

    report =
      AuditReportBuilder.build(%{
        collection_window_minutes: 5,
        flow_node_instance_details: [
          build_details(%{flow_node_instance_id: "fni-1", duration_us: 40_000}),
          build_details(%{flow_node_instance_id: "fni-2", duration_us: 60_000})
        ],
        boundary_results: boundary_results,
        all_rule_ids_by_model: %{"employee-benefits" => @all_rules}
      })

    assert report.collection_window_minutes == 5
    assert report.generated_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
    assert report.summary.total_decision_executions == 2
    assert report.summary.unique_decision_models == 1
    assert report.summary.avg_latency_us == 50_000
    assert length(report.per_model) == 1
    assert hd(report.per_model).decision_ref == "employee-benefits"
    assert hd(report.per_model).execution_count == 2
    assert hd(report.per_model).rule_coverage.coverage_percent == 100.0
    assert length(hd(report.per_model).boundary_test_results) == 1
    assert is_map(report.compliance)
  end

  test "computes compliance flags correctly" do
    passing_report =
      AuditReportBuilder.build(%{
        collection_window_minutes: 1,
        flow_node_instance_details: [build_details(%{duration_us: 10_000})],
        boundary_results: %{},
        all_rule_ids_by_model: %{"employee-benefits" => @all_rules},
        sla_threshold_us: AuditReportBuilder.default_sla_threshold_us()
      })

    assert passing_report.compliance.all_models_evaluated
    assert passing_report.compliance.no_dead_rules_found
    assert passing_report.compliance.latency_within_sla

    failing_report =
      AuditReportBuilder.build(%{
        collection_window_minutes: 1,
        flow_node_instance_details: [
          build_details(%{duration_us: 200_000, matched_rules: ["rule_1"]})
        ],
        boundary_results: %{
          "employee-benefits" => [
            %{test_case: "bad", input: %{}, result: nil, error: "Error: failed"}
          ]
        },
        all_rule_ids_by_model: %{"employee-benefits" => @all_rules}
      })

    refute failing_report.compliance.no_dead_rules_found
    refute failing_report.compliance.latency_within_sla
    assert failing_report.summary.error_rate == 1
  end

  test "produces valid report with zero counts for empty data" do
    report =
      AuditReportBuilder.build(%{
        collection_window_minutes: 10,
        flow_node_instance_details: [],
        boundary_results: %{},
        all_rule_ids_by_model: %{}
      })

    assert report.summary.total_decision_executions == 0
    assert report.summary.unique_decision_models == 0
    assert report.summary.avg_latency_us == 0
    assert report.summary.p95_latency_us == 0
    assert report.per_model == []
    assert report.compliance.all_models_evaluated
    assert report.compliance.no_dead_rules_found
    assert report.compliance.latency_within_sla
  end

  test "includes models from boundary results even without executions" do
    report =
      AuditReportBuilder.build(%{
        collection_window_minutes: 1,
        flow_node_instance_details: [],
        boundary_results: %{
          "employee-benefits" => [
            %{test_case: "probe", input: %{}, result: %{"tier" => "bronze"}, error: nil}
          ]
        },
        all_rule_ids_by_model: %{"employee-benefits" => @all_rules}
      })

    assert length(report.per_model) == 1
    assert hd(report.per_model).execution_count == 0
    refute report.compliance.all_models_evaluated
  end
end
