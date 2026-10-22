defmodule BfwEngine.Events.Sinks.ConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BfwEngine.Events.Sinks.Console
  alias BfwEngine.Types.Event

  describe "init/1" do
    test "defaults to :info severity" do
      assert {:ok, %{min_severity: :info}} = Console.init([])
    end

    test "accepts custom min_severity" do
      assert {:ok, %{min_severity: :debug}} = Console.init(min_severity: "debug")
    end
  end

  describe "accepts?/1" do
    test "rejects SinkFailed events" do
      event = %Event.SinkFailed{
        sink_name: "x",
        event_kind: Event.EngineStarted,
        reason: "boom",
        occurred_at: DateTime.utc_now()
      }

      refute Console.accepts?(event)
    end

    test "accepts EngineStarted" do
      event = %Event.EngineStarted{engine_id: "e", started_at: DateTime.utc_now()}
      assert Console.accepts?(event)
    end

    test "accepts EngineShutdown" do
      event = %Event.EngineShutdown{
        engine_id: "e",
        reason: :normal,
        occurred_at: DateTime.utc_now()
      }

      assert Console.accepts?(event)
    end
  end

  describe "handle_event/2" do
    setup do
      prev_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev_level) end)
      :ok
    end

    test "logs EngineStarted at info level" do
      {:ok, state} = Console.init([])

      event = %Event.EngineStarted{
        engine_id: "e-1",
        engine_name: "test",
        version: "0.1.0",
        started_at: DateTime.utc_now()
      }

      log =
        capture_log([level: :info], fn ->
          assert {:ok, ^state} = Console.handle_event(event, state)
        end)

      assert log =~ "EngineStarted"
      assert log =~ "e-1"
      assert log =~ "[info]"
    end

    test "logs EngineShutdown at warning level" do
      {:ok, state} = Console.init([])

      event = %Event.EngineShutdown{
        engine_id: "e-1",
        reason: :normal,
        occurred_at: DateTime.utc_now()
      }

      log =
        capture_log([level: :warning], fn ->
          Console.handle_event(event, state)
        end)

      assert log =~ "EngineShutdown"
      assert log =~ "[warning]"
    end

    test "does not log EngineStarted at warning level only" do
      {:ok, state} = Console.init([])

      event = %Event.EngineStarted{
        engine_id: "e-1",
        engine_name: "test",
        version: "0.1.0",
        started_at: DateTime.utc_now()
      }

      log =
        capture_log(fn ->
          Console.handle_event(event, state)
        end)

      refute log =~ "[warning]"
      refute log =~ "[error]"
    end

    test "filters events below min_severity" do
      {:ok, state} = Console.init(min_severity: "error")

      event = %Event.EngineStarted{engine_id: "e", started_at: DateTime.utc_now()}

      log =
        capture_log(fn ->
          assert {:ok, ^state} = Console.handle_event(event, state)
        end)

      assert log == ""
    end
  end

  describe "handle_event/2 with severity edge cases" do
    setup do
      prev_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev_level) end)
      :ok
    end

    test "logs EngineShutdown at warning level when min_severity is warn" do
      {:ok, state} = Console.init(min_severity: "warn")

      event = %Event.EngineShutdown{
        engine_id: "e-1",
        reason: :test,
        occurred_at: DateTime.utc_now()
      }

      log =
        capture_log(fn ->
          assert {:ok, ^state} = Console.handle_event(event, state)
        end)

      assert log =~ "EngineShutdown"
      assert log =~ "[warning]"
    end

    test "filters when min_severity is above event level" do
      {:ok, state} = Console.init(min_severity: "warn")

      event = %Event.EngineStarted{engine_id: "e", started_at: DateTime.utc_now()}

      log =
        capture_log(fn ->
          assert {:ok, ^state} = Console.handle_event(event, state)
        end)

      assert log == ""
    end
  end

  describe "handle_shutdown/1" do
    test "returns :ok" do
      {:ok, state} = Console.init([])
      assert :ok = Console.handle_shutdown(state)
    end
  end
end
