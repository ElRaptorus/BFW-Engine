# Implementing Event Sinks

An Event Sink receives every typed engine event emitted to the `EngineEventBus`. Sinks are used for logging, metrics, auditing, and forwarding events to external systems.

## Behaviour

```elixir
@behaviour EvilEngine.Plugin.EventSink

@callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
@callback accepts?(event :: struct()) :: boolean()
@callback handle_event(event :: struct(), state :: term()) :: {:ok, state :: term()} | :skip
@callback handle_shutdown(state :: term()) :: :ok
```

## Callbacks

### `init/1`

Called once at registration time with the opts passed to `register_event_sink`. Return `{:ok, state}` to initialize internal state, or `{:error, reason}` to reject registration.

### `accepts?/1`

Fast filter called before `handle_event/2`. Return `false` to skip dispatch for this event type. Useful for sinks that only care about specific event categories.

### `handle_event/2`

Process the event. Must be **O(1) in observable cost** — buffer internally if the downstream target is slow.

Return `{:ok, new_state}` to update state, or `:skip` to preserve the previous state unchanged.

Raising is caught by the `EngineEventBus`, which emits `Event.SinkFailed` to all surviving sinks and continues dispatch.

### `handle_shutdown/1`

Called on graceful engine stop. Flush internal buffers here. Not called on SIGKILL.

## Registration

In your plugin's `on_load`:

```elixir
def on_load(facade) do
  facade.register_event_sink.("my-datadog", MyPlugin.DatadogSink,
    api_key: "...",
    batch_size: 100
  )
  :ok
end
```

## Crash Isolation

- Sink crashes never kill the `EngineEventBus`
- A `SinkFailed` event is emitted to all surviving sinks with the offending sink name, event kind, and error reason
- The crashing sink's previous state is preserved for the next event

## Example: Simple Logging Sink

```elixir
defmodule MyPlugin.AuditSink do
  @behaviour EvilEngine.Plugin.EventSink

  require Logger

  @impl true
  def init(opts) do
    {:ok, %{log_level: Keyword.get(opts, :level, :info)}}
  end

  @impl true
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    Logger.log(state.log_level, "Engine event: #{inspect(event.__struct__)}")
    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state) do
    Logger.info("Audit sink shutting down")
    :ok
  end
end
```

## Event Types

All events are structs under `EvilEngine.Types.Event.*`:

- `EngineStarted`, `EngineShutdown`
- `SinkFailed`, `PluginQuarantined`
- PI and FNI lifecycle events
- And more — see the `core_types` module documentation

## Related

- [Monitoring](../handbook/monitoring.md) -- built-in sink configuration
- [Error Handling](../handbook/error-handling.md) -- `SinkFailed` event details
- [Engine Facade Reference](engine-facade.md) -- registration API
- [Built-in Plugins](builtin-plugins.md) -- reference sink implementations
