defmodule Examples.EventSinks.DatadogMetrics.DatadogSinkTest do
  use ExUnit.Case

  alias BfwEngine.Types.Event
  alias Examples.EventSinks.DatadogMetrics.DatadogSink

  @api_key "test-api-key"

  defp sample_process_instance_state_changed do
    %Event.ProcessInstanceStateChanged{
      process_instance_id: "process-instance-1",
      process_model_id: "order",
      version: "1.0.0",
      parent_process_instance_id: nil,
      old_state: :running,
      new_state: :completed,
      occurred_at: ~U[2026-05-14T12:00:00Z]
    }
  end

  test "accepts? returns true for process instance and flow node events" do
    assert DatadogSink.accepts?(sample_process_instance_state_changed())

    assert DatadogSink.accepts?(%Event.FlowNodeInstanceStarted{
             flow_node_instance_id: "flow-node-instance-1",
             process_instance_id: "process-instance-1",
             flow_node_id: "Task_1",
             flow_node_type: :user_task,
             event_type: nil,
             occurred_at: ~U[2026-05-14T12:00:01Z]
           })

    assert DatadogSink.accepts?(%Event.FlowNodeInstanceFinished{
             flow_node_instance_id: "flow-node-instance-1",
             process_instance_id: "process-instance-1",
             flow_node_id: "Task_1",
             flow_node_type: :user_task,
             event_type: nil,
             terminal_state: :completed,
             occurred_at: ~U[2026-05-14T12:00:02Z]
           })

    assert DatadogSink.accepts?(%Event.EngineOverloaded{
             level: :elevated,
             active_process_instances: 900,
             limit: 1000,
             occurred_at: ~U[2026-05-14T12:00:03Z]
           })
  end

  test "accepts? returns false for EngineStarted" do
    refute DatadogSink.accepts?(%Event.EngineStarted{
             engine_id: "engine-1",
             engine_name: "local",
             version: "1.0.0",
             started_at: ~U[2026-05-14T12:00:00Z]
           })
  end

  test "handle_event accumulates metric entries until batch_size triggers flush" do
    test_process = self()

    on_flush = fn api_key, buffer ->
      send(test_process, {:flushed, api_key, buffer})
    end

    {:ok, initial_state} =
      DatadogSink.init(api_key: @api_key, batch_size: 3, on_flush: on_flush)

    event_one = sample_process_instance_state_changed()

    event_two = %Event.FlowNodeInstanceStarted{
      flow_node_instance_id: "flow-node-instance-2",
      process_instance_id: "process-instance-2",
      flow_node_id: "Task_2",
      flow_node_type: :service_task,
      event_type: nil,
      occurred_at: ~U[2026-05-14T12:01:00Z]
    }

    assert {:ok, after_one} = DatadogSink.handle_event(event_one, initial_state)
    assert length(after_one.buffer) == 1
    refute_receive {:flushed, _, _}

    assert {:ok, after_two} = DatadogSink.handle_event(event_two, after_one)
    assert length(after_two.buffer) == 2
    refute_receive {:flushed, _, _}

    event_three = %Event.EngineOverloaded{
      level: :critical,
      active_process_instances: 1200,
      limit: 1000,
      occurred_at: ~U[2026-05-14T12:02:00Z]
    }

    assert {:ok, after_three} = DatadogSink.handle_event(event_three, after_two)
    assert after_three.buffer == []

    assert_receive {:flushed, received_api_key, buffer}
    assert received_api_key == @api_key
    assert length(buffer) == 3
    assert Enum.at(buffer, 0).metric == "bfw.process_instance.state_changed"
    assert Enum.at(buffer, 1).metric == "bfw.flow_node.started"
    assert Enum.at(buffer, 2).metric == "bfw.engine.overload"
  end
end
