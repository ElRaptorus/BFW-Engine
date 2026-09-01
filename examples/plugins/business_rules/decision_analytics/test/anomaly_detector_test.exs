defmodule Examples.BusinessRules.DecisionAnalytics.AnomalyDetectorTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.DecisionAnalytics.AnomalyDetector

  test "does not flag normal latency" do
    detector = AnomalyDetector.new(window_size: 20, spike_threshold: 3)
    latencies = List.duplicate(100, 10)
    result = AnomalyDetector.detect(detector, "shipping-rates", latencies, 110)

    refute result.is_anomaly
    assert result.spike_factor == 1.1
    assert result.decision_ref == "shipping-rates"
  end

  test "flags a tenfold spike with correct spike factor" do
    detector = AnomalyDetector.new(window_size: 20, spike_threshold: 3)
    latencies = List.duplicate(100, 10)
    result = AnomalyDetector.detect(detector, "shipping-rates", latencies, 1000)

    assert result.is_anomaly
    assert result.spike_factor == 10.0
    assert result.rolling_average == 100
    assert result.current_latency == 1000
  end

  test "does not flag when history is empty" do
    detector = AnomalyDetector.new()
    result = AnomalyDetector.detect(detector, "shipping-rates", [], 5000)

    refute result.is_anomaly
    assert result.spike_factor == 0.0
    assert result.rolling_average == 0
  end

  test "flags at the spike threshold boundary" do
    detector = AnomalyDetector.new(window_size: 20, spike_threshold: 3)
    result = AnomalyDetector.detect(detector, "shipping-rates", [100, 100, 100], 300)

    assert result.is_anomaly
    assert result.spike_factor == 3.0
  end

  test "does not flag just below the spike threshold" do
    detector = AnomalyDetector.new(window_size: 20, spike_threshold: 3)
    result = AnomalyDetector.detect(detector, "shipping-rates", [100, 100, 100], 299)

    refute result.is_anomaly
    assert result.spike_factor == 2.99
  end
end
