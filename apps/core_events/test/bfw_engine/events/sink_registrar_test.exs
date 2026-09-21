defmodule BfwEngine.Events.SinkRegistrarTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Events.SinkRegistrar

  setup do
    EngineEventBus.reset_state()
    on_exit(fn -> EngineEventBus.reset_state() end)
    :ok
  end

  describe "register_all/0" do
    test "registers sinks that are enabled and available" do
      prev_console = Application.get_env(:core_events, :console_sink_enabled)
      prev_tele = Application.get_env(:core_events, :telemetry_sink_enabled)
      prev_ws = Application.get_env(:core_events, :websocket_sink_enabled)

      Application.put_env(:core_events, :console_sink_enabled, true)
      Application.put_env(:core_events, :telemetry_sink_enabled, false)
      Application.put_env(:core_events, :websocket_sink_enabled, false)

      on_exit(fn ->
        Application.put_env(:core_events, :console_sink_enabled, prev_console)
        Application.put_env(:core_events, :telemetry_sink_enabled, prev_tele)
        Application.put_env(:core_events, :websocket_sink_enabled, prev_ws)
      end)

      assert :ok = SinkRegistrar.register_all()

      sinks = EngineEventBus.list_sinks()
      sink_names = Enum.map(sinks, & &1.name)
      assert "console" in sink_names
      refute "telemetry" in sink_names
    end

    test "skips sinks whose modules are not available" do
      prev_modules = Application.get_env(:core_events, :sink_modules, %{})
      prev_console = Application.get_env(:core_events, :console_sink_enabled)

      Application.put_env(:core_events, :sink_modules, %{
        "console" => NonExistent.Sink.Module
      })

      Application.put_env(:core_events, :console_sink_enabled, true)

      on_exit(fn ->
        Application.put_env(:core_events, :sink_modules, prev_modules)
        Application.put_env(:core_events, :console_sink_enabled, prev_console)
      end)

      assert :ok = SinkRegistrar.register_all()

      sinks = EngineEventBus.list_sinks()
      sink_names = Enum.map(sinks, & &1.name)
      refute "console" in sink_names
    end

    test "registers nothing when all sinks are disabled" do
      prev_console = Application.get_env(:core_events, :console_sink_enabled)
      prev_tele = Application.get_env(:core_events, :telemetry_sink_enabled)
      prev_ws = Application.get_env(:core_events, :websocket_sink_enabled)

      Application.put_env(:core_events, :console_sink_enabled, false)
      Application.put_env(:core_events, :telemetry_sink_enabled, false)
      Application.put_env(:core_events, :websocket_sink_enabled, false)

      on_exit(fn ->
        Application.put_env(:core_events, :console_sink_enabled, prev_console)
        Application.put_env(:core_events, :telemetry_sink_enabled, prev_tele)
        Application.put_env(:core_events, :websocket_sink_enabled, prev_ws)
      end)

      assert :ok = SinkRegistrar.register_all()

      sinks = EngineEventBus.list_sinks()
      assert sinks == []
    end
  end
end
