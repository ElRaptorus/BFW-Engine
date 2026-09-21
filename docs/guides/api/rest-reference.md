# REST API Reference

Base URL: `http://localhost:4000` (configurable via `BFE_HTTP_PORT`).

OpenAPI spec: `GET /api/openapi`. Swagger UI: `GET /`.

All authenticated endpoints require a JWT Bearer token — see [Authentication](authentication.md).

## Public Endpoints

### `GET /health`

Public liveness probe. Returns **204 No Content** (empty body). No authentication required.

Load level is **not** on `/health`. Read `engine.load` from `GET /stats`.

### `GET /metrics`

Prometheus exposition format. Returns all registered Telemetry metrics
as plain text (`text/plain; version=0.0.4`).

| Status | Condition |
|---|---|
| 200 | Metrics enabled (default) |
| 404 | `BFE_METRICS_ENABLED=false` |

No authentication required (designed for Prometheus scraper access).

### `GET /info`

Engine identity and feature flags. No authentication required.

```json
{
  "engineId": "bfw-engine-local",
  "engineName": "Bifrost Forge World Engine (local)",
  "version": "0.1.0",
  "startedAt": "2026-05-03T15:00:00Z"
}
```

`event_sink_database` is **not** serialized. The built-in database event sink was removed; this leftover flag is always absent (never `true`).

## Authenticated Endpoints

### `GET /stats`

Full engine state snapshot (camelCase wire keys). Auth required.

```json
{
  "engine": {
    "id": "...",
    "name": "...",
    "version": "...",
    "startedAt": "2026-08-24T12:00:00Z",
    "uptimeSeconds": 3600,
    "load": "normal"
  },
  "processInstances": { "running": 3, "finished": 12, "fatal": 0, "aborted": 0, "error": 0 },
  "flowNodeInstances": {
    "active": 2,
    "waiting": 1,
    "finished": 10,
    "fatal": 0,
    "aborted": 0,
    "interrupted": 0,
    "error": 0,
    "byType": {}
  },
  "userTasksPending": { "count": 1, "byAssigneeRole": {} },
  "asyncFlowNodes": { "waiting": 0, "byPlugin": {} },
  "timers": { "armed": 0, "fireInNextMinute": 0 },
  "plugins": [],
  "listeners": {
    "eventSinksCount": 3,
    "eventSinksByName": { "console": "on", "telemetry": "on", "websocket": "on" },
    "monitoringPanelsCount": 0
  }
}
```

### `GET /processes`

List all currently deployed processes. Returns the latest active version
of each process. Processes with no active versions (fully undeployed) are
excluded. No authorization claim required — any authenticated user can list.

**Success (200):**
```json
[
  { "id": "...", "processModelId": "order_process", "name": "Order Process", "enabled": true, "createdAt": "...", "latestVersion": "2.1.0" }
]
```

### `GET /processes/{model_id}`

Process metadata. Use `?includeXml=true` to include the latest active
version's BPMN XML. Version history is available at
`GET /processes/{model_id}/versions`.

### `GET /processes/{model_id}/versions`

Lists all deployed versions of a process. Use `?includeXml=true` to
include each version's BPMN XML in the response.

### `POST /processes`

Deploy one or more BPMN definitions in a single atomic batch.
Body: JSON with a `sources` array of BPMN XML strings.
On deploy, the process `enabled` flag is synchronized with the BPMN
`isExecutable` attribute (see [Deploying Processes](../handbook/deploying-processes.md)).

**Authorization:** Requires `deploy_bpmn=true` claim. Returns 403 Forbidden without it.

**Request body:**
```json
{
  "sources": [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><bpmn:definitions ...>...</bpmn:definitions>"
  ]
}
```

**Success (201):**
```json
{ "deployed": [{ "processModelId": "order_process", "version": "1.0.0", "processVersionId": "..." }] }
```

**Linter gate failure (422):**
```json
{
  "error": "linter_gate_failed",
  "failures": [{ "rulesetId": "bpmn-production-ready", "reason": "score_below_minimum" }]
}
```

See [Deploying Processes](../handbook/deploying-processes.md) for details.

### `POST /processes/{model_id}/start`

Start a new process instance. Body:

```json
{ "payload": { "orderId": "ORD-123" }, "startEventId": "Start_Main", "businessKey": "ext-ref" }
```

**Success (201):**
```json
{ "processInstanceId": "...", "processModelId": "order_process", "version": "1.0.0", "state": "running" }
```

| Status | Meaning |
|--------|---------|
| `201` | PI started |
| `403` | Caller has `"read"` / `observe_all` but not `"write"` on the Start Event's lane |
| `404` | Process not found, or caller has no observe claim on the Start Event's lane |
| `404` | Not found / no active version |
| `413` | Payload too large |
| `422` | Process disabled (`process_disabled`), or ambiguous start event |
| `429` | Start rate limit exceeded. `Retry-After` header present. |
| `503` | Engine at capacity (max concurrent PIs reached). `Retry-After: 5` header. |

