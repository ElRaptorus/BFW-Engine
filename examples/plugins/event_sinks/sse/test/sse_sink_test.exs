defmodule Examples.EventSinks.Sse.SseSinkTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Types.Event
  alias Examples.EventSinks.Sse.{ConnectionHub, SseSink}

  setup do
    ConnectionHub.ensure_started()
    ConnectionHub.unsubscribe(self())
    :ok
  end

  test "handle_event broadcasts a JSON object frame body to subscribers" do
    ConnectionHub.subscribe(self())
    {:ok, state} = SseSink.init([])

    event = %Event.EngineStarted{
      engine_id: "engine-1",
      engine_name: "local",
      version: "1.0.0",
      started_at: ~U[2026-05-14T12:00:00Z]
    }

    assert {:ok, ^state} = SseSink.handle_event(event, state)
    assert_receive {:sse_event, json_body, "info"}, 1_000

    decoded = Jason.decode!(json_body)
    assert decoded["engineId"] == "engine-1"
    assert is_binary(ConnectionHub.frame(json_body))
    assert String.starts_with?(ConnectionHub.frame(json_body), "data: ")
    assert String.ends_with?(ConnectionHub.frame(json_body), "\n\n")
  end

  test "PluginQuarantined is broadcast with error severity" do
    ConnectionHub.subscribe(self())
    {:ok, state} = SseSink.init([])

    event = %Event.PluginQuarantined{
      plugin_name: "cookbook-quarantine_demo",
      tier: :inbeam,
      reason: "intentional_quarantine",
      occurred_at: ~U[2026-05-14T12:00:00Z]
    }

    assert {:ok, ^state} = SseSink.handle_event(event, state)
    assert_receive {:sse_event, _json_body, "error"}, 1_000
  end
end
