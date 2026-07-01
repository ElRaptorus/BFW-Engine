defmodule Examples.BusinessRules.KpiCalculator.KpiAggregatorTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.KpiCalculator.KpiAggregator

  setup do
    aggregator_name = :"kpi_aggregator_test_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = KpiAggregator.start_link(name: aggregator_name)
    {:ok, aggregator_name: aggregator_name}
  end

  test "first record initializes per-decision entry", %{aggregator_name: aggregator_name} do
    occurred_at = ~U[2026-05-20T10:00:00Z]

    :ok =
      KpiAggregator.record(
        %{
          decision_ref: "shipping-rates",
          duration_us: 12_000,
          hit_policy: "FIRST",
          matched_rules: ["Rule_express_domestic_light"],
          process_instance_id: "process-instance-1",
          occurred_at: occurred_at,
          total_rule_count: 8
        },
        name: aggregator_name
      )

    Process.sleep(10)

    stats = KpiAggregator.get_stats(name: aggregator_name)
    per_decision = stats.per_decision["shipping-rates"]

    assert per_decision.count == 1
    assert per_decision.total_duration_us == 12_000
    assert per_decision.min_duration_us == 12_000
    assert per_decision.max_duration_us == 12_000
    assert per_decision.durations == [12_000]
    assert per_decision.rule_hits == %{"Rule_express_domestic_light" => 1}
    assert per_decision.errors == 0
    assert per_decision.total_rule_count == 8

    assert stats.global.total_evaluations == 1
    assert stats.global.total_errors == 0
    assert stats.global.first_seen == occurred_at
    assert stats.global.last_seen == occurred_at
  end

  test "subsequent records update running totals", %{aggregator_name: aggregator_name} do
    :ok =
      KpiAggregator.record(
        %{
          decision_ref: "shipping-rates",
          duration_us: 10_000,
          matched_rules: ["Rule_1"],
          occurred_at: ~U[2026-05-20T10:00:00Z]
        },
        name: aggregator_name
      )

    :ok =
      KpiAggregator.record(
        %{
          decision_ref: "shipping-rates",
          duration_us: 30_000,
          matched_rules: ["Rule_2", "Rule_2"],
          occurred_at: ~U[2026-05-20T10:01:00Z]
        },
        name: aggregator_name
      )

    Process.sleep(10)

    per_decision = KpiAggregator.get_stats(name: aggregator_name).per_decision["shipping-rates"]

    assert per_decision.count == 2
    assert per_decision.total_duration_us == 40_000
    assert per_decision.min_duration_us == 10_000
    assert per_decision.max_duration_us == 30_000
    assert per_decision.durations == [10_000, 30_000]
    assert per_decision.rule_hits == %{"Rule_1" => 1, "Rule_2" => 2}
  end

  test "get_stats/0 returns correct aggregated state", %{aggregator_name: aggregator_name} do
    :ok =
      KpiAggregator.record(
        %{
          decision_ref: "shipping-rates",
          duration_us: 8_000,
          matched_rule_count: 1,
          occurred_at: ~U[2026-05-20T10:00:00Z]
        },
        name: aggregator_name
      )

    :ok =
      KpiAggregator.record(
        %{
          decision_ref: "other-decision",
          duration_us: 50_000,
          terminal_state: :fatal,
          occurred_at: ~U[2026-05-20T10:05:00Z]
        },
        name: aggregator_name
      )

    Process.sleep(10)

    stats = KpiAggregator.get_stats(name: aggregator_name)

    assert stats.per_decision["shipping-rates"].count == 1
    assert stats.per_decision["other-decision"].errors == 1
    assert stats.global.total_evaluations == 2
    assert stats.global.total_errors == 1
  end

  test "reset/0 clears all stats", %{aggregator_name: aggregator_name} do
    :ok =
      KpiAggregator.record(
        %{decision_ref: "shipping-rates", duration_us: 1_000, occurred_at: DateTime.utc_now()},
        name: aggregator_name
      )

    Process.sleep(10)
    :ok = KpiAggregator.reset(name: aggregator_name)

    stats = KpiAggregator.get_stats(name: aggregator_name)

    assert stats.per_decision == %{}
    assert stats.global.total_evaluations == 0
    assert stats.global.total_errors == 0
    assert stats.global.first_seen == nil
    assert stats.global.last_seen == nil
  end
end
