defmodule BfwEngine.Telemetry.MetricsTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Telemetry.Metrics

  describe "metrics/0" do
    test "returns a non-empty list of metric definitions" do
      metrics = Metrics.metrics()
      assert is_list(metrics)
      assert match?([_ | _], metrics)
      assert Enum.all?(metrics, &match?(%{__struct__: _}, &1))
    end

    test "contains exactly 27 metric definitions" do
      assert length(Metrics.metrics()) == 27
    end

    test "includes all expected metric names" do
      names = Enum.map(Metrics.metrics(), & &1.name)

      expected = [
        [:bfw_engine, :http, :request, :total],
        [:bfw_engine, :http, :request, :duration_ms],
        [:bfw_engine, :process_instance, :state_change, :total],
        [:bfw_engine, :process_instance, :active, :count],
        [:bfw_engine, :flow_node_instance, :started, :total],
        [:bfw_engine, :flow_node_instance, :state_change, :total],
        [:bfw_engine, :event_bus, :events, :total],
        [:bfw_engine, :process_instance, :capacity, :ratio],
        [:bfw_engine, :dmn, :evaluations, :total],
        [:bfw_engine, :dmn, :evaluate, :duration, :milliseconds],
        [:bfw_engine, :dmn, :evaluations, :exceptions, :total],
        [:bfw_engine, :dmn, :cache, :hit, :total],
        [:bfw_engine, :dmn, :cache, :miss, :total],
        [:bfw_engine, :db, :query, :queue_time_ms],
        [:bfw_engine, :db, :query, :total_time_ms],
        [:bfw_engine, :db, :query, :count],
        [:bfw_engine, :db, :pool, :size],
        [:bfw_engine, :db, :pool, :checked_out],
        [:bfw_engine, :db, :pool, :idle],
        [:vm, :memory, :total],
        [:vm, :memory, :processes],
        [:vm, :total_run_queue_lengths, :total],
        [:vm, :total_run_queue_lengths, :cpu],
        [:vm, :total_run_queue_lengths, :io],
        [:vm, :system_counts, :process_count],
        [:bfw_engine, :escalation, :raised, :total],
        [:bfw_engine, :escalation, :uncaught, :total]
      ]

      for name <- expected do
        assert name in names, "Missing metric: #{inspect(name)}"
      end
    end

    test "HTTP request counter has method/route/status tags" do
      http_counter =
        Metrics.metrics()
        |> Enum.find(&(&1.name == [:bfw_engine, :http, :request, :total]))

      assert http_counter.tags == [:method, :route, :status]
    end

    test "FNI state_change counter has flow_node_type/terminal_state tags" do
      fni_counter =
        Metrics.metrics()
        |> Enum.find(&(&1.name == [:bfw_engine, :flow_node_instance, :state_change, :total]))

      assert fni_counter.tags == [:flow_node_type, :terminal_state]
    end

    test "event bus counter has event_type tag" do
      bus_counter =
        Metrics.metrics()
        |> Enum.find(&(&1.name == [:bfw_engine, :event_bus, :events, :total]))

      assert bus_counter.tags == [:event_type]
    end

    test "DMN evaluations counter has hit_policy tag" do
      dmn_counter =
        Metrics.metrics()
        |> Enum.find(&(&1.name == [:bfw_engine, :dmn, :evaluations, :total]))

      assert dmn_counter != nil
      assert dmn_counter.tags == [:hit_policy]
    end

    test "DMN evaluate duration is a distribution with millisecond buckets" do
      dmn_duration =
        Metrics.metrics()
        |> Enum.find(&(&1.name == [:bfw_engine, :dmn, :evaluate, :duration, :milliseconds]))

      assert %Telemetry.Metrics.Distribution{} = dmn_duration
      assert dmn_duration.reporter_options[:buckets] == [1, 5, 10, 25, 50, 100, 250, 500, 1000]
    end

    test "HTTP duration is a distribution with millisecond buckets" do
      duration =
        Metrics.metrics()
        |> Enum.find(&(&1.name == [:bfw_engine, :http, :request, :duration_ms]))

      assert %Telemetry.Metrics.Distribution{} = duration
      assert duration.reporter_options[:buckets] == [5, 10, 25, 50, 100, 250, 500, 1000, 5000]
    end
  end
end
