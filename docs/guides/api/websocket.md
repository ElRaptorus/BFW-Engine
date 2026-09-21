# WebSocket API

The engine pushes real-time events via Phoenix Channels over WebSocket.

## Connection

WebSocket connections share the same port as the HTTP/GraphQL API
(`BFE_HTTP_PORT`, default `4000`). There is no separate WebSocket port.

Connect with a JWT token parameter for authentication:

```javascript
const socket = new Phoenix.Socket("ws://localhost:4000/socket", {
  params: { token: "eyJhbGciOi..." }
});
socket.connect();
```

When `BFE_AUTH_DISABLED=true`, the token is not required and a synthetic anonymous identity is used.

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
- **Lane access** — the PI has at least one FNI on a lane the caller holds as `"read"` or `"write"`, or FNIs without any lane, or `observe_all`
- **Admin override** — `zeeky_boogie_doog=true` bypasses all checks

If the PI is not visible, join returns `{:error, %{reason: "not_found"}}`.

### Lane-Filtered Event Dispatch

After join, `EventDelivery.should_deliver?/2` filters each envelope:

- FNI-originating events with `laneName: null` — always delivered
- FNI-originating events with a `laneName` — only if the subscriber holds `lane:<name>` as `"read"` or `"write"`, or `observe_all` / zeeky
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

Full catalog: [event-system.md](../../architecture/event-system.md). Structural keys are camelCase. Opaque payload subtrees are not transformed.

Twelve event types carry `rootProcessInstanceId`. For child PIs the WebSocket sink also broadcasts to `process_instance:<rootProcessInstanceId>` so a debugger subscribed only to the root channel receives descendant FNI, user-task, data-object, and compensation events.

### Engine-level (always delivered on `engine:events`)

| Type | Fields | Description |
|------|--------|-------------|
| `EngineStarted` | `engineId` | Boot complete |
| `EngineShutdown` | `engineId` | Graceful shutdown |
| `EngineOverloaded` | `level`, `activeProcessInstances`, `limit` | Load crossed upward (`elevated` / `critical`) |
| `EngineRecovered` | `previousLevel`, `activeProcessInstances`, `limit` | Load dropped back to `normal` |
| `PluginQuarantined` | `pluginName`, `reason` | Plugin load / registration failure |

### PI-scoped (broadcast to `process_instance:<id>` and, when distinct, the root PI channel)

| Type | Description |
|------|-------------|
| `ProcessInstanceStateChanged` | PI state transition (includes `hasLanelessFlowNode`, `laneNames`) |
| `ProcessInstanceRetried` | Retry accepted (`version` / `previousVersion` / `newVersion` are process-version UUIDs) |
| `FlowNodeInstanceStarted` | FNI begins execution |
| `FlowNodeInstanceFinished` | FNI reaches a terminal state (`errorInfo` on fatals) |
| `FlowNodeInstanceStateChanged` | Non-terminal FNI transition (currently `active` → `waiting`) |
| `MultiInstanceStarted` / `MultiInstanceCompleted` | MI / Standard Loop shell lifecycle |
| `UserTaskCreated` / `UserTaskFinished` | Also `user_tasks:pending` |
| `UserTaskValidationFailed` | Result-contract violations |
| `CallActivityChildStarted` | Child PI spawned by a Call Activity |
| `SubProcessChildStarted` | Embedded / Event / Ad-hoc subprocess child (`isEventSubprocess`, `isAdHocSubprocess`) |
| `EventSubprocessTriggered` | ESP trigger fired (`triggerKind`, `isInterrupting`) |
| `DataObjectWritten` | Successful DOA write |
| `TimerFired` | Catch / boundary / start timer fired |
| `MessagePublished` / `MessageArrived` | Message pipeline |
| `SignalPublished` / `SignalArrived` | Signal broadcast |
| `EscalationRaised` | Modeled throw or `throwType: "api_trigger"` |
| `CompensationTriggered` / `ActivityCompensated` | Compensation dispatch |
| `TransactionCancelled` | Transaction child reached `:cancelled` |
| `AdHocActivityActivated` / `AdHocSubProcessCompleted` | Ad-hoc control |
| `ProcessDefinitionDeployed` / `Undeployed` / `Enabled` / `Disabled` | Catalog |
| `DecisionDefinitionDeployed` / `Undeployed` / `DecisionEvaluated` | DMN |
| `PluginAsyncFlowNodeRehydrated` | Async FNI resumed after restart |

`SinkFailed` does **not** reach the WebSocket sink.

## Event Sink Configuration

| Env Var | Default | Purpose |
|---------|---------|---------|
| `BFE_EVENT_SINK_WEBSOCKET` | `true` | Toggle WebSocket event push |

The WebSocket sink is disabled in test environments by default.

## Related

- [Monitoring](../handbook/monitoring.md) — subscription use cases
- [Authentication](authentication.md) — JWT token for WebSocket auth
- [GraphQL Reference](graphql-reference.md) — query-based API
- [Implementing Event Sinks](../plugins/event-sink.md) — custom sink development
