defmodule EvilEngine.Integration.DMN.DmnPrometheusMetricsTest do
  @moduledoc """
  Integration test verifying that DMN evaluation produces Prometheus
  metrics visible on GET /metrics (7H.4).
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  describe "Prometheus DMN metrics" do
    test "DMN evaluation increments counters and records duration" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {200, _} = http_evaluate_decision("definitions_discount", %{"age" => 25})
      {200, _} = http_evaluate_decision("definitions_discount", %{"age" => 70})

      metrics = scrape_metrics()

      assert metrics =~ "evil_engine_dmn_evaluations_total",
             "Expected evil_engine_dmn_evaluations_total in metrics output"

      assert metrics =~ "evil_engine_dmn_evaluate_duration_milliseconds",
             "Expected evil_engine_dmn_evaluate_duration_milliseconds in metrics output"

      assert metrics =~ "evil_engine_dmn_cache_hit_total",
             "Expected evil_engine_dmn_cache_hit_total in metrics output"
    end
  end

  defp scrape_metrics do
    conn =
      Plug.Test.conn(:get, "/metrics")
      |> route()

    assert conn.status == 200
    conn.resp_body
  end
end
