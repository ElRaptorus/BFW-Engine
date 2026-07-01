# WebSocket API

The engine pushes real-time events via Phoenix Channels over WebSocket.

## Connection

WebSocket connections share the same port as the HTTP/GraphQL API
(`EVIL_HTTP_PORT`, default `4000`). There is no separate WebSocket port.

Connect with a JWT token parameter for authentication:

```javascript
const socket = new Phoenix.Socket("ws://localhost:4000/socket", {
  params: { token: "eyJhbGciOi..." }
});
socket.connect();
```

When `EVIL_AUTH_DISABLED=true`, the token is not required and a synthetic anonymous identity is used.

## Channel Topics

| Topic | Content | Authorization |
|-------|---------|---------------|
| `engine:events` | Engine-level events (startup, shutdown, plugin) | Any authenticated user |
| `process_instance:<id>` | All events for a specific process instance | PI visibility check |

**Note:** Events with a `process_instance_id` are only broadcast to the `process_instance:<id>` topic — they do **not** appear on `engine:events`. Engine-level events without a PI are broadcast to `engine:events` only.

### Engine Events

The `engine:events` topic also delivers operational events including
`EngineOverloaded` and `EngineRecovered` when the engine crosses
load-level thresholds. Clients can use these to implement client-side
back-pressure (on `EngineOverloaded`) and release it (on `EngineRecovered`).

### `process_instance:*` Authorization

Joining a `process_instance:<id>` channel requires that the PI is **visible** to the caller. Visibility follows the same rules as GraphQL:

- **Starter match** — the caller started the PI (`started_by.id == sub`)
- **Lane access** — the PI has at least one FNI on a lane the caller holds (`lane:<name>=true`), or FNIs without any lane
- **Admin override** — `zeeky_boogie_doog=true` bypasses all checks

If the PI is not visible, join returns `{:error, %{reason: "not_found"}}`.

### Lane-Filtered Event Dispatch

After joining a `process_instance:*` channel, events are further filtered by lane:

- Events with no `lane_name` — always delivered
- Events with a `lane_name` — only delivered if the subscriber holds the matching `lane:<name>` claim

The subscriber's accessible lanes are cached at join time.

### Joining a Channel

```javascript
const channel = socket.channel("process_instance:01234567-89ab-cdef-0123-456789abcdef", {});
channel.join()
  .receive("ok", () => console.log("Joined"))
  .receive("error", (resp) => console.log("Error", resp));

channel.on("engine_event", (payload) => {
  console.log("Event:", payload.type, payload.data);
});
```

## Event Message Format

All events are pushed as `"engine_event"` messages with this shape:

```json
{
  "type": "ProcessInstanceStateChanged",
  "data": {
    "process_instance_id": "...",
    "process_version_id": "...",
    "old_state": "running",
    "new_state": "finished",
    "occurred_at": "2026-05-03T15:30:00Z"
  },
  "occurred_at": "2026-05-03T15:30:00Z"
}
```

- **`type`** — event struct name (e.g. `"ProcessInstanceStateChanged"`, `"FlowNodeInstanceStarted"`)
- **`data`** — all fields from the event struct
- **`occurred_at`** — timestamp (duplicated at top level for convenience)

## Event Types

### Engine-level (broadcast to `engine:events`)

| Type | Fields | Description |
|------|--------|-------------|
| `EngineStarted` | `engine_id`, `engine_name`, `version`, `started_at` | Boot complete |
| `EngineShutdown` | `engine_id`, `reason`, `occurred_at` | Graceful shutdown |
| `PluginQuarantined` | `plugin_name`, `tier`, `reason`, `occurred_at` | Plugin load failure |

### PI-scoped (broadcast to `process_instance:<id>`)

| Type | Fields | Description |
|------|--------|-------------|
| `ProcessInstanceStateChanged` | `process_instance_id`, `process_version_id`, `old_state`, `new_state`, `occurred_at` | PI state transition |
| `FlowNodeInstanceStarted` | `flow_node_instance_id`, `process_instance_id`, `flow_node_id`, `flow_node_type`, `occurred_at` | FNI begins execution |
| `FlowNodeInstanceFinished` | `flow_node_instance_id`, `process_instance_id`, `flow_node_id`, `flow_node_type`, `terminal_state`, `occurred_at` | FNI reaches terminal state |
| `UserTaskCreated` | `flow_node_instance_id`, `process_instance_id`, `flow_node_id`, `assignees`, `occurred_at` | User task enters waiting |
| `UserTaskFinished` | `flow_node_instance_id`, `process_instance_id`, `flow_node_id`, `outcome`, `occurred_at` | User task completed/aborted |
| `PluginAsyncFlowNodeRehydrated` | `flow_node_instance_id`, `process_instance_id`, `plugin_name`, `occurred_at` | Async FNI resumed after restart |

## Event Sink Configuration

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_EVENT_SINK_WEBSOCKET` | `true` | Toggle WebSocket event push |

The WebSocket sink is disabled in test environments by default.

## Related

- [Monitoring](../handbook/monitoring.md) — subscription use cases
- [Authentication](authentication.md) — JWT token for WebSocket auth
- [GraphQL Reference](graphql-reference.md) — query-based API
- [Implementing Event Sinks](../plugins/event-sink.md) — custom sink development
