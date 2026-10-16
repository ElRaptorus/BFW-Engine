# Built-in Plugins

The engine ships one built-in OTP plugin capability and three built-in event sinks.

The HTTP Service Task handler is registered by `BfwEngine.Plugins.Loader` before user plugins (implementation key `"http"`). Registration is first-wins, so it cannot be overridden: a plugin that registers `"http"` gets `{:error, :conflict, "bfw:builtin"}`. Use another implementation key for a custom HTTP handler. Built-in event sinks are **not** OTP plugins: `SinkRegistrar` attaches them to `EngineEventBus` at boot. They implement `@behaviour BfwEngine.Plugin.EventSink` but are not loaded via `BFE_PLUGINS_INBEAM`.

There is no `bfw:postgres_persistence` plugin. Execution persistence is `BfwEngine.Execution.Persistence` (AshPostgres via `ExecutionAdapter` in production, `NoOp` in tests), configured with `:core_execution, :persistence_adapter`.

## HTTP Service Task Handler

**Implementation:** `implementation="http"`  
**Module:** `BfwEngine.Plugins.Builtin.HttpServiceTaskHandler`  
**Location:** `apps/engine_plugins/`

Performs asynchronous HTTP requests using the `Req` library (all Service Task handlers are async-only). `handle_enter/3` validates inputs, spawns a Task for the HTTP call, and returns `{:async, flow_node_instance_id}`. On success, the Task calls `finish_async_service_task`; on failure, `fail_async_service_task`.

### Extension Elements

| Extension | FEEL? | Purpose |
|-----------|-------|---------|
| `bfw:httpUrl` | No | Target URL (required) |
| `bfw:httpMethod` | No | HTTP verb (default `GET`) |
| `bfw:httpBody` | Yes | Request body — evaluated as a [FEEL expression](../handbook/expressions.md) |
| `bfw:httpAuthHeader` | Yes | Authorization header — evaluated as FEEL |
| `bfw:httpResponseHeaders` | Yes | Response header mapping — evaluated as FEEL |

### Supported Methods

`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`

### Behavior

- **Request timeout:** 30 seconds
- **Success (2xx):** response body is passed to `finish_async_service_task` as the output token
- **Error status:** calls `fail_async_service_task` with code `HTTP_<status>` (for example `HTTP_404`); the message quotes at most the first 500 characters of the response body
- **Connection failure:** calls `fail_async_service_task` with code `HTTP_CONNECTION_FAILED` and a message naming the failure (connection refused, connection closed, host not resolved, or the client's reason code)
- **Timeout:** calls `fail_async_service_task` with code `HTTP_TIMEOUT`
- **Request could not be executed** (the request raised, exited, or threw, for example a malformed URL or a stopped connection pool): calls `fail_async_service_task` with code `HTTP_REQUEST_FAILED`
- **Authorization header** that evaluates to anything but a string or number, or to text containing a carriage return, line feed, or NUL character: synchronous error `http_auth_expression_error`. Failure messages never contain the header value
- **Engine restart while the request is in flight:** `handle_resume/2` calls `fail_async_service_task` with code `HTTP_INTERRUPTED` (the message names the task and the URL); the request is not re-issued, so an error boundary decides
- **Payload cap:** output is checked against `BFE_TOKEN_MAX_BYTES` when the task finishes

### FEEL Context

FEEL expressions in `httpBody`, `httpAuthHeader`, and `httpResponseHeaders` are evaluated with the standard [expression bindings](../handbook/expressions.md): `token`, `this`, `context`, `dataObjects`, `process`, `processInstance`, `identity`.

The `httpResponseHeaders` expression additionally receives a `responseHeaders` binding (normalized to lowercase keys).

## Built-in Event Sinks

Three built-in sinks, registered by `SinkRegistrar` (not the plugin Loader).

### Console Sink

Logs engine events at configurable severity.

| Env Var | Default | Purpose |
|---------|---------|---------|
| `BFE_EVENT_SINK_CONSOLE` | `on` | Enable/disable |
| `BFE_LOG_MIN_SEVERITY` | `info` | Severity floor (`error`/`warn`/`info`/`debug`/`verbose`) |

### Telemetry Sink

Increments Prometheus `bfw_engine.event_bus.events.total`. Does **not** feed `/stats`.

| Env Var | Default |
|---------|---------|
| `BFE_EVENT_SINK_TELEMETRY` | `on` |

### WebSocket Sink

Pushes events to connected Phoenix Channels clients. There is no separate WebSocket min-severity env var; use `BFE_LOG_MIN_SEVERITY` for console logging. The WebSocket sink rejects only `SinkFailed`.

| Env Var | Default |
|---------|---------|
| `BFE_EVENT_SINK_WEBSOCKET` | `on` |

## Related

- [Service Tasks](../handbook/service-tasks.md) -- using the HTTP handler in processes
- [Monitoring](../handbook/monitoring.md) -- sink configuration in practice
- [Observability](../operations/observability.md) -- production event pipeline setup
