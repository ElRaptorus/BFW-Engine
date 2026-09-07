defmodule EvilEngine.Telemetry.SinkTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Telemetry.Sink
  alias EvilEngine.Types.Event

  describe "init/1" do
    test "returns ok with empty state" do
      assert {:ok, %{}} = Sink.init([])
    end
  end

  describe "accepts?/1" do
    test "accepts all event types" do
      assert Sink.accepts?(%Event.EngineStarted{engine_id: "e", started_at: DateTime.utc_now()})

      assert Sink.accepts?(%Event.SinkFailed{
               sink_name: "x",
               event_kind: Event.EngineStarted,
               reason: "boom",
               occurred_at: DateTime.utc_now()
             })
    end
  end

  describe "handle_event/2" do
    test "emits telemetry event with event_type metadata and returns {:ok, state}" do
      {:ok, state} = Sink.init([])

      ref = :telemetry_test.attach_event_handlers(self(), [[:evil_engine, :event_bus]])

      event = %Event.EngineStarted{
        engine_id: "test",
        engine_name: "test",
        version: "0.1.0",
        started_at: DateTime.utc_now()
      }

      assert {:ok, ^state} = Sink.handle_event(event, state)

      assert_receive {[:evil_engine, :event_bus], ^ref, %{count: 1},
                      %{event_type: :engine_started, event: ^event}}
    end

    test "maps EngineOverloaded to event_type :engine_overloaded" do
      {:ok, state} = Sink.init([])

      ref = :telemetry_test.attach_event_handlers(self(), [[:evil_engine, :event_bus]])

      event = %Event.EngineOverloaded{
        level: :critical,
        active_process_instances: 95,
        limit: 100,
        occurred_at: DateTime.utc_now()
      }

      assert {:ok, ^state} = Sink.handle_event(event, state)

      assert_receive {[:evil_engine, :event_bus], ^ref, %{count: 1},
                      %{event_type: :engine_overloaded, event: ^event}}
    end

    test "maps EngineRecovered to event_type :engine_recovered" do
      {:ok, state} = Sink.init([])

      ref = :telemetry_test.attach_event_handlers(self(), [[:evil_engine, :event_bus]])

      event = %Event.EngineRecovered{
        previous_level: :elevated,
        active_process_instances: 60,
        limit: 100,
        occurred_at: DateTime.utc_now()
      }

      assert {:ok, ^state} = Sink.handle_event(event, state)

      assert_receive {[:evil_engine, :event_bus], ^ref, %{count: 1},
                      %{event_type: :engine_recovered, event: ^event}}
    end
  end

  describe "handle_shutdown/1" do
    test "returns :ok" do
      assert :ok = Sink.handle_shutdown(%{})
    end
  end
end
