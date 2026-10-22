defmodule BfwEngine.Test.CrashingSink do
  @moduledoc false
  @behaviour BfwEngine.Plugin.EventSink
  @dialyzer {:nowarn_function, handle_event: 2}

  @impl true
  def init(opts) do
    test_pid = Keyword.get(opts, :test_pid)
    {:ok, %{test_pid: test_pid}}
  end

  @impl true
  def accepts?(_event), do: true

  @impl true
  def handle_event(_event, _state) do
    raise "deliberate crash for testing"
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end
