defmodule Examples.BusinessRules.KpiCalculator.SinkTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.KpiCalculator.{KpiAggregator, Sink}

  setup do
    aggregator_name = :"kpi_sink_test_#{:erlang.unique_integer([:positive])}"

    {:ok, sink_state} = Sink.init(aggregator_name: aggregator_name)

    on_exit(fn ->
      case Process.whereis(aggregator_name) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid), do: Agent.stop(pid)
      end
    end)

    {:ok, sink_state: sink_state, aggregator_name: aggregator_name}
  end

  defp dmn_brt_finished_event(overrides \\ %{}) do
    overrides = normalize_overrides(overrides)

    type_properties =
      Map.get(overrides, :type_properties) ||
        Map.get(overrides, "type_properties") ||
        %{
          "mode" => "dmn",
          "decision_ref" => "shipping-rates",
          "duration_us" => 18_500,
          "hit_policy" => "FIRST",
          "matched_rules" => ["Rule_express_domestic_light", "Rule_express_domestic_heavy"],
          "total_rule_count" => 8
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
      |> Map.merge(Map.drop(overrides, [:type_properties, "type_properties"]))

    struct(Event.FlowNodeInstanceFinished, struct_fields)
    |> Map.put(:type_properties, type_properties)
  end

  defp normalize_overrides(overrides) when is_map(overrides), do: overrides

  defp normalize_overrides(overrides) when is_list(overrides), do: Enum.into(overrides, %{})

  test "accepts?/1 returns true for BRT DMN fni.finished events" do
    event = dmn_brt_finished_event()
    assert Sink.accepts?(event)
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

    refute Sink.accepts?(service_task_event)

    refute Sink.accepts?(%Event.EngineStarted{
             engine_id: "engine-1",
             engine_name: "test",
             version: "1.0.0",
             started_at: ~U[2026-05-20T12:00:00Z]
           })
  end

  test "accepts?/1 returns false for BRT events with mode != dmn" do
    feel_event =
      dmn_brt_finished_event(%{
        type_properties: %{"mode" => "feel", "decision_ref" => "unused"}
      })

    refute Sink.accepts?(feel_event)

    missing_mode_event = dmn_brt_finished_event(%{type_properties: %{}})
    refute Sink.accepts?(missing_mode_event)
  end

  test "handle_event/2 calls KpiAggregator.record/1 with correct data shape", %{
    sink_state: sink_state,
    aggregator_name: aggregator_name
  } do
    event = dmn_brt_finished_event()

    assert {:ok, ^sink_state} = Sink.handle_event(event, sink_state)
    Process.sleep(10)

    stats = KpiAggregator.get_stats(name: aggregator_name)
    per_decision = stats.per_decision["shipping-rates"]

    assert per_decision.count == 1
    assert per_decision.total_duration_us == 18_500
    assert per_decision.rule_hits["Rule_express_domestic_light"] == 1
    assert per_decision.rule_hits["Rule_express_domestic_heavy"] == 1
    assert per_decision.total_rule_count == 8
    assert stats.global.total_evaluations == 1
  end

  test "handle_event/2 supports atom-keyed type_properties for forward compatibility", %{
    sink_state: sink_state,
    aggregator_name: aggregator_name
  } do
    event =
      dmn_brt_finished_event(%{
        type_properties: %{
          mode: "dmn",
          decision_ref: "shipping-rates",
          duration_us: 9_000,
          matched_rules: ["Rule_domestic_economy"]
        }
      })

    assert {:ok, _} = Sink.handle_event(event, sink_state)
    Process.sleep(10)

    per_decision = KpiAggregator.get_stats(name: aggregator_name).per_decision["shipping-rates"]
    assert per_decision.total_duration_us == 9_000
    assert per_decision.rule_hits["Rule_domestic_economy"] == 1
  end
end
