defmodule EvilEngine.Test.TestSink do
  @moduledoc false
  @behaviour EvilEngine.Plugin.EventSink

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    {:ok, %{test_pid: test_pid, events: []}}
  end

  @impl true
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    send(state.test_pid, {:sink_received, event})
    {:ok, %{state | events: state.events ++ [event]}}
  end

  @impl true
  def handle_shutdown(state) do
    send(state.test_pid, {:sink_shutdown, length(state.events)})
    :ok
  end
end
