defmodule EvilEngine.Events.SinkWorker do
  @moduledoc """
  GenServer wrapping a single registered `EvilEngine.Plugin.EventSink`.

  One worker per registered sink. The bus casts events to the worker; the
  worker invokes `module.handle_event/2` serially in arrival order,
  preserving the documented in-order state-mutation contract.

  Crash isolation is by supervision: a sink that raises crashes only its
  own worker, which is restarted by `EvilEngine.Events.SinkSupervisor`
  (one_for_one). A `%Event.SinkFailed{}` event is emitted before the
  rescue swallows the exception so other sinks can observe the failure.
  """

  use GenServer

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Types.Event

  @doc false
  def start_link({name, module, opts}) do
    GenServer.start_link(__MODULE__, {name, module, opts}, name: via_tuple(name))
  end

  @doc "Cast an event to the named worker."
  def event(name, event) do
    GenServer.cast(via_tuple(name), {:event, event})
  end

  @doc "Synchronously call `handle_shutdown/1` on the named worker, draining its mailbox first."
  def shutdown(name) do
    GenServer.call(via_tuple(name), :shutdown)
  end

  @doc false
  def get_state(name) do
    GenServer.call(via_tuple(name), :get_state)
  end

  defp via_tuple(name), do: {:via, Registry, {EvilEngine.Events.SinkRegistry, name}}

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({name, module, opts}) do
    case module.init(opts) do
      {:ok, sink_state} ->
        {:ok, %{name: name, module: module, sink_state: sink_state}}

      {:error, reason} ->
        {:stop, {:sink_init_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:event, event}, state) do
    if state.module.accepts?(event) do
      dispatch(event, state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:shutdown, _from, state) do
    try do
      state.module.handle_shutdown(state.sink_state)
    rescue
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  defp dispatch(event, state) do
    case state.module.handle_event(event, state.sink_state) do
      {:ok, new_sink_state} -> {:noreply, %{state | sink_state: new_sink_state}}
      :skip -> {:noreply, state}
    end
  rescue
    exception ->
      emit_sink_failed(state.name, event, exception)
      {:noreply, state}
  end

  defp emit_sink_failed(sink_name, original_event, exception) do
    EngineEventBus.publish(%Event.SinkFailed{
      sink_name: sink_name,
      event_kind: original_event.__struct__,
      reason: Exception.message(exception),
      occurred_at: DateTime.utc_now()
    })
  end
end
