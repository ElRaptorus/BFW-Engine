defmodule EvilEngine.Test.SelectiveSink do
  @moduledoc false
  @behaviour EvilEngine.Plugin.EventSink

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    {:ok, %{test_pid: test_pid}}
  end

  @impl true
  def accepts?(%EvilEngine.Types.Event.EngineStarted{}), do: true
  def accepts?(_event), do: false

  @impl true
  def handle_event(event, state) do
    send(state.test_pid, {:selective_received, event})
    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end
