defmodule Examples.BusinessRules.DecisionAnalytics.ReportSchedulerTest do
  use ExUnit.Case, async: false

  alias Examples.BusinessRules.DecisionAnalytics.AnalyticsCollector
  alias Examples.BusinessRules.DecisionAnalytics.ReportScheduler

  test "emit_report/1 returns JSON-encodable totals from the collector" do
    collector_name = :"analytics_report_scheduler_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = AnalyticsCollector.start_link(name: collector_name)

    :ok =
      AnalyticsCollector.record(
        %{decision_ref: "shipping-rates", duration_us: 200, matched_rules: ["Rule_1"]},
        name: collector_name
      )

    {:ok, scheduler_pid} =
      ReportScheduler.start_link(interval_ms: 0, collector_name: collector_name)

    report = ReportScheduler.emit_report(scheduler_pid)

    assert report.totals.total_evaluations == 1
    assert hd(report.decisions).decision_ref == "shipping-rates"
    assert hd(report.decisions).avg_latency_us == 200
    assert is_binary(Jason.encode!(report))

    GenServer.stop(scheduler_pid)
    Agent.stop(collector_name)
  end
end
