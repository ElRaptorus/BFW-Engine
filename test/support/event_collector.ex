defmodule EvilEngine.Test.EventCollector do
  @moduledoc """
  Collects EngineEventBus events in order for test assertions.

  Registers a dedicated `EventSink` on start and stores all received
  events in a GenServer. Provides helpers for waiting on event
  sequences.
  """

  use GenServer

  alias EvilEngine.Events.EngineEventBus

  # -- Client API ----------------------------------------------------------

  def start_link(test_pid) do
    {:ok, pid} = GenServer.start_link(__MODULE__, test_pid)

    EngineEventBus.register_sink(
      "test:event_collector_#{inspect(pid)}",
      EvilEngine.Test.EventCollector.Sink,
      collector_pid: pid
    )

    {:ok, pid}
  end

  @doc "Return all collected events in order."
  def get_events(collector_pid) do
    GenServer.call(collector_pid, :get_events)
  end

  @doc """
  Wait for the collector to accumulate at least `count` events,
  then return them all. Times out after `timeout_ms`.
  """
  def await_events(collector_pid, count, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_events(collector_pid, count, deadline)
  end

  defp do_await_events(collector_pid, count, deadline) do
    events = get_events(collector_pid)

    cond do
      length(events) >= count ->
        events

      System.monotonic_time(:millisecond) >= deadline ->
        events

      true ->
        Process.sleep(25)
        do_await_events(collector_pid, count, deadline)
    end
  end

  # -- GenServer callbacks -------------------------------------------------

  @impl true
  def init(_test_pid) do
    {:ok, %{events: []}}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    {:noreply, %{state | events: state.events ++ [event]}}
  end

  @impl true
  def handle_call(:get_events, _from, state) do
    {:reply, state.events, state}
  end
end

defmodule EvilEngine.Test.EventCollector.Sink do
  @moduledoc false
  @behaviour EvilEngine.Plugin.EventSink

  @impl true
  def init(opts) do
    collector_pid = Keyword.fetch!(opts, :collector_pid)
    {:ok, %{collector_pid: collector_pid}}
  end

  @impl true
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    GenServer.cast(state.collector_pid, {:event, event})
    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end
