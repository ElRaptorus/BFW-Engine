defmodule EvilEngine.Telemetry.MeasurementsTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Telemetry.Measurements
  alias EvilEngine.Types.Event

  @dummy_children_key :measurements_dummy_children

  setup do
    cleanup_all_dummy_children()
    :persistent_term.put(:evil_engine_load_level, :normal)
    :ok
  end

  defmodule EventCapturingSink do
    @moduledoc false
    @behaviour EvilEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def accepts?(_event), do: true

    @impl true
    def handle_event(event, %{test_pid: test_pid} = state) do
      send(test_pid, {:overload_event, event})
      {:ok, state}
    end

    @impl true
    def handle_shutdown(_state), do: :ok
  end

  describe "active_process_instances/0" do
    test "emits telemetry event with active PI count" do
      handler_id = "test-active-pis-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:evil_engine, :process_instance, :active],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:active_process_instances, measurements.count})
        end,
        nil
      )

      Measurements.active_process_instances()

      assert_receive {:active_process_instances, count} when is_integer(count)

      :telemetry.detach(handler_id)
    end

    test "emits capacity ratio gauge" do
      handler_id = "test-capacity-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:evil_engine, :process_instance, :capacity],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:capacity_ratio, measurements.ratio})
        end,
        nil
      )

      Measurements.active_process_instances()

      assert_receive {:capacity_ratio, ratio} when is_float(ratio)

      :telemetry.detach(handler_id)
    end

    test "emits ratio 0.0 when cap is infinity" do
      handler_id = "test-cap-inf-#{System.unique_integer([:positive])}"
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)
      Application.put_env(:core_execution, :max_concurrent_process_instances, :infinity)
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:evil_engine, :process_instance, :capacity],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:ratio, measurements.ratio})
        end,
        nil
      )

      Measurements.active_process_instances()

      assert_receive {:ratio, ratio}
      assert ratio == 0.0

      :telemetry.detach(handler_id)

      if original do
        Application.put_env(:core_execution, :max_concurrent_process_instances, original)
      else
        Application.delete_env(:core_execution, :max_concurrent_process_instances)
      end
    end

    test "emits finite ratio when cap is set" do
      handler_id = "test-cap-finite-#{System.unique_integer([:positive])}"
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)
      Application.put_env(:core_execution, :max_concurrent_process_instances, 100)
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:evil_engine, :process_instance, :capacity],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:ratio, measurements.ratio})
        end,
        nil
      )

      Measurements.active_process_instances()

      assert_receive {:ratio, ratio} when is_float(ratio) and ratio >= 0.0 and ratio <= 1.0

      :telemetry.detach(handler_id)

      if original do
        Application.put_env(:core_execution, :max_concurrent_process_instances, original)
      else
        Application.delete_env(:core_execution, :max_concurrent_process_instances)
      end
    end
  end

  describe "overload threshold crossing" do
    setup do
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)
      :persistent_term.put(:evil_engine_load_level, :normal)

      on_exit(fn ->
        if original do
          Application.put_env(:core_execution, :max_concurrent_process_instances, original)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end

        :persistent_term.put(:evil_engine_load_level, :normal)
      end)

      :ok
    end

    test "no overload event when cap is infinity" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, :infinity)

      Measurements.active_process_instances()

      assert :persistent_term.get(:evil_engine_load_level, :normal) == :normal
    end

    test "persistent_term stays :normal when active/limit ratio < 0.7" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, 10_000)

      Measurements.active_process_instances()

      assert :persistent_term.get(:evil_engine_load_level, :normal) == :normal
    end

    test "no event published when level remains unchanged" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, 10_000)
      :persistent_term.put(:evil_engine_load_level, :normal)

      handler_id = "test-no-event-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:evil_engine, :event_bus],
        fn _event, _measurements, metadata, _config ->
          if match?(%{event_type: :engine_overloaded}, metadata) do
            send(test_pid, :overload_event)
          end
        end,
        nil
      )

      Measurements.active_process_instances()
      Measurements.active_process_instances()
      Measurements.active_process_instances()

      refute_receive :overload_event, 50

      :telemetry.detach(handler_id)
    end
  end

  describe "level transitions" do
    setup do
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)

      on_exit(fn ->
        if original do
          Application.put_env(:core_execution, :max_concurrent_process_instances, original)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end

        :persistent_term.put(:evil_engine_load_level, :normal)
      end)

      :ok
    end

    test "M-1: transition from elevated to normal updates persistent_term" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, 1000)
      :persistent_term.put(:evil_engine_load_level, :elevated)

      Measurements.active_process_instances()

      assert :persistent_term.get(:evil_engine_load_level) == :normal
    end

    test "M-2: transition from critical to normal updates persistent_term" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, 1000)
      :persistent_term.put(:evil_engine_load_level, :critical)

      Measurements.active_process_instances()

      assert :persistent_term.get(:evil_engine_load_level) == :normal
    end

    test "M-5: recovery from elevated publishes EngineRecovered with previous_level" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, 1000)
      :persistent_term.put(:evil_engine_load_level, :elevated)

      sink_name = "measurements-recovery-#{System.unique_integer([:positive])}"

      assert :ok =
               EngineEventBus.register_sink(sink_name, EventCapturingSink, test_pid: self())

      Measurements.active_process_instances()

      assert_receive {:overload_event, %Event.EngineRecovered{previous_level: :elevated}}, 500
      assert :persistent_term.get(:evil_engine_load_level) == :normal
    end
  end

  describe "upward threshold crossings" do
    setup context do
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)
      {:ok, _} = Application.ensure_all_started(:core_execution)
      {:ok, _} = Application.ensure_all_started(:core_events)
      EngineEventBus.reset_state()
      :persistent_term.put(:evil_engine_load_level, :normal)

      sink_name = "measurements-overload-#{System.unique_integer([:positive])}"

      assert :ok =
               EngineEventBus.register_sink(sink_name, EventCapturingSink, test_pid: self())

      on_exit(fn ->
        cleanup_all_dummy_children()
        EngineEventBus.reset_state()

        if original do
          Application.put_env(:core_execution, :max_concurrent_process_instances, original)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end

        :persistent_term.put(:evil_engine_load_level, :normal)
      end)

      {:ok, context: context}
    end

    test "normal to elevated publishes EngineOverloaded at 70% capacity" do
      spawn_dummy_children(10)
      actual_count = DynamicSupervisor.count_children(EvilEngine.Execution.Supervisor).active
      limit = ceil(actual_count / 0.75)
      Application.put_env(:core_execution, :max_concurrent_process_instances, limit)

      Measurements.active_process_instances()

      assert_receive {:overload_event, %Event.EngineOverloaded{level: :elevated, limit: ^limit}},
                     500

      assert :persistent_term.get(:evil_engine_load_level) == :elevated
    end

    test "elevated to critical publishes EngineOverloaded at 90% capacity" do
      spawn_dummy_children(10)
      actual_count = DynamicSupervisor.count_children(EvilEngine.Execution.Supervisor).active
      limit = ceil(actual_count / 0.95)
      Application.put_env(:core_execution, :max_concurrent_process_instances, limit)
      :persistent_term.put(:evil_engine_load_level, :elevated)

      Measurements.active_process_instances()

      assert_receive {:overload_event, %Event.EngineOverloaded{level: :critical, limit: ^limit}},
                     500

      assert :persistent_term.get(:evil_engine_load_level) == :critical
    end

    test "normal to critical skips elevated when ratio jumps past both thresholds" do
      spawn_dummy_children(10)
      actual_count = DynamicSupervisor.count_children(EvilEngine.Execution.Supervisor).active
      limit = ceil(actual_count / 0.95)
      Application.put_env(:core_execution, :max_concurrent_process_instances, limit)
      :persistent_term.put(:evil_engine_load_level, :normal)

      Measurements.active_process_instances()

      assert_receive {:overload_event, %Event.EngineOverloaded{level: :critical}}, 500
      refute_receive {:overload_event, %Event.EngineOverloaded{level: :elevated}}, 50
      assert :persistent_term.get(:evil_engine_load_level) == :critical
    end
  end

  describe "db_pool_stats/0" do
    test "emits pool telemetry gauges for the write repo" do
      handler_id = "test-db-pool-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:evil_engine, :db, :pool],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:db_pool, measurements, metadata})
        end,
        nil
      )

      Measurements.db_pool_stats()

      assert_receive {:db_pool, measurements, %{repo: :write}}
      assert is_integer(measurements.size)
      assert is_integer(measurements.checked_out)
      assert is_integer(measurements.idle)

      :telemetry.detach(handler_id)
    end

    test "returns :ok when repo pool is unreachable" do
      assert :ok = Measurements.db_pool_stats()
    end
  end

  describe "edge cases" do
    setup do
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)

      on_exit(fn ->
        if original do
          Application.put_env(:core_execution, :max_concurrent_process_instances, original)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end

        :persistent_term.put(:evil_engine_load_level, :normal)
      end)

      :ok
    end

    test "M-3: no-op when limit is zero" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, 0)

      assert :ok = Measurements.active_process_instances()
    end

    test "M-4: no capacity telemetry event for invalid limit" do
      Application.put_env(:core_execution, :max_concurrent_process_instances, -1)

      handler_id = "test-invalid-cap-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:evil_engine, :process_instance, :capacity],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:capacity_ratio, measurements.ratio})
        end,
        nil
      )

      Measurements.active_process_instances()

      refute_receive {:capacity_ratio, _}, 50

      :telemetry.detach(handler_id)
    end
  end

  describe "rescue branch" do
    test "returns :ok when supervisor is unavailable" do
      original = Application.get_env(:core_execution, :max_concurrent_process_instances)
      Application.put_env(:core_execution, :max_concurrent_process_instances, :infinity)

      assert :ok = Measurements.active_process_instances()

      if original do
        Application.put_env(:core_execution, :max_concurrent_process_instances, original)
      else
        Application.delete_env(:core_execution, :max_concurrent_process_instances)
      end
    end
  end

  defp spawn_dummy_children(count) when is_integer(count) and count > 0 do
    start_dummy_execution_children(count)
  end

  defp cleanup_all_dummy_children do
    child_pids = Process.get(@dummy_children_key, [])

    Enum.each(child_pids, fn child_pid ->
      try do
        DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, child_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    Process.put(@dummy_children_key, [])
  end

  defp start_dummy_execution_children(count) when count > 0 do
    child_pids =
      for _index <- 1..count do
        {:ok, child_pid} =
          DynamicSupervisor.start_child(
            EvilEngine.Execution.Supervisor,
            {Agent, fn -> :ok end}
          )

        child_pid
      end

    existing = Process.get(@dummy_children_key, [])
    Process.put(@dummy_children_key, existing ++ child_pids)
    child_pids
  end

  defp start_dummy_execution_children(0), do: []
end
