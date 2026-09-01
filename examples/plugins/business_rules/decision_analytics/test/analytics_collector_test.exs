defmodule Examples.BusinessRules.DecisionAnalytics.AnalyticsCollectorTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.DecisionAnalytics.AnalyticsCollector
  alias Examples.BusinessRules.DecisionAnalytics.LatencyHistogram
  alias Examples.BusinessRules.DecisionAnalytics.ReportFormatter

  setup do
    collector_name = :"analytics_collector_test_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = AnalyticsCollector.start_link(name: collector_name)
    {:ok, collector_name: collector_name}
  end

  test "records event and updates per-decision stats", %{collector_name: collector_name} do
    :ok =
      AnalyticsCollector.record(
        %{decision_ref: "shipping-rates", duration_us: 500, matched_rules: ["Rule_express_domestic_light"]},
        name: collector_name
      )

    :ok =
      AnalyticsCollector.record(
        %{decision_ref: "shipping-rates", duration_us: 700, matched_rules: ["Rule_express_domestic_light"]},
        name: collector_name
      )

    stats = AnalyticsCollector.get_stats_for_decision("shipping-rates", name: collector_name)

    assert stats.evaluation_count == 2
    assert stats.total_duration_us == 1200
    assert stats.latencies == [500, 700]
  end

  test "computes correct average from latency array via report formatting", %{
    collector_name: collector_name
  } do
    :ok = AnalyticsCollector.record(%{duration_us: 100, matched_rules: []}, name: collector_name)
    :ok = AnalyticsCollector.record(%{duration_us: 300, matched_rules: []}, name: collector_name)

    report = ReportFormatter.format(AnalyticsCollector.get_stats(name: collector_name))
    decision = hd(report.decisions)
    assert decision.avg_latency_us == 200

    histogram =
      LatencyHistogram.new()
      |> LatencyHistogram.add_all(
        AnalyticsCollector.get_stats_for_decision("unknown", name: collector_name).latencies
      )

    assert round(LatencyHistogram.average(histogram)) == 200
  end

  test "tracks per-rule hit distribution", %{collector_name: collector_name} do
    :ok =
      AnalyticsCollector.record(
        %{matched_rules: ["Rule_express_domestic_light"]},
        name: collector_name
      )

    :ok =
      AnalyticsCollector.record(
        %{matched_rules: ["Rule_express_domestic_light"]},
        name: collector_name
      )

    :ok =
      AnalyticsCollector.record(
        %{matched_rules: ["Rule_economy_domestic_light"]},
        name: collector_name
      )

    stats = AnalyticsCollector.get_stats_for_decision("unknown", name: collector_name)
    assert stats.rule_hit_counts["Rule_express_domestic_light"] == 2
    assert stats.rule_hit_counts["Rule_economy_domestic_light"] == 1

    report = ReportFormatter.format(AnalyticsCollector.get_stats(name: collector_name))
    assert hd(report.decisions).top_rules == [
             ["Rule_express_domestic_light", 2],
             ["Rule_economy_domestic_light", 1]
           ]
  end

  test "reset clears all stats", %{collector_name: collector_name} do
    :ok = AnalyticsCollector.record(%{duration_us: 1}, name: collector_name)
    :ok = AnalyticsCollector.reset(name: collector_name)
    assert AnalyticsCollector.get_stats(name: collector_name) == %{}
  end

  test "defaults unknown decision ref when decision_ref is missing", %{
    collector_name: collector_name
  } do
    :ok = AnalyticsCollector.record(%{duration_us: 42}, name: collector_name)
    stats = AnalyticsCollector.get_stats_for_decision("unknown", name: collector_name)

    assert stats.decision_ref == "unknown"
    assert stats.evaluation_count == 1
  end

  test "normalizes matched rule maps with rule_id", %{collector_name: collector_name} do
    :ok =
      AnalyticsCollector.record(
        %{matched_rules: [%{"rule_id" => "Rule_1"}, %{rule_id: "Rule_2"}]},
        name: collector_name
      )

    stats = AnalyticsCollector.get_stats_for_decision("unknown", name: collector_name)
    assert stats.rule_hit_counts["Rule_1"] == 1
    assert stats.rule_hit_counts["Rule_2"] == 1
  end
end
