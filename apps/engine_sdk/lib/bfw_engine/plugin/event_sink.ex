defmodule BfwEngine.Plugin.EventSink do
  @moduledoc """
  Receives every `BfwEngine.Types.Event.*` the engine emits.

  Each registered sink runs in its own sink worker GenServer under the
  engine's sink supervisor, which calls it serially in event order.
  Sinks MUST NOT call back into `core_execution` or block the hot path.

  ## Callbacks

  * `init/1` — called once at registration time with the opts passed to
    `facade.register_event_sink.("name", module, opts)`.
  * `accepts?/1` — fast filter; return `false` to skip dispatch for this event.
  * `handle_event/2` — process the event. Buffer internally if the downstream
    target is slow. A raise here (or in `accepts?/1`) is rescued by the
    sink's worker, which keeps its state, publishes `%Event.SinkFailed{}`
    (never for a failing `SinkFailed`), and continues with the next event.
  * `handle_shutdown/1` — called on graceful engine stop. Flush buffers here.
    Not called on SIGKILL.
  """

  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @callback accepts?(event :: struct()) :: boolean()

  @callback handle_event(event :: struct(), state :: term()) ::
              {:ok, state :: term()} | :skip

  @callback handle_shutdown(state :: term()) :: :ok
end
