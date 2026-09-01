defmodule Examples.BusinessRules.DecisionAnalytics.LatencyHistogramTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.DecisionAnalytics.LatencyHistogram

  test "returns zeros when empty" do
    histogram = LatencyHistogram.new()

    assert LatencyHistogram.count(histogram) == 0
    assert LatencyHistogram.average(histogram) == 0
    assert LatencyHistogram.p95(histogram) == 0
    assert LatencyHistogram.p99(histogram) == 0
    assert LatencyHistogram.min(histogram) == 0
    assert LatencyHistogram.max(histogram) == 0
  end

  test "uses the single value for average and percentiles" do
    histogram = LatencyHistogram.add(LatencyHistogram.new(), 250)

    assert LatencyHistogram.average(histogram) == 250
    assert LatencyHistogram.p95(histogram) == 250
    assert LatencyHistogram.p99(histogram) == 250
    assert LatencyHistogram.min(histogram) == 250
    assert LatencyHistogram.max(histogram) == 250
  end

  test "computes percentile boundaries for one hundred values" do
    values = Enum.to_list(1..100)
    histogram = LatencyHistogram.add_all(LatencyHistogram.new(), values)

    assert LatencyHistogram.count(histogram) == 100
    assert LatencyHistogram.average(histogram) == 50.5
    assert LatencyHistogram.p95(histogram) == 95
    assert LatencyHistogram.p99(histogram) == 99
    assert LatencyHistogram.min(histogram) == 1
    assert LatencyHistogram.max(histogram) == 100
  end

  test "reports correct min and max" do
    histogram = LatencyHistogram.add_all(LatencyHistogram.new(), [10, 50, 30])

    assert LatencyHistogram.min(histogram) == 10
    assert LatencyHistogram.max(histogram) == 50
  end
end
