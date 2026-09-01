defmodule Examples.BusinessRules.DecisionAuditReporter.AuditReportBuilder do
  @moduledoc """
  Assembles a post-execution decision audit report with per-model coverage,
  boundary-test results, and compliance flags for operators and DMN observers.
  """

  alias Examples.BusinessRules.DecisionAuditReporter.CoverageAnalyzer

  @default_sla_threshold_us 100_000

  @doc "Default SLA threshold in microseconds (100 ms)."
  @spec default_sla_threshold_us() :: pos_integer()
  def default_sla_threshold_us, do: @default_sla_threshold_us

  @doc """
  Builds the audit report.

  `input` keys:

  * `:collection_window_minutes`
  * `:flow_node_instance_details`
  * `:boundary_results` — `%{decision_ref => [boundary_test_result]}`
  * `:all_rule_ids_by_model` — `%{decision_ref => [rule_id]}`
  * `:sla_threshold_us` — optional, default `100_000`
  """
  @spec build(map()) :: map()
  def build(input) when is_map(input) do
    sla_threshold_us = Map.get(input, :sla_threshold_us, @default_sla_threshold_us)
    flow_node_instance_details = Map.get(input, :flow_node_instance_details, [])
    boundary_results = Map.get(input, :boundary_results, %{})
    all_rule_ids_by_model = Map.get(input, :all_rule_ids_by_model, %{})

    grouped = Enum.group_by(flow_node_instance_details, & &1.decision_ref)

    decision_refs =
      [Map.keys(grouped), Map.keys(boundary_results), Map.keys(all_rule_ids_by_model)]
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    per_model =
      Enum.map(decision_refs, fn decision_ref ->
        model_instances = Map.get(grouped, decision_ref, [])
        latencies = Enum.map(model_instances, & &1.duration_us)
        rule_ids = Map.get(all_rule_ids_by_model, decision_ref, [])

        %{
          decision_ref: decision_ref,
          execution_count: length(model_instances),
          avg_latency_us: average(latencies),
          rule_coverage: CoverageAnalyzer.analyze(model_instances, rule_ids),
          boundary_test_results: Map.get(boundary_results, decision_ref, [])
        }
      end)

    all_latencies = Enum.map(flow_node_instance_details, & &1.duration_us)
    boundary_tests = boundary_results |> Map.values() |> List.flatten()
    boundary_error_count = Enum.count(boundary_tests, &(&1.error != nil))

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      collection_window_minutes: Map.get(input, :collection_window_minutes, 0),
      summary: %{
        total_decision_executions: length(flow_node_instance_details),
        unique_decision_models: length(decision_refs),
        avg_latency_us: average(all_latencies),
        p95_latency_us: percentile(all_latencies, 95),
        error_rate:
          if(boundary_tests == [],
            do: 0,
            else: boundary_error_count / length(boundary_tests)
          )
      },
      per_model: per_model,
      compliance: %{
        all_models_evaluated: Enum.all?(per_model, &(&1.execution_count > 0)),
        no_dead_rules_found: Enum.all?(per_model, &(&1.rule_coverage.dead_rules == [])),
        latency_within_sla: Enum.all?(per_model, &(&1.avg_latency_us < sla_threshold_us))
      }
    }
  end

  defp average([]), do: 0

  defp average(values) do
    round(Enum.sum(values) / length(values))
  end

  defp percentile([], _percentile_rank), do: 0

  defp percentile(values, percentile_rank) do
    sorted_values = Enum.sort(values)
    index = max(0, ceil(length(sorted_values) * percentile_rank / 100) - 1)
    Enum.at(sorted_values, index)
  end
end
