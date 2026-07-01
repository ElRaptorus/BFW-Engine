defmodule EvilEngine.Events.EngineEventBusTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Types.Event

  setup do
    EngineEventBus.reset_state()
    :ok
  end

  defp make_event do
    %Event.EngineStarted{
      engine_id: "test-engine",
      engine_name: "test",
      version: "0.0.1",
      started_at: DateTime.utc_now()
    }
  end

  describe "register_sink/3" do
    test "registers a sink and lists it" do
      assert :ok =
               EngineEventBus.register_sink("test-sink", EvilEngine.Test.TestSink,
                 test_pid: self()
               )

      sinks = EngineEventBus.list_sinks()
      assert length(sinks) == 1
      assert hd(sinks).name == "test-sink"
      assert hd(sinks).module == EvilEngine.Test.TestSink
    end

    test "returns error when sink init fails" do
      defmodule FailingSinkInit do
        @behaviour EvilEngine.Plugin.EventSink
        def init(_opts), do: {:error, :bad_config}
        def accepts?(_), do: true
        def handle_event(_, s), do: {:ok, s}
        def handle_shutdown(_), do: :ok
      end

      assert {:error, :bad_config} = EngineEventBus.register_sink("fail", FailingSinkInit, [])
      assert EngineEventBus.list_sinks() == []
    end

    test "returns :already_registered when name is registered twice" do
      assert :ok =
               EngineEventBus.register_sink("dup-name", EvilEngine.Test.TestSink,
                 test_pid: self()
               )

      assert {:error, :already_registered} =
               EngineEventBus.register_sink("dup-name", EvilEngine.Test.TestSink,
                 test_pid: self()
               )

      # First registration is preserved
      sinks = EngineEventBus.list_sinks()
      assert length(sinks) == 1
    end
  end

  describe "publish/1" do
    test "returns :ok when no sinks are registered" do
      assert EngineEventBus.list_sinks() == []
      assert :ok = EngineEventBus.publish(make_event())
      refute_receive {:sink_received, _}, 100
    end

    test "dispatches event to registered sink" do
      :ok =
        EngineEventBus.register_sink("dispatch-test", EvilEngine.Test.TestSink, test_pid: self())

      event = make_event()
      assert :ok = EngineEventBus.publish(event)

      assert_receive {:sink_received, %Event.EngineStarted{engine_id: "test-engine"}}, 1_000
    end

    test "dispatches to multiple sinks" do
      :ok = EngineEventBus.register_sink("multi-a", EvilEngine.Test.TestSink, test_pid: self())
      :ok = EngineEventBus.register_sink("multi-b", EvilEngine.Test.TestSink, test_pid: self())

      event = make_event()
      EngineEventBus.publish(event)

      assert_receive {:sink_received, %Event.EngineStarted{engine_id: "test-engine"}}, 1_000
      assert_receive {:sink_received, %Event.EngineStarted{engine_id: "test-engine"}}, 1_000
    end

    test "selective sink only receives accepted events" do
      :ok =
        EngineEventBus.register_sink("selective", EvilEngine.Test.SelectiveSink, test_pid: self())

      EngineEventBus.publish(make_event())
      assert_receive {:selective_received, %Event.EngineStarted{engine_id: "test-engine"}}, 1_000

      shutdown_event = %Event.EngineShutdown{
        engine_id: "test",
        reason: :normal,
        occurred_at: DateTime.utc_now()
      }

      EngineEventBus.publish(shutdown_event)
      refute_receive {:selective_received, _}, 200
    end
  end

  describe "publish/1 with :skip return" do
    test "sink returning :skip preserves its previous state" do
      :ok =
        EngineEventBus.register_sink("skipper", EvilEngine.Test.SkippingSink, test_pid: self())

      event = make_event()
      assert :ok = EngineEventBus.publish(event)
      assert_receive {:skipping_sink_called, ^event, 1}, 1_000

      event2 = make_event()
      assert :ok = EngineEventBus.publish(event2)
      assert_receive {:skipping_sink_called, ^event2, call_count}, 1_000

      # call_count should still be 1 because :skip preserves the original state
      assert call_count == 1
    end
  end

  describe "shutdown_sinks/0" do
    test "calls handle_shutdown on registered sinks" do
      :ok =
        EngineEventBus.register_sink("shutdown-test", EvilEngine.Test.TestSink, test_pid: self())

      EngineEventBus.publish(make_event())
      assert_receive {:sink_received, _}, 1_000

      assert :ok = EngineEventBus.shutdown_sinks()
      assert_receive {:sink_shutdown, count}, 1_000
      assert count == 1
    end
  end

  describe "shutdown_sinks/0 with crashing sink" do
    test "handles sink shutdown crash gracefully" do
      defmodule CrashingShutdownSink do
        @behaviour EvilEngine.Plugin.EventSink
        def init(_opts), do: {:ok, %{}}
        def accepts?(_), do: true
        def handle_event(_, s), do: {:ok, s}
        def handle_shutdown(_), do: raise("boom on shutdown")
      end

      :ok = EngineEventBus.register_sink("crash-shutdown", CrashingShutdownSink, [])
      assert :ok = EngineEventBus.shutdown_sinks()
    end

    test "handles dead worker gracefully" do
      :ok = EngineEventBus.register_sink("to-kill", EvilEngine.Test.TestSink, test_pid: self())

      [{worker_pid, _}] = Registry.lookup(EvilEngine.Events.SinkRegistry, "to-kill")
      Process.exit(worker_pid, :kill)

      # Wait briefly for the registry entry to be cleared by the supervisor
      # restart cycle. Either way, shutdown_sinks/0 must not raise on a dead
      # worker — it catches :exit from GenServer.call.
      Process.sleep(50)

      assert :ok = EngineEventBus.shutdown_sinks()
    end
  end

  describe "reset_state/0" do
    test "unregistering via reset_state stops further delivery" do
      :ok =
        EngineEventBus.register_sink("unsub-test", EvilEngine.Test.TestSink, test_pid: self())

      assert :ok = EngineEventBus.publish(make_event())
      assert_receive {:sink_received, %Event.EngineStarted{}}, 1_000

      assert :ok = EngineEventBus.reset_state()

      assert :ok = EngineEventBus.publish(make_event())
      refute_receive {:sink_received, _}, 200
    end

    test "clears all registered sinks" do
      :ok = EngineEventBus.register_sink("to-reset", EvilEngine.Test.TestSink, test_pid: self())
      assert length(EngineEventBus.list_sinks()) == 1

      assert :ok = EngineEventBus.reset_state()
      assert EngineEventBus.list_sinks() == []
    end

    test "tolerates already-dead worker during reset" do
      :ok =
        EngineEventBus.register_sink("dead-on-reset", EvilEngine.Test.TestSink, test_pid: self())

      [{worker_pid, _}] = Registry.lookup(EvilEngine.Events.SinkRegistry, "dead-on-reset")
      DynamicSupervisor.terminate_child(EvilEngine.Events.SinkSupervisor, worker_pid)
      Process.sleep(20)

      # Registry entry was cleared by the supervisor; reset_state must still work.
      assert :ok = EngineEventBus.reset_state()
      assert EngineEventBus.list_sinks() == []
    end
  end

  describe "crash isolation" do
    test "crashing sink does not kill the bus" do
      :ok = EngineEventBus.register_sink("crasher", EvilEngine.Test.CrashingSink, [])
      :ok = EngineEventBus.register_sink("survivor", EvilEngine.Test.TestSink, test_pid: self())

      EngineEventBus.publish(make_event())

      assert_receive {:sink_received, %Event.EngineStarted{}}, 1_000
      assert Process.alive?(GenServer.whereis(EngineEventBus))
    end

    test "crashing sink emits SinkFailed event to surviving sinks" do
      :ok = EngineEventBus.register_sink("crasher2", EvilEngine.Test.CrashingSink, [])
      :ok = EngineEventBus.register_sink("observer", EvilEngine.Test.TestSink, test_pid: self())

      EngineEventBus.publish(make_event())

      assert_receive {:sink_received, %Event.EngineStarted{}}, 1_000

      assert_receive {:sink_received,
                      %Event.SinkFailed{
                        sink_name: "crasher2",
                        event_kind: Event.EngineStarted,
                        reason: reason
                      }},
                     1_000

      assert is_binary(reason) and reason != ""
    end
  end

  describe "PF-3: per-sink worker isolation" do
    defmodule SlowSink do
      @moduledoc false
      @behaviour EvilEngine.Plugin.EventSink

      @impl true
      def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

      @impl true
      def accepts?(_event), do: true

      @impl true
      def handle_event(event, state) do
        Process.sleep(200)
        send(state.test_pid, {:slow_sink_received, event})
        {:ok, state}
      end

      @impl true
      def handle_shutdown(_state), do: :ok
    end

    defmodule CountingSink do
      @moduledoc false
      @behaviour EvilEngine.Plugin.EventSink

      @impl true
      def init(opts) do
        {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), count: 0}}
      end

      @impl true
      def accepts?(_event), do: true

      @impl true
      def handle_event(_event, state) do
        new_state = %{state | count: state.count + 1}
        send(state.test_pid, {:counting_sink_count, new_state.count})
        {:ok, new_state}
      end

      @impl true
      def handle_shutdown(state) do
        send(state.test_pid, {:counting_sink_final, state.count})
        :ok
      end
    end

    test "a slow sink does not block other sinks" do
      :ok = EngineEventBus.register_sink("slow", SlowSink, test_pid: self())
      :ok = EngineEventBus.register_sink("fast", EvilEngine.Test.TestSink, test_pid: self())

      Enum.each(1..5, fn _ -> EngineEventBus.publish(make_event()) end)

      # The fast sink should receive all 5 events well before the slow sink finishes
      # one (200ms each → 1000ms minimum for slow sink to complete all 5).
      started_at = System.monotonic_time(:millisecond)

      Enum.each(1..5, fn _ ->
        assert_receive {:sink_received, %Event.EngineStarted{}}, 200
      end)

      elapsed = System.monotonic_time(:millisecond) - started_at

      # Generous bound: fast sink processes 5 events while slow sink is still busy
      # with its first. Should be well under 200ms (the slow sink's per-event delay).
      assert elapsed < 200,
             "Fast sink was blocked by slow sink (took #{elapsed}ms; expected < 200ms)"
    end

    test "events to a single sink are processed in arrival order" do
      :ok = EngineEventBus.register_sink("counter", CountingSink, test_pid: self())

      Enum.each(1..50, fn _ -> EngineEventBus.publish(make_event()) end)

      Enum.each(1..50, fn expected_count ->
        assert_receive {:counting_sink_count, ^expected_count}, 1_000
      end)
    end

    test "supervisor restarts a worker after the worker process is killed" do
      :ok =
        EngineEventBus.register_sink("restartable", EvilEngine.Test.TestSink, test_pid: self())

      [{first_pid, _}] = Registry.lookup(EvilEngine.Events.SinkRegistry, "restartable")
      ref = Process.monitor(first_pid)

      # Sink-handler exceptions are caught by the worker (see "crash isolation"
      # describe block above); the worker survives. To exercise the supervision
      # wiring itself, kill the worker process directly.
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, :killed}, 1_000

      # Wait for the supervisor to restart the worker. Polling because restart
      # is asynchronous.
      restarted_pid = poll_for_new_pid("restartable", first_pid, 500)
      assert restarted_pid != nil
      assert restarted_pid != first_pid
      assert Process.alive?(restarted_pid)
    end

    defp poll_for_new_pid(name, old_pid, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_poll_for_new_pid(name, old_pid, deadline)
    end

    defp do_poll_for_new_pid(name, old_pid, deadline) do
      case Registry.lookup(EvilEngine.Events.SinkRegistry, name) do
        [{pid, _}] when pid != old_pid ->
          pid

        _ ->
          if System.monotonic_time(:millisecond) >= deadline do
            nil
          else
            Process.sleep(10)
            do_poll_for_new_pid(name, old_pid, deadline)
          end
      end
    end
  end
end
