defmodule EvilEngine.Plugin.EventSink do
  @moduledoc """
  Receives every `EvilEngine.Types.Event.*` the engine emits.

  Runs in its own supervised Task; crashes are isolated by EngineEventBus.
  Sinks MUST NOT call back into `core_execution` or block the hot path.

  ## Callbacks

  * `init/1` — called once at registration time with the opts passed to
    `facade.register_event_sink.("name", module, opts)`.
  * `accepts?/1` — fast filter; return `false` to skip dispatch for this event.
  * `handle_event/2` — process the event. Buffer internally if the downstream
    target is slow. Raising here is caught by EngineEventBus which emits
    `%Event.SinkFailed{}` and continues other sinks.
  * `handle_shutdown/1` — called on graceful engine stop. Flush buffers here.
    Not called on SIGKILL.
  """

  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @callback accepts?(event :: struct()) :: boolean()

  @callback handle_event(event :: struct(), state :: term()) ::
              {:ok, state :: term()} | :skip

  @callback handle_shutdown(state :: term()) :: :ok
end
