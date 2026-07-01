defmodule EvilEngine.Telemetry.StatsCollectorTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Telemetry.StatsCollector

  describe "info/0" do
    test "returns engine identity fields" do
      result = StatsCollector.info()

      assert is_binary(result.engine_id)
      assert is_binary(result.engine_name)
      assert is_binary(result.version)
      assert %DateTime{} = result.started_at
      refute Map.has_key?(result, :auth_disabled)
      refute Map.has_key?(result, :event_sink_database)
      refute Map.has_key?(result, :uptime_seconds)
    end
  end

  describe "snapshot/0" do
    test "returns all expected top-level keys" do
      result = StatsCollector.snapshot()

      expected_keys =
        ~w(engine process_instances flow_node_instances user_tasks_pending
           async_flow_nodes timers plugins listeners)a

      for key <- expected_keys do
        assert Map.has_key?(result, key), "missing top-level key: #{inspect(key)}"
      end
    end

    test "engine section contains identity and load level" do
      %{engine: engine} = StatsCollector.snapshot()

      assert is_binary(engine.id)
      assert is_binary(engine.name)
      assert is_binary(engine.version)
      assert engine.load in ["normal", "elevated", "critical"]
    end

    test "listeners section has sink info" do
      %{listeners: listeners} = StatsCollector.snapshot()

      assert is_integer(listeners.event_sinks_count)
      assert is_map(listeners.event_sinks_by_name)
    end

    test "returns default-off sinks when no sinks are registered" do
      EngineEventBus.reset_state()

      try do
        %{listeners: listeners} = StatsCollector.snapshot()

        assert listeners.event_sinks_count == 0

        assert listeners.event_sinks_by_name == %{
                 "console" => "off",
                 "telemetry" => "off",
                 "websocket" => "off"
               }

        assert listeners.monitoring_panels_count == 0
      after
        :ok
      end
    end

    test "S-3: process_instances section has all state keys" do
      %{process_instances: pi_stats} = StatsCollector.snapshot()

      for key <- ~w(running finished fatal aborted)a do
        assert Map.has_key?(pi_stats, key),
               "missing process_instances key: #{inspect(key)}"

        assert is_integer(Map.get(pi_stats, key))
      end
    end

    test "S-4: registered event sinks appear as on in listeners" do
      sinks = EngineEventBus.list_sinks()

      if sinks != [] do
        %{listeners: listeners} = StatsCollector.snapshot()

        assert listeners.event_sinks_count == Enum.count(sinks)

        for sink <- sinks do
          assert listeners.event_sinks_by_name[sink.name] == "on",
                 "Expected sink #{sink.name} to be 'on'"
        end
      end
    end
  end
end
