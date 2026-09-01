defmodule Examples.BusinessRules.DecisionAnalytics.AnalyticsSinkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.DecisionAnalytics.AnalyticsCollector
  alias Examples.BusinessRules.DecisionAnalytics.AnalyticsSink

  setup do
    collector_name = :"analytics_sink_test_#{:erlang.unique_integer([:positive])}"

    {:ok, sink_state} = AnalyticsSink.init(collector_name: collector_name)

    on_exit(fn ->
      case Process.whereis(collector_name) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid), do: Agent.stop(pid)
      end
    end)

    {:ok, sink_state: sink_state, collector_name: collector_name}
  end

  defp dmn_brt_finished_event(overrides \\ %{}) do
    type_properties =
      Map.get(overrides, :type_properties) ||
        %{
          "mode" => "dmn",
          "decision_ref" => "shipping-rates",
          "duration_us" => 18_500,
          "matched_rules" => ["Rule_express_domestic_light"]
        }

    struct_fields =
      %{
        flow_node_instance_id: "flow-node-instance-1",
        process_instance_id: "process-instance-1",
        flow_node_id: "BRT_calculate_shipping",
        flow_node_type: :business_rule_task,
        event_type: nil,
        terminal_state: :finished,
        occurred_at: ~U[2026-05-20T12:00:00Z]
      }
      |> Map.merge(Map.drop(overrides, [:type_properties]))

    struct(Event.FlowNodeInstanceFinished, struct_fields)
    |> Map.put(:type_properties, type_properties)
  end

  test "accepts?/1 returns true for BRT DMN finished events" do
    assert AnalyticsSink.accepts?(dmn_brt_finished_event())
  end

  test "accepts?/1 returns false for non-BRT events" do
    service_task_event = %Event.FlowNodeInstanceFinished{
      flow_node_instance_id: "flow-node-instance-2",
      process_instance_id: "process-instance-1",
      flow_node_id: "Task_http",
      flow_node_type: :service_task,
      event_type: nil,
      terminal_state: :finished,
      occurred_at: ~U[2026-05-20T12:00:00Z]
    }

    refute AnalyticsSink.accepts?(service_task_event)

    refute AnalyticsSink.accepts?(%Event.EngineStarted{
             engine_id: "engine-1",
             engine_name: "test",
             version: "1.0.0",
             started_at: ~U[2026-05-20T12:00:00Z]
           })
  end

  test "accepts?/1 returns false for BRT events with mode != dmn" do
    refute AnalyticsSink.accepts?(
             dmn_brt_finished_event(%{type_properties: %{"mode" => "feel"}})
           )

    refute AnalyticsSink.accepts?(dmn_brt_finished_event(%{type_properties: %{}}))
  end

  test "handle_event/2 records evaluation data into the collector", %{
    sink_state: sink_state,
    collector_name: collector_name
  } do
    assert {:ok, ^sink_state} = AnalyticsSink.handle_event(dmn_brt_finished_event(), sink_state)

    stats = AnalyticsCollector.get_stats_for_decision("shipping-rates", name: collector_name)
    assert stats.evaluation_count == 1
    assert stats.total_duration_us == 18_500
    assert stats.rule_hit_counts["Rule_express_domestic_light"] == 1
  end

  test "handle_event/2 logs a warning on a latency spike", %{
    sink_state: sink_state,
    collector_name: collector_name
  } do
    baseline_event =
      dmn_brt_finished_event(%{
        type_properties: %{
          "mode" => "dmn",
          "decision_ref" => "shipping-rates",
          "duration_us" => 100,
          "matched_rules" => ["Rule_1"]
        }
      })

    Enum.each(1..5, fn _index ->
      AnalyticsSink.handle_event(baseline_event, sink_state)
    end)

    spike_event =
      dmn_brt_finished_event(%{
        type_properties: %{
          "mode" => "dmn",
          "decision_ref" => "shipping-rates",
          "duration_us" => 1000,
          "matched_rules" => ["Rule_1"]
        }
      })

    log =
      capture_log(fn ->
        AnalyticsSink.handle_event(spike_event, sink_state)
      end)

    assert log =~ "decision_analytics: latency spike"
    assert log =~ "shipping-rates"

    stats = AnalyticsCollector.get_stats_for_decision("shipping-rates", name: collector_name)
    assert stats.evaluation_count == 6
  end
end
