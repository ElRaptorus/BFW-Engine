defmodule EvilEngine.Test.IntegrationSink do
  @moduledoc false
  @behaviour EvilEngine.Plugin.EventSink

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    {:ok, %{test_pid: test_pid}}
  end

  @impl true
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    send(state.test_pid, {:integration_sink, event})
    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok
end

defmodule EvilEngine.Test.IntegrationCrashSink do
  @moduledoc false
  @behaviour EvilEngine.Plugin.EventSink

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def accepts?(%EvilEngine.Types.Event.SinkFailed{}), do: false
  def accepts?(_event), do: true

  @impl true
  def handle_event(_event, _state), do: raise("deliberate integration crash")

  @impl true
  def handle_shutdown(_state), do: :ok
end

defmodule EvilEngine.Test.FakePlugin do
  @moduledoc false
  @behaviour EvilEngine.Plugin

  @impl true
  def on_load(_facade), do: :ok

  @impl true
  def on_ready(_facade), do: :ok
end
