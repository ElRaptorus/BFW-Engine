defmodule BfwEngine.Events.PendingSweeper do
  @moduledoc """
  Periodic GenServer that expires pending messages and pending signals
  past their TTL.

  Ticks at `BFE_PENDING_SWEEPER_INTERVAL` (default 10 000 ms). On
  each tick, transitions all `pending_messages` and `pending_signals`
  rows with `state='pending' AND expires_at <= now()` to
  `state='expired'`.

  Forward-compatible: Phase 4 escalations will add their pending
  tables to the same tick.
  """

  use GenServer

  require Logger

  alias BfwEngine.Events.MessagePersistence
  alias BfwEngine.Events.SignalPersistence

  @default_interval_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = sweep_interval()
    schedule_tick(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    sweep_expired_messages()
    sweep_expired_signals()
    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp sweep_expired_messages do
    case MessagePersistence.adapter() do
      nil ->
        :ok

      adapter ->
        case adapter.expire_pending_messages() do
          {:ok, 0} ->
            :ok

          {:ok, count} ->
            Logger.info("PendingSweeper: expired #{count} pending message(s)")

          {:error, reason} ->
            Logger.warning("PendingSweeper: sweep failed: #{inspect(reason)}")
        end
    end
  rescue
    exception ->
      Logger.warning("PendingSweeper: sweep failed: #{Exception.message(exception)}")
  end

  defp sweep_expired_signals do
    case SignalPersistence.adapter() do
      nil ->
        :ok

      adapter ->
        case adapter.expire_pending_signals() do
          {:ok, 0} ->
            :ok

          {:ok, count} ->
            Logger.info("PendingSweeper: expired #{count} pending signal(s)")

          {:error, reason} ->
            Logger.warning("PendingSweeper: signal sweep failed: #{inspect(reason)}")
        end
    end
  rescue
    exception ->
      Logger.warning("PendingSweeper: signal sweep failed: #{Exception.message(exception)}")
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp sweep_interval do
    case Application.get_env(:core_events, :pending_sweeper_interval) do
      nil -> @default_interval_ms
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> @default_interval_ms
    end
  end
end
