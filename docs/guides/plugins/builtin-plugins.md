# Built-in Plugins

The engine ships one built-in OTP plugin capability and three built-in event sinks.

The HTTP Service Task handler is registered by `EvilEngine.Plugins.Loader` before user plugins (implementation key `"http"`), so operators can override it. Built-in event sinks are **not** OTP plugins: `SinkRegistrar` attaches them to `EngineEventBus` at boot. They implement `@behaviour EvilEngine.Plugin.EventSink` but are not loaded via `EVIL_PLUGINS_INBEAM`.

There is no `evil:postgres_persistence` plugin. Execution persistence is `EvilEngine.Execution.Persistence` (AshPostgres via `ExecutionAdapter` in production, `NoOp` in tests), configured with `:core_execution, :persistence_adapter`.

## HTTP Service Task Handler

**Implementation:** `implementation="http"`  
**Module:** `EvilEngine.Plugins.Builtin.HttpServiceTaskHandler`  
**Location:** `apps/peripheral_plugins/`

Performs asynchronous HTTP requests using the `Req` library (all Service Task handlers are async-only). `handle_enter/3` validates inputs, spawns a Task for the HTTP call, and returns `{:async, flow_node_instance_id}`. On success, the Task calls `finish_async_service_task`; on failure, `fail_async_service_task`.

### Extension Elements

| Extension | FEEL? | Purpose |
|-----------|-------|---------|
| `evil:httpUrl` | No | Target URL (required) |
| `evil:httpMethod` | No | HTTP verb (default `GET`) |
| `evil:httpBody` | Yes | Request body — evaluated as a [FEEL expression](../handbook/expressions.md) |
| `evil:httpAuthHeader` | Yes | Authorization header — evaluated as FEEL |
| `evil:httpResponseHeaders` | Yes | Response header mapping — evaluated as FEEL |

### Supported Methods

`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`

### Behavior

- **Request timeout:** 30 seconds
- **Success (2xx):** response body is passed to `finish_async_service_task` as the output token
- **Error status:** calls `fail_async_service_task` with code `HTTP_ERROR`
- **Connection failure:** calls `fail_async_service_task` with code `HTTP_CONNECTION_FAILED`
- **Timeout:** calls `fail_async_service_task` with code `HTTP_TIMEOUT`
- **Payload cap:** output is checked against `EVIL_TOKEN_MAX_BYTES` (in the PI's `handle_fni_ok`)

### FEEL Context

FEEL expressions in `httpBody`, `httpAuthHeader`, and `httpResponseHeaders` are evaluated with the standard [expression bindings](../handbook/expressions.md): `token`, `this`, `context`, `dataObjects`, `process`, `processInstance`, `identity`.

The `httpResponseHeaders` expression additionally receives a `responseHeaders` binding (normalized to lowercase keys).

## Built-in Event Sinks

Three built-in sinks, registered by `SinkRegistrar` (not the plugin Loader). The built-in database sink was removed.

### Console Sink

Logs engine events at configurable severity.

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_EVENT_SINK_CONSOLE` | `on` | Enable/disable |
| `EVIL_LOG_MIN_SEVERITY` | `info` | Severity floor (`error`/`warn`/`info`/`debug`/`verbose`) |

### Telemetry Sink

Feeds the `/stats` endpoint counters.

| Env Var | Default |
|---------|---------|
| `EVIL_EVENT_SINK_TELEMETRY` | `on` |

Disabling this makes all `/stats` counters permanently zero.

### WebSocket Sink

Pushes events to connected Phoenix Channels clients. There is no separate WebSocket min-severity env var; use `EVIL_LOG_MIN_SEVERITY` for console logging. The WebSocket sink drops `debug`/`verbose` events by default so Studio clients are not flooded.

| Env Var | Default |
|---------|---------|
| `EVIL_EVENT_SINK_WEBSOCKET` | `on` |

## Related

- [Service Tasks](../handbook/service-tasks.md) -- using the HTTP handler in processes
- [Monitoring](../handbook/monitoring.md) -- sink configuration in practice
- [Observability](../operations/observability.md) -- production event pipeline setup
