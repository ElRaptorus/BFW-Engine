defmodule EvilEngine.Events.PendingSweeperTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Events.PendingSweeper

  @original_message_adapter Application.compile_env(
                              :core_events,
                              :message_persistence_adapter
                            )

  @original_signal_adapter Application.compile_env(:core_events, :signal_persistence_adapter)

  @original_interval Application.compile_env(:core_events, :pending_sweeper_interval)

  setup do
    on_exit(fn ->
      stop_pending_sweeper()
      restore_adapter_config()
    end)

    stop_pending_sweeper()
    :ok
  end

  describe "lifecycle" do
    test "starts and schedules periodic sweeps against configured adapters" do
      configure_mock_adapters(self(), message_expire_result: {:ok, 0})

      Application.put_env(:core_events, :pending_sweeper_interval, 30)

      assert {:ok, pid} = PendingSweeper.start_link([])
      assert Process.alive?(pid)

      assert_receive {:mock_expire_pending_messages, 0}, 500
      assert_receive {:mock_expire_pending_signals, 0}, 500
    end

    test "stops cleanly when terminated" do
      configure_mock_adapters(self())
      Application.put_env(:core_events, :pending_sweeper_interval, 50)

      {:ok, pid} = PendingSweeper.start_link([])
      ref = Process.monitor(pid)
      assert :ok = GenServer.stop(pid, :normal, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end

  describe "sweep interval configuration" do
    test "uses TDE_PENDING_SWEEPER_INTERVAL from application env" do
      configure_mock_adapters(self())
      Application.put_env(:core_events, :pending_sweeper_interval, 40)

      {:ok, _pid} = PendingSweeper.start_link([])

      first_tick_at = System.monotonic_time(:millisecond)
      assert_receive {:mock_expire_pending_messages, _}, 200
      first_elapsed = System.monotonic_time(:millisecond) - first_tick_at

      second_tick_at = System.monotonic_time(:millisecond)
      assert_receive {:mock_expire_pending_messages, _}, 200
      second_elapsed = System.monotonic_time(:millisecond) - second_tick_at

      assert first_elapsed >= 30
      assert second_elapsed >= 30
    end

    test "falls back to default interval when config is nil" do
      Application.put_env(:core_events, :pending_sweeper_interval, nil)
      configure_mock_adapters(self())

      assert {:ok, _pid} = PendingSweeper.start_link([])
    end
  end

  describe "edge cases" do
    test "nil adapter is a no-op — sweeper does not crash" do
      Application.put_env(:core_events, :message_persistence_adapter, nil)
      Application.put_env(:core_events, :signal_persistence_adapter, nil)
      Application.put_env(:core_events, :pending_sweeper_interval, 20)

      {:ok, pid} = PendingSweeper.start_link([])
      Process.sleep(60)
      assert Process.alive?(pid)
    end

    test "adapter returning {:ok, 0} for empty pending tables is tolerated" do
      configure_mock_adapters(self(),
        message_expire_result: {:ok, 0},
        signal_expire_result: {:ok, 0}
      )

      Application.put_env(:core_events, :pending_sweeper_interval, 25)

      {:ok, pid} = PendingSweeper.start_link([])

      assert_receive {:mock_expire_pending_messages, 0}, 300
      assert_receive {:mock_expire_pending_signals, 0}, 300
      assert Process.alive?(pid)
    end

    test "adapter expiring rows reports count without crashing the sweeper" do
      configure_mock_adapters(self(),
        message_expire_result: {:ok, 2},
        signal_expire_result: {:ok, 1}
      )

      Application.put_env(:core_events, :pending_sweeper_interval, 25)

      {:ok, pid} = PendingSweeper.start_link([])

      assert_receive {:mock_expire_pending_messages, 2}, 300
      assert_receive {:mock_expire_pending_signals, 1}, 300
      assert Process.alive?(pid)
    end

    test "adapter error is swallowed — sweeper stays alive" do
      configure_mock_adapters(self(),
        message_expire_result: {:error, :db_down},
        signal_expire_result: {:ok, 0}
      )

      Application.put_env(:core_events, :pending_sweeper_interval, 25)

      {:ok, pid} = PendingSweeper.start_link([])

      assert_receive {:mock_expire_pending_messages, :error}, 300
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  defp configure_mock_adapters(test_pid, opts \\ []) do
    Application.put_env(:core_events, :pending_sweeper_test_pid, test_pid)

    Application.put_env(
      :core_events,
      :pending_sweeper_message_expire_result,
      Keyword.get(opts, :message_expire_result, {:ok, 0})
    )

    Application.put_env(
      :core_events,
      :pending_sweeper_signal_expire_result,
      Keyword.get(opts, :signal_expire_result, {:ok, 0})
    )

    Application.put_env(
      :core_events,
      :message_persistence_adapter,
      EvilEngine.Events.PendingSweeperTest.MockMessagePersistenceAdapter
    )

    Application.put_env(
      :core_events,
      :signal_persistence_adapter,
      EvilEngine.Events.PendingSweeperTest.MockSignalPersistenceAdapter
    )
  end

  defp stop_pending_sweeper do
    case Process.whereis(PendingSweeper) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp restore_adapter_config do
    Application.put_env(:core_events, :message_persistence_adapter, @original_message_adapter)
    Application.put_env(:core_events, :signal_persistence_adapter, @original_signal_adapter)
    Application.put_env(:core_events, :pending_sweeper_interval, @original_interval)
    Application.delete_env(:core_events, :pending_sweeper_test_pid)
    Application.delete_env(:core_events, :pending_sweeper_message_expire_result)
    Application.delete_env(:core_events, :pending_sweeper_signal_expire_result)
  end

  defmodule MockMessagePersistenceAdapter do
    @moduledoc false
    @behaviour EvilEngine.Events.MessagePersistence

    @impl true
    def insert_message(_params), do: {:ok, "message-id"}

    @impl true
    def insert_pending_message(_params), do: {:ok, "pending-id"}

    @impl true
    def find_pending_messages(_message_name, _correlation_value), do: {:ok, []}

    @impl true
    def mark_pending_delivered(_pending_message_id), do: :ok

    @impl true
    def cancel_pending_for_message(_message_name, _correlation_value), do: {:ok, 0}

    @impl true
    def expire_pending_messages do
      test_pid = Application.get_env(:core_events, :pending_sweeper_test_pid)
      result = Application.get_env(:core_events, :pending_sweeper_message_expire_result, {:ok, 0})

      case result do
        {:ok, count} ->
          send(test_pid, {:mock_expire_pending_messages, count})
          {:ok, count}

        {:error, _reason} = error ->
          send(test_pid, {:mock_expire_pending_messages, :error})
          error
      end
    end

    @impl true
    def append_message_correlation(_message_id, _entry), do: :ok

    @impl true
    def update_started_process_instance_ids(_message_id, _started_ids), do: :ok
  end

  defmodule MockSignalPersistenceAdapter do
    @moduledoc false
    @behaviour EvilEngine.Events.SignalPersistence

    @impl true
    def insert_signal(_params), do: {:ok, "signal-id"}

    @impl true
    def insert_pending_signal(_params), do: {:ok, "pending-id"}

    @impl true
    def find_pending_signals(_signal_name), do: {:ok, []}

    @impl true
    def mark_pending_delivered(_pending_signal_id), do: :ok

    @impl true
    def cancel_pending_for_signal_name(_signal_name), do: {:ok, 0}

    @impl true
    def expire_pending_signals do
      test_pid = Application.get_env(:core_events, :pending_sweeper_test_pid)
      result = Application.get_env(:core_events, :pending_sweeper_signal_expire_result, {:ok, 0})

      case result do
        {:ok, count} ->
          send(test_pid, {:mock_expire_pending_signals, count})
          {:ok, count}

        {:error, _reason} = error ->
          send(test_pid, {:mock_expire_pending_signals, :error})
          error
      end
    end

    @impl true
    def append_signal_delivery(_signal_id, _entry), do: :ok

    @impl true
    def update_started_process_instance_ids(_signal_id, _started_ids), do: :ok
  end
end
