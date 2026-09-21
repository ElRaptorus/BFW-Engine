defmodule BfwEngine.Test.SkippingSink do
  @moduledoc false
  @behaviour BfwEngine.Plugin.EventSink

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    {:ok, %{test_pid: test_pid, call_count: 0}}
  end

  @impl true
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    send(state.test_pid, {:skipping_sink_called, event, state.call_count + 1})
    :skip
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end
