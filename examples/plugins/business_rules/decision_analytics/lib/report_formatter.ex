defmodule Examples.BusinessRules.DecisionAnalytics.ReportFormatter do
  @moduledoc """
  Pure functions that turn `AnalyticsCollector` stats into a JSON-ready
  analytics report with per-decision latency histograms and top rules.
  """

  alias Examples.BusinessRules.DecisionAnalytics.LatencyHistogram

  @doc "Formats the collector stats map into a report."
  @spec format(%{String.t() => map()}) :: map()
  def format(stats) when is_map(stats) do
    decisions =
      stats
      |> Map.values()
      |> Enum.map(&format_decision/1)

    total_evaluations =
      Enum.reduce(decisions, 0, fn decision, acc -> acc + decision.evaluation_count end)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      decisions: decisions,
      totals: %{
        total_evaluations: total_evaluations,
        unique_decisions: length(decisions)
      }
    }
  end

  defp format_decision(decision_stats) do
    histogram =
      LatencyHistogram.new()
      |> LatencyHistogram.add_all(Map.get(decision_stats, :latencies, []))

    top_rules =
      decision_stats
      |> Map.get(:rule_hit_counts, %{})
      |> Enum.sort_by(fn {_rule_identifier, hit_count} -> -hit_count end)
      |> Enum.take(10)
      |> Enum.map(fn {rule_identifier, hit_count} -> [rule_identifier, hit_count] end)

    %{
      decision_ref: Map.get(decision_stats, :decision_ref, "unknown"),
      evaluation_count: Map.get(decision_stats, :evaluation_count, 0),
      avg_latency_us: round(LatencyHistogram.average(histogram)),
      p95_latency_us: LatencyHistogram.p95(histogram),
      p99_latency_us: LatencyHistogram.p99(histogram),
      min_latency_us: LatencyHistogram.min(histogram),
      max_latency_us: LatencyHistogram.max(histogram),
      top_rules: top_rules
    }
  end
end