See [Starting Process Instances](../handbook/starting-instances.md).

### `PUT /processes/{model_id}/enable` / `PUT /processes/{model_id}/disable`

Toggle process availability. Returns `204 No Content` on success.

**Authorization:** Requires `deploy_bpmn=true` claim. Returns 403 Forbidden without it.

### `DELETE /processes/{model_id}`

Undeploy a process by deleting all its versions. Returns `204 No Content`
on success. Returns `404` if the process does not exist or is already
fully undeployed. Does not change the process `enabled` state.

**Authorization:** Requires `delete_bpmn=true` claim. Returns 403 Forbidden without it.

### `DELETE /processes/{model_id}/versions/{version}`

Delete a version. Returns `204 No Content` on success.

**Authorization:** Requires `delete_bpmn=true` claim. Returns 403 Forbidden without it.

See [Deploying Processes](../handbook/deploying-processes.md).

### `PUT /user-tasks/{fniId}/finish`

Complete a User Task with result. Body:

```json
{ "result": { "approved": true } }
```

| Status | Meaning |
|--------|---------|
| `204`  | Task completed (no body) |
| `403`  | Visible but not writable (`"read"` / `observe_all`) |
| `404`  | FNI not found or invisible (no observe of that lane) |
| `413`  | Result payload exceeds cap |
| `422`  | Not in `waiting` state or contract violation |

Authorization: caller needs `lane:<lane_name>="write"` for the task's lane.
`"read"` / `observe_all` → **403**. Invisible tasks return **404**.
See [User Tasks](../handbook/user-tasks.md).

### `PUT /user-tasks/{fniId}/cancel`

Cancel a User Task and abort the entire process instance. This has the
same effect as `PUT /process-instances/{id}/abort` — all parallel branches
are stopped and the PI transitions to `aborted`. Body (optional):

```json
{ "reason": "No longer needed" }
```

| Status | Meaning |
|--------|---------|
| `204`  | Task cancelled, PI aborted (no body) |
| `403`  | Visible but not writable (`"read"` / `observe_all`) |
| `404`  | FNI not found or invisible (no observe of that lane) |
| `422`  | Not in `waiting` state |

Same lane-based authorization as finish.

### `PUT /process-instances/{id}/abort`

Abort a running process instance. All active FNIs are aborted and the PI
transitions to `aborted`. Body (optional):

```json
{ "reason": "Operator abort" }
```

| Status | Meaning |
|--------|---------|
| `204`  | PI aborted (no body) |
| `403`  | Insufficient `abort_process_instance` claim |
| `404`  | PI not found or not running |
| `422`  | PI already in terminal state |

Authorization: requires `abort_process_instance` claim — `own` (can abort
PIs started by the caller) or `all` (any PI). Default is `none` (403).
See [Authentication](authentication.md).

### `DELETE /process-instances/{id}`

Delete a terminal process instance. All associated FNIs are also
deleted in the same transaction.

| Status | Meaning |
|--------|---------|
| `204`  | PI and FNIs deleted (no body) |
| `403`  | Insufficient `delete_process_instance` claim |
| `404`  | PI not found or already deleted |
| `422`  | PI is not in a terminal state (still running) |

Authorization: requires `delete_process_instance` claim — `own` (can delete
PIs started by the caller) or `all` (any PI). Default is `none` (403).
Only terminal PIs (`finished`, `fatal`, `aborted`, `error`, `escalated`, `compensated`) can be deleted. `:cancelled` is a transaction-child business outcome and is not in this delete set.

### `PUT /process-instances/{id}/retry`

Retry a terminal PI (`fatal`, `aborted`, or `error`). Optional body:

```json
{ "version": "latest", "resetToFlowNodeInstanceId": "..." }
```

| Status | Meaning |
|--------|---------|
| `204` | Retry accepted (no body) |
| `403` | Insufficient `retry_process_instance` claim |
| `404` | PI not found |
| `422` | Not retryable, or checkpoint/scope restriction (join gateway, MI iteration, transaction, ad-hoc, …) |

Authorization: `retry_process_instance` — `own` or `all`. Default `none` (403).
`:compensated` / `:escalated` / `:cancelled` are not retryable.
See [Retry](../handbook/retry.md). Request/response schemas: OpenAPI `GET /api/openapi`.

## Decisions (DMN)

Full set on `DecisionController`. Schemas: OpenAPI.

| Method | Path | Purpose | Claim |
|--------|------|---------|-------|
| `GET` | `/decisions` | List deployed decisions | any authenticated |
| `GET` | `/decisions/{model_id}` | Metadata (`?includeXml=true`) | any authenticated |
| `GET` | `/decisions/{model_id}/versions` | Version history (`?includeXml=true`) | any authenticated |
| `POST` | `/decisions` | Deploy DMN (body `{sources: ["<xml>"]}`) | `deploy_dmn` |
| `POST` | `/decisions/{model_id}/evaluate` | Ad-hoc evaluate | any authenticated |
| `POST` | `/decisions/{model_id}/versions/{version}/evaluate` | Evaluate a pinned version | any authenticated |
| `POST` | `/decisions/{model_id}/services/{service_id}/evaluate` | Evaluate a Decision Service | any authenticated |
| `PUT` | `/decisions/{model_id}/enable` | Enable (204) | `deploy_dmn` |
| `PUT` | `/decisions/{model_id}/disable` | Disable (204) | `deploy_dmn` |
| `DELETE` | `/decisions/{model_id}` | Undeploy all versions (204) | `delete_dmn` |
| `DELETE` | `/decisions/{model_id}/versions/{version}` | Soft-delete a version (204) | `delete_dmn` |

