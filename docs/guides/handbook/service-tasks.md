# Service Tasks

Service Tasks execute automated logic via plugin-driven dispatch. The engine resolves the handler from the standard BPMN `implementation` attribute on the Service Task and delegates execution to the registered `ServiceTaskHandler` plugin.

## Async-Only Contract

All Service Task handlers are **asynchronous**. The handler returns `{:async, ref}` immediately, parking the FNI in `:waiting` state. The actual work runs outside the handler Task and completes (or fails) the FNI later through the engine facade.

This is a deliberate design choice: Service Tasks represent external delegation to remote systems. If your task performs local, synchronous computation, use a **Script Task** with a Named Script plugin instead. See [Script Tasks](script-tasks.md).

## How It Works

1. The BPMN process sets `implementation="http"` (or any custom handler key) on the `<bpmn:serviceTask>` element
2. At runtime, the engine runs the **input pipeline**: input mappers (FEEL) → payload contract (JSON Schema)
3. The engine looks up the registered `ServiceTaskHandler` for that implementation key and dispatches the (optionally mapped) token
4. The handler returns `{:async, flow_node_instance_id}` — the FNI enters `:waiting` state
5. The plugin completes the FNI later through the facade (see below)
6. On async completion, the **output pipeline** runs: output mappers (FEEL) → result contract (JSON Schema) → PayloadCap

## Built-in HTTP Handler

The engine ships with a built-in handler for `implementation="http"` that performs HTTP requests asynchronously. Configuration is via extension elements:

| Extension | FEEL? | Purpose |
|-----------|-------|---------|
| `bfw:httpUrl` | No | Target URL (required) |
| `bfw:httpMethod` | No | HTTP verb (default `GET`) |
| `bfw:httpBody` | Yes | Request body expression |
| `bfw:httpAuthHeader` | Yes | Authorization header expression |
| `bfw:httpResponseHeaders` | Yes | Response header mapping expression |

FEEL-enabled fields are evaluated against the standard [expression context](expressions.md) before the request is sent.

```xml
<bpmn:serviceTask id="call_api" name="Call Payment API" implementation="http">
  <bpmn:extensionElements>
    <bfw:httpUrl>https://api.example.com/payments</bfw:httpUrl>
    <bfw:httpMethod>POST</bfw:httpMethod>
    <bfw:httpBody>token</bfw:httpBody>
    <bfw:httpAuthHeader>identity.api_token</bfw:httpAuthHeader>
  </bpmn:extensionElements>
</bpmn:serviceTask>
```

An HTTP request in flight when the engine stops is not re-issued after the restart: the task is failed with error code `HTTP_INTERRUPTED`, so an Error Boundary Event (for example with `<bfw:errorCode>HTTP_INTERRUPTED</bfw:errorCode>`) decides whether to retry, compensate, or give up.

See [Built-in Plugins](../plugins/builtin-plugins.md) for the full HTTP handler specification.

## Input/Output Mappers

Optionally reshape data before/after the plugin handler runs. Mappers are FEEL expressions with `source`/`target` pairs:

```xml
<bpmn:serviceTask id="mapped_task" name="Mapped Service" implementation="echo">
  <bpmn:extensionElements>
    <bfw:inputMapping source="token.order_id" target="id"/>
    <bfw:payloadContract>{"type":"object","required":["id"],"properties":{"id":{"type":"string"}}}</bfw:payloadContract>
    <bfw:outputMapping source="token.input.id" target="result_id"/>
    <bfw:resultContract>{"type":"object","required":["result_id"],"properties":{"result_id":{"type":"string"}}}</bfw:resultContract>
  </bpmn:extensionElements>
</bpmn:serviceTask>
```

The input pipeline (`in_mappings` → `payloadContract`) runs in `handle_enter`. The output pipeline (`out_mappings` → `resultContract` → PayloadCap) runs in `handle_complete` when the async FNI is completed. All contract violations and FEEL evaluation failures fail the FNI (service tasks have no interactive retry path): an Error Boundary Event on the task or an Error Event Subprocess start in its scope may catch the error, otherwise the FNI transitions to `fatal`.

## Async Completion

When a handler returns `{:async, ref}`, the FNI enters `waiting` state. The plugin completes it later:

```elixir
# In the plugin, when the external work finishes:
facade.service_tasks.finish_async.(flow_node_instance_id, %{"result" => "success"})

# Or on failure:
facade.service_tasks.fail_async.(flow_node_instance_id, "TIMEOUT", "External service did not respond")
```

The completion may arrive before the handler's `handle_enter` has returned; the engine answers it at once and applies it when the FNI is `waiting` (it is dropped with a warning if the task ends otherwise first). A `fail_async` code is matched against Error Boundary Events first, then against Error Event Subprocess starts. A handler that raises instead of returning fails the task with error code `handler_raised`, which the same catchers can handle.

There is no dedicated REST endpoint for async completion — it is plugin-side only via the engine facade. GraphQL is query-only and has no mutation equivalent.

## Payload Cap

The output payload from a Service Task handler is checked against `BFE_TOKEN_MAX_BYTES` when the task finishes (after output mapping). If it exceeds the cap, the FNI fails: a catch-all Error Boundary Event (one without an error code) catches it and `finish_async` answers `:ok`; otherwise the FNI is `fatal` and `finish_async` answers `{:error, {:payload_too_large, details}}`. Error Event Subprocess starts do not catch this error. See [Error Handling](error-handling.md) for details.

## Custom Handlers

To implement your own Service Task handler, see [Implementing Service Task Handlers](../plugins/service-task-handler.md).

## Related

- [Script Tasks](script-tasks.md) -- for local, synchronous computation
- [FEEL Expressions](expressions.md) -- expression evaluation in HTTP body and headers
- [Built-in Plugins](../plugins/builtin-plugins.md) -- HTTP handler reference
- [Error Handling](error-handling.md) -- fatal states and payload cap
- [Plugin Development](../plugins/service-task-handler.md) -- implement custom handlers
