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
| `engine:events` | Engine-level events plus PI-scoped events filtered at dispatch | Any authenticated user may join. PI-level events require §5.1 visibility (starter match, laneless FNI, or a matching lane). FNI-originating events require `laneName` to be `null` or in the subscriber's lanes. |
| `process_instance:<id>` | Events for one process instance | Join requires §5.1 PI visibility. PI-level events always deliver after a successful join. FNI events are lane-filtered. |
| `user_tasks:pending` | `UserTaskCreated` / `UserTaskFinished` inbox | Any authenticated user may join. Dispatch applies the same FNI lane rule. |

`process:<model_id>` is not implemented.

The WebSocket sink broadcasts PI-scoped events to **both** `process_instance:<id>` (and the root PI channel when it differs) **and** `engine:events`. `UserTaskCreated` / `UserTaskFinished` are also published to `user_tasks:pending`.

TypeScript clients can call `NotificationClient.subscribePendingUserTasks(handler)` to join the inbox topic.

### Engine Events

The `engine:events` topic also delivers operational events including
`EngineOverloaded` and `EngineRecovered` when the engine crosses
load-level thresholds. Clients can use these to implement client-side
back-pressure (on `EngineOverloaded`) and release it (on `EngineRecovered`).

### `process_instance:*` Authorization

Joining a `process_instance:<id>` channel requires that the PI is **visible** to the caller. Visibility follows the same rules as GraphQL:

- **Starter match** — the caller started the PI (`startedById == sub`)
- **Lane access** — the PI has at least one FNI on a lane the caller holds (`lane:<name>=true`), or FNIs without any lane
- **Admin override** — `zeeky_boogie_doog=true` bypasses all checks

If the PI is not visible, join returns `{:error, %{reason: "not_found"}}`.

### Lane-Filtered Event Dispatch

After join, `EventDelivery.should_deliver?/2` filters each envelope:

- FNI-originating events with `laneName: null` — always delivered
- FNI-originating events with a `laneName` — only if the subscriber holds `lane:<name>`
- Unknown envelope types — dropped (`zeeky_boogie_doog` still receives them)
- PI-level events (`ProcessInstanceStateChanged`, `ProcessInstanceRetried`) on `process_instance:*` — always delivered (join already proved visibility)
- PI-level events on `engine:events` — delivered when `startedById` matches, `hasLanelessFlowNode` is true, or any `laneNames` entry is accessible

The subscriber's accessible lanes are cached at join time.

GraphQL FNI reads stay PI-scoped: if you can see the PI, you can read every FNI. WebSocket FNI dispatch is the stricter lane gate.

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
    "processInstanceId": "...",
    "processModelId": "order-process",
    "version": "1.0.0",
    "oldState": "running",
    "newState": "finished",
    "startedById": "user-1",
    "hasLanelessFlowNode": false,
    "laneNames": ["Management"],
    "occurredAt": "2026-05-03T15:30:00Z"
  },
  "occurredAt": "2026-05-03T15:30:00Z"
}
```

- **`type`** — event struct name (e.g. `"ProcessInstanceStateChanged"`, `"FlowNodeInstanceStarted"`)
- **`data`** — all fields from the event struct (camelCase structural keys)
- **`occurredAt`** — timestamp (duplicated at top level for convenience)

## Event Types

### Engine-level (always delivered on `engine:events`)

| Type | Fields | Description |
|------|--------|-------------|
| `EngineStarted` | `engineId`, `engineName`, `version`, `startedAt` | Boot complete |
| `EngineShutdown` | `engineId`, `reason`, `occurredAt` | Graceful shutdown |
| `PluginQuarantined` | `pluginName`, `tier`, `reason`, `occurredAt` | Plugin load failure |

### PI-scoped (broadcast to `process_instance:<id>` and `engine:events`)

| Type | Fields | Description |
|------|--------|-------------|
| `ProcessInstanceStateChanged` | `processInstanceId`, `processModelId`, `version`, `oldState`, `newState`, `startedById`, `hasLanelessFlowNode`, `laneNames`, `occurredAt` | PI state transition |
| `FlowNodeInstanceStarted` | `flowNodeInstanceId`, `processInstanceId`, `flowNodeId`, `flowNodeType`, `laneName`, `occurredAt` | FNI begins execution |
| `FlowNodeInstanceFinished` | `flowNodeInstanceId`, `processInstanceId`, `flowNodeId`, `flowNodeType`, `terminalState`, `laneName`, `occurredAt` | FNI reaches terminal state |
| `UserTaskCreated` | `flowNodeInstanceId`, `processInstanceId`, `flowNodeId`, `assignees`, `laneName`, `occurredAt` | User task enters waiting (also `user_tasks:pending`) |
| `UserTaskFinished` | `flowNodeInstanceId`, `processInstanceId`, `flowNodeId`, `outcome`, `laneName`, `occurredAt` | User task completed/aborted (also `user_tasks:pending`) |
| `PluginAsyncFlowNodeRehydrated` | `flowNodeInstanceId`, `processInstanceId`, `pluginName`, `laneName`, `occurredAt` | Async FNI resumed after restart |

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