See [DMN Decisions](../handbook/dmn-decisions.md). There are no GraphQL writes for DMN.

## Timer schedules

Created automatically when a process version with timer start events is deployed.

| Method | Path | Purpose | Claim |
|--------|------|---------|-------|
| `GET` | `/timer-schedules` | List (`?processVersionId=`, `?enabled=`) | `deploy_bpmn` |
| `GET` | `/timer-schedules/{id}` | Show one | `deploy_bpmn` |
| `PUT` | `/timer-schedules/{id}/enable` | Re-enable (204) | `deploy_bpmn` |
| `PUT` | `/timer-schedules/{id}/disable` | Disable (204) | `deploy_bpmn` |

There is no `PUT /timer-schedules/{id}` toggle. See [Timer Events](../handbook/timer-events.md).

## Timer event trigger

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/timer-events/{flow_node_instance_id}/trigger` | Manually fire a waiting timer FNI (catch or boundary) |

Body: empty or `{}`. Success `200`: `{ "triggered": true }`. Auth: `lane:<name>="write"` (or laneless / `zeeky_boogie_doog`). `"read"` / `observe_all` → 403; invisible → 404; not a timer → 422 `not_a_timer_event`; not waiting → 409.

## Messages and signals

| Method | Path | Purpose | Claim |
|--------|------|---------|-------|
| `POST` | `/messages/{message_name}/trigger` | Publish a named message. Body `{payload?, correlation?}` | `trigger_message` (`"all"`) |
| `POST` | `/signals/{signal_name}/trigger` | Broadcast a named signal. Body empty/`{}`; `payload` ignored | `trigger_signal` (`"all"`) |

Response shapes and routing: OpenAPI + [Message Events](../handbook/message-events.md) / [Signal Events](../handbook/signal-events.md). Commands are REST only.

## Escalations

| Method | Path | Purpose | Claim |
|--------|------|---------|-------|
| `POST` | `/escalations/{escalation_code}/trigger` | Inject a named escalation into waiting catchers (ESP starts and waiting Escalation Boundary FNIs) | `trigger_escalation` (boolean) |

Body: empty or `{}`. Any `payload` key is ignored. Success `200`: `{ "escalationCode", "deliveries": [{ "processInstanceId", "flowNodeInstanceId" }], "pending": false }`. Empty `deliveries` is success. Errors: `403` (missing / false claim), `422` (`escalation_code_blank` / `escalation_code_too_long`). This is an operator inject, not a modeled BPMN throw: no pending table, unmatched PIs are not marked `:escalated`.

See [Escalation Events](../handbook/escalation-events.md).

## Ad-hoc subprocesses

`{id}` is the **child process instance ID** spawned by the ad-hoc handler — not the parent PI and not the shell FNI ID.

| Method | Path | Purpose | Claim |
|--------|------|---------|-------|
| `GET` | `/adhoc-subprocesses/{id}/activities` | List enabled/performed inner activities | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/activities/{activity_id}/activate` | Activate an inner activity | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/complete` | Signal completion | `manage_adhoc_subprocess` |
| `GET` | `/adhoc-subprocesses/{id}/status` | Runtime status | `manage_adhoc_subprocess` |

See [Ad-hoc Subprocesses](../handbook/adhoc-subprocesses.md). No GraphQL writes.

## Payload Cap

All endpoints accepting user payloads enforce `BFE_TOKEN_MAX_BYTES` (default 64 KiB). Oversized payloads return:

**HTTP 413:**
```json
{ "error": "payload_too_large", "field": "payload", "size": 123456, "limit": 65536 }
```

See [Error Handling](../handbook/error-handling.md).

## Deprecation Policy

When an API endpoint is deprecated, responses include RFC 8594 headers:

| Header | Value | Description |
|---|---|---|
| `Deprecation` | `true` | Endpoint is deprecated |
| `Link` | `<successor-url>; rel="successor-version"` | Replacement endpoint |
| `Sunset` | HTTP-date (RFC 7231) | When the endpoint will be removed (optional) |

**No routes are currently deprecated.** These headers will appear when
endpoints are retired in future versions. Consumers should monitor for
the `Deprecation: true` header in integration tests.

## Related

- [Authentication](authentication.md) -- JWT setup
- [GraphQL API Reference](graphql-reference.md) -- read-only queries
- [WebSocket API](websocket.md) -- real-time event streaming
