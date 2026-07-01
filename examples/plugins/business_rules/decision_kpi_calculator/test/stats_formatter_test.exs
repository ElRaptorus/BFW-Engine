defmodule Examples.BusinessRules.KpiCalculator.StatsFormatterTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.KpiCalculator.StatsFormatter

  test "correct avg, p95, min, max calculations" do
    per_decision_stats = %{
      decision_ref: "shipping-rates",
      count: 5,
      total_duration_us: 100_000,
      min_duration_us: 8_100,
      max_duration_us: 45_200,
      durations: [8_100, 10_000, 20_000, 30_000, 45_200],
      rule_hits: %{"Rule_1" => 3, "Rule_3" => 2},
      errors: 0,
      total_rule_count: 8
    }

    global_stats = %{
      total_evaluations: 5,
      total_errors: 0,
      first_seen: ~U[2026-05-20T10:00:00Z],
      last_seen: ~U[2026-05-20T10:04:00Z]
    }

    report = StatsFormatter.format(per_decision_stats, global_stats)

    assert report.decision_ref == "shipping-rates"
    assert report.evaluation_count == 5
    assert report.avg_duration_us == 20_000
    assert report.p95_duration_us == 45_200
    assert report.min_duration_us == 8_100
    assert report.max_duration_us == 45_200
    assert report.error_rate == 0.0
    assert report.top_rules == [{"Rule_1", 3}, {"Rule_3", 2}]
    assert report.coverage_percent == 25.0
  end

  test "empty aggregator entry returns zeroed stats without crashing" do
    per_decision_stats = %{decision_ref: "shipping-rates", count: 0}

    global_stats = %{
      total_evaluations: 0,
      total_errors: 0,
      first_seen: nil,
      last_seen: nil
    }

    report = StatsFormatter.format(per_decision_stats, global_stats)

    assert report.evaluation_count == 0
    assert report.avg_duration_us == 0
    assert report.p95_duration_us == 0
    assert report.throughput_per_minute == 0.0
    assert report.top_rules == []
    assert report.coverage_percent == 0.0
  end

  test "throughput calculation accounts for time window" do
    per_decision_stats = %{
      decision_ref: "shipping-rates",
      count: 12,
      total_duration_us: 240_000,
      min_duration_us: 10_000,
      max_duration_us: 30_000,
      durations: Enum.map(1..12, fn index -> index * 2_000 end),
      rule_hits: %{"Rule_1" => 12},
      errors: 0,
      total_rule_count: 8
    }

    global_stats = %{
      total_evaluations: 12,
      total_errors: 0,
      first_seen: ~U[2026-05-20T10:00:00Z],
      last_seen: ~U[2026-05-20T10:01:00Z]
    }

    report = StatsFormatter.format(per_decision_stats, global_stats)

    assert_in_delta report.throughput_per_minute, 12.0, 0.01
  end

  test "coverage_percent uses total_rule_count when provided" do
    per_decision_stats = %{
      decision_ref: "shipping-rates",
      count: 147,
      total_duration_us: 2_940_000,
      min_duration_us: 8_100,
      max_duration_us: 45_200,
      durations: [8_100, 20_000, 45_200],
      rule_hits: %{
        "Rule_1" => 42,
        "Rule_2" => 31,
        "Rule_3" => 28,
        "Rule_4" => 20,
        "Rule_5" => 15,
        "Rule_6" => 8,
        "Rule_7" => 3
      },
      errors: 0,
      total_rule_count: 8
    }

    global_stats = %{
      total_evaluations: 147,
      total_errors: 0,
      first_seen: ~U[2026-05-20T09:00:00Z],
      last_seen: ~U[2026-05-20T10:00:00Z]
    }

    report = StatsFormatter.format(per_decision_stats, global_stats)

    assert_in_delta report.coverage_percent, 87.5, 0.01
  end

  test "error_rate reflects per-decision errors" do
    per_decision_stats = %{
      decision_ref: "shipping-rates",
      count: 10,
      total_duration_us: 200_000,
      min_duration_us: 10_000,
      max_duration_us: 30_000,
      durations: Enum.map(1..10, fn _index -> 20_000 end),
      rule_hits: %{},
      errors: 2,
      total_rule_count: 8
    }

    global_stats = %{
      total_evaluations: 10,
      total_errors: 2,
      first_seen: ~U[2026-05-20T10:00:00Z],
      last_seen: ~U[2026-05-20T10:10:00Z]
    }

    report = StatsFormatter.format(per_decision_stats, global_stats)

    assert_in_delta report.error_rate, 0.2, 0.001
  end
end
