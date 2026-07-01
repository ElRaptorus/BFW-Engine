defmodule Examples.BusinessRules.DecisionTracePublisher.SinkTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.DecisionTracePublisher.Sink

  setup do
    parent = self()

    deliver_function = fn audit_message ->
      send(parent, {:delivered, audit_message})
      :ok
    end

    {:ok, sink_state} = Sink.init(deliver_fn: deliver_function)
    {:ok, sink_state: sink_state}
  end

  defp dmn_brt_finished_event(overrides \\ %{}) do
    type_properties =
      Map.get(overrides, :type_properties) ||
        %{
          "mode" => "dmn",
          "decision_ref" => "order-risk-rules",
          "decision_version_id" => "version-uuid-1",
          "hit_policy" => "UNIQUE",
          "matched_rules" => ["Rule_medium_risk"],
          "duration_us" => 18_500,
          "trace" => %{"decisions" => [%{"decisionModelId" => "Decision_Risk_Level"}]}
        }

    struct_fields =
      %{
        flow_node_instance_id: "flow-node-instance-1",
        process_instance_id: "process-instance-1",
        flow_node_id: "BRT_assess_order_risk",
        flow_node_type: :business_rule_task,
        event_type: nil,
        terminal_state: :finished,
        occurred_at: ~U[2026-05-20T12:00:00Z]
      }
      |> Map.merge(Map.drop(overrides, [:type_properties]))

    struct(Event.FlowNodeInstanceFinished, struct_fields)
    |> Map.put(:type_properties, type_properties)
  end

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

  test "handle_event/2 calls deliver_fn with correct audit message shape", %{sink_state: sink_state} do
    event = dmn_brt_finished_event()

    assert {:ok, ^sink_state} = Sink.handle_event(event, sink_state)

    assert_receive {:delivered, audit_message}

    assert audit_message.event_type == "dmn_decision_executed"
    assert %DateTime{} = audit_message.timestamp
    assert audit_message.process_instance_id == "process-instance-1"
    assert audit_message.flow_node_id == "BRT_assess_order_risk"
    assert audit_message.decision_ref == "order-risk-rules"
    assert audit_message.decision_version_id == "version-uuid-1"
    assert audit_message.hit_policy == "UNIQUE"
    assert audit_message.matched_rules == ["Rule_medium_risk"]
    assert audit_message.duration_us == 18_500
    assert audit_message.trace == %{"decisions" => [%{"decisionModelId" => "Decision_Risk_Level"}]}
  end
end
