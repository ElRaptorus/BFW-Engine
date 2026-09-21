defmodule Examples.EventSinks.WebhookForwarder.WebhookSinkTest do
  use ExUnit.Case

  alias BfwEngine.Types.Event
  alias Examples.EventSinks.WebhookForwarder.WebhookSink

  @webhook_url "https://hooks.example.test/engine"

  setup do
    on_exit(fn -> Process.delete(:examples_webhook_forwarder_sink_filter_types) end)
    :ok
  end

  test "accepts? with no filter_types accepts every event" do
    {:ok, _state} = WebhookSink.init(url: @webhook_url, filter_types: nil)

    assert WebhookSink.accepts?(%Event.EngineStarted{
             engine_id: "engine-1",
             engine_name: "local",
             version: "1.0.0",
             started_at: ~U[2026-05-14T12:00:00Z]
           })
  end

  test "accepts? with empty filter_types list accepts every event" do
    {:ok, _state} = WebhookSink.init(url: @webhook_url, filter_types: [])

    assert WebhookSink.accepts?(%Event.PluginQuarantined{
             plugin_name: "broken_plugin",
             tier: :inbeam,
             reason: :load_error,
             occurred_at: ~U[2026-05-14T12:00:00Z]
           })
  end

  test "accepts? with filter_types only accepts listed struct modules" do
    allowed = [Event.EngineStarted, Event.EngineShutdown]

    {:ok, _state} = WebhookSink.init(url: @webhook_url, filter_types: allowed)

    assert WebhookSink.accepts?(%Event.EngineStarted{
             engine_id: "engine-1",
             engine_name: "local",
             version: "1.0.0",
             started_at: ~U[2026-05-14T12:00:00Z]
           })

    refute WebhookSink.accepts?(%Event.UserTaskFinished{
             flow_node_instance_id: "flow-node-instance-1",
             process_instance_id: "process-instance-1",
             flow_node_id: "Task_1",
             outcome: :completed,
             occurred_at: ~U[2026-05-14T12:00:00Z]
           })
  end

  test "handle_event POST payload uses type field and engine event fields" do
    test_process = self()

    deliver_payload = fn url, headers, json_body ->
      send(test_process, {:webhook, url, headers, json_body})
      :ok
    end

    {:ok, state} =
      WebhookSink.init(
        url: @webhook_url,
        headers: [{"content-type", "application/json"}],
        deliver_payload: deliver_payload
      )

    event = %Event.EngineStarted{
      engine_id: "engine-1",
      engine_name: "local",
      version: "1.0.0",
      started_at: ~U[2026-05-14T12:00:00Z]
    }

    assert {:ok, ^state} = WebhookSink.handle_event(event, state)

    assert_receive {:webhook, received_url, received_headers, json_body}
    assert received_url == @webhook_url
    assert received_headers == [{"content-type", "application/json"}]

    decoded = Jason.decode!(json_body)
    assert decoded["type"] == "BfwEngine.Types.Event.EngineStarted"
    assert decoded["engine_id"] == "engine-1"
    assert decoded["engine_name"] == "local"
    assert decoded["version"] == "1.0.0"
    assert decoded["started_at"] == "2026-05-14T12:00:00Z"
  end
end
