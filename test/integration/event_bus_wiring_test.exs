defmodule BfwEngine.Integration.EventBusWiringTest do
  @moduledoc "Full-stack: event bus → sink pipeline, crash isolation."
  use BfwEngine.IntegrationCase, async: false

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Types.Event.{EngineStarted, SinkFailed}

  defp engine_started(version \\ "0.1.0") do
    %EngineStarted{
      engine_id: "test-engine",
      version: version,
      started_at: DateTime.utc_now()
    }
  end

  describe "sink dispatch" do
    test "registered sink receives published events" do
      :ok =
        EngineEventBus.register_sink(
          "test:observer",
          BfwEngine.Test.IntegrationSink,
          test_pid: self()
        )

      EngineEventBus.publish(engine_started())

      assert_receive {:integration_sink, %EngineStarted{version: "0.1.0"}}, 500
    end

    test "crash in one sink does not block another" do
      :ok =
        EngineEventBus.register_sink(
          "test:crasher",
          BfwEngine.Test.IntegrationCrashSink,
          []
        )

      :ok =
        EngineEventBus.register_sink(
          "test:observer",
          BfwEngine.Test.IntegrationSink,
          test_pid: self()
        )

      EngineEventBus.publish(engine_started())

      assert_receive {:integration_sink, %EngineStarted{version: "0.1.0"}}, 500
      assert_receive {:integration_sink, %SinkFailed{}}, 500
    end

    test "multiple publish calls result in multiple deliveries" do
      :ok =
        EngineEventBus.register_sink(
          "test:observer",
          BfwEngine.Test.IntegrationSink,
          test_pid: self()
        )

      EngineEventBus.publish(engine_started("1"))
      EngineEventBus.publish(engine_started("2"))
      EngineEventBus.publish(engine_started("3"))

      assert_receive {:integration_sink, %EngineStarted{version: "1"}}, 500
      assert_receive {:integration_sink, %EngineStarted{version: "2"}}, 500
      assert_receive {:integration_sink, %EngineStarted{version: "3"}}, 500
    end
  end
end
