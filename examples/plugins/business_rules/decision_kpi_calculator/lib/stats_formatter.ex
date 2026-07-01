defmodule Examples.BusinessRules.KpiCalculator.StatsFormatter do
  @moduledoc """
  Pure functions that turn raw `KpiAggregator` per-decision state into
  human-readable KPI report maps.
  """

  @doc """
  Formats one per-decision aggregate map into a report.

  The second argument is the global aggregate map (`first_seen`, `last_seen`,
  `total_evaluations`, `total_errors`) used for throughput and error rate.
  """
  @spec format(map(), map()) :: map()
  def format(per_decision_stats, global_stats) do
    evaluation_count = Map.get(per_decision_stats, :count, 0)

    if evaluation_count == 0 do
      zeroed_report(per_decision_stats)
    else
      populated_report(per_decision_stats, global_stats, evaluation_count)
    end
  end

  defp zeroed_report(per_decision_stats) do
    %{
      decision_ref: Map.get(per_decision_stats, :decision_ref, "unknown"),
      evaluation_count: 0,
      avg_duration_us: 0,
      p95_duration_us: 0,
      min_duration_us: 0,
      max_duration_us: 0,
      throughput_per_minute: 0.0,
      error_rate: 0.0,
      top_rules: [],
      coverage_percent: 0.0
    }
  end

  defp populated_report(per_decision_stats, global_stats, evaluation_count) do
    total_duration_us = Map.get(per_decision_stats, :total_duration_us, 0)
    durations = Map.get(per_decision_stats, :durations, [])
    rule_hits = Map.get(per_decision_stats, :rule_hits, %{})
    errors = Map.get(per_decision_stats, :errors, 0)

    %{
      decision_ref: Map.get(per_decision_stats, :decision_ref, "unknown"),
      evaluation_count: evaluation_count,
      avg_duration_us: div(total_duration_us, evaluation_count),
      p95_duration_us: percentile(durations, 95),
      min_duration_us: Map.get(per_decision_stats, :min_duration_us, 0) || 0,
      max_duration_us: Map.get(per_decision_stats, :max_duration_us, 0),
      throughput_per_minute:
        throughput_per_minute(evaluation_count, global_stats.first_seen, global_stats.last_seen),
      error_rate: error_rate(errors, evaluation_count),
      top_rules: top_rules(rule_hits),
      coverage_percent: coverage_percent(rule_hits, per_decision_stats)
    }
  end

  defp percentile([], _percentile_rank), do: 0

  defp percentile(durations, percentile_rank) when is_list(durations) do
    sorted_durations = Enum.sort(durations)
    length = length(sorted_durations)
    index = max(0, ceil(length * percentile_rank / 100) - 1)
    Enum.at(sorted_durations, index)
  end

  defp throughput_per_minute(_evaluation_count, nil, _last_seen), do: 0.0

  defp throughput_per_minute(_evaluation_count, _first_seen, nil), do: 0.0

  defp throughput_per_minute(evaluation_count, first_seen, last_seen) do
    elapsed_seconds = DateTime.diff(last_seen, first_seen, :second)

    if elapsed_seconds <= 0 do
      evaluation_count * 1.0
    else
      elapsed_minutes = elapsed_seconds / 60
      evaluation_count / elapsed_minutes
    end
  end

  defp error_rate(errors, evaluation_count) when evaluation_count > 0 do
    errors / evaluation_count
  end

  defp error_rate(_errors, _evaluation_count), do: 0.0

  defp top_rules(rule_hits) do
    rule_hits
    |> Enum.sort_by(fn {_rule_identifier, hit_count} -> -hit_count end)
    |> Enum.take(5)
    |> Enum.map(fn {rule_identifier, hit_count} -> {rule_identifier, hit_count} end)
  end

  defp coverage_percent(rule_hits, per_decision_stats) do
    distinct_rules_hit = map_size(rule_hits)

    total_rule_count =
      case Map.get(per_decision_stats, :total_rule_count) do
        count when is_integer(count) and count > 0 -> count
        _unknown -> max(distinct_rules_hit, 1)
      end

    distinct_rules_hit / total_rule_count * 100.0
  end
end
