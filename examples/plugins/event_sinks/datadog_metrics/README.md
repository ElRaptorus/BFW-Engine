# DataDog metrics — example event sink

Ready-to-copy starting point that converts selected `EvilEngine.Types.Event` structs
into counter-style metric entries, buffers them, and flushes in batches. The HTTP
upload is intentionally stubbed so you can wire `Req`, `:httpc`, or your stack’s
HTTP client.

## Usage

1. Copy `lib/datadog_plugin.ex` and `lib/datadog_sink.ex` into your OTP application.
2. Replace the placeholder API key (or load it from vault or environment variables).
3. Implement `default_on_flush/2` in `DatadogSink` to POST to DataDog’s metrics API.
4. Set `:plugin_module` in application env and add your app name to `EVIL_PLUGINS_INBEAM`
   (same pattern as other in-BEAM examples).

## Metric naming

| Engine event | Metric name |
|--------------|-------------|
| `ProcessInstanceStateChanged` | `evil.process_instance.state_changed` |
| `FlowNodeInstanceStarted` | `evil.flow_node.started` |
| `FlowNodeInstanceFinished` | `evil.flow_node.finished` |
| `EngineOverloaded` | `evil.engine.overload` |

Each flush sends a list of maps with `metric`, `tags`, `value` (always `1` in this example),
and `timestamp` (from the event’s `occurred_at`).

## Configuration

- **`api_key`** — DataDog API key (never commit production secrets).
- **`batch_size`** — Flush when the buffer reaches this many metric entries (default `10`).
- **`on_flush`** (optional) — `fn api_key, buffer -> ... end` for tests or custom delivery.

## Further reading

- [`EvilEngine.Plugin.EventSink`](../../../../apps/engine_sdk/lib/evil_engine/plugin/event_sink.ex)
  — callbacks your sink must implement.
- [`docs/architecture/event-system.md`](../../../../docs/architecture/event-system.md) —
  how events flow through `EngineEventBus` and sink workers.
