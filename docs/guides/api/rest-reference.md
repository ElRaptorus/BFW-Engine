# REST API Reference

Base URL: `http://localhost:4000` (configurable via `EVIL_HTTP_PORT`).

OpenAPI spec: `GET /api/openapi`. Swagger UI: `GET /`.

All authenticated endpoints require a JWT Bearer token — see [Authentication](authentication.md).

## Public Endpoints

### `GET /health`

Liveness/readiness probe.

Response:
```json
{
  "status": "ok",
  "load": "normal",
  "uptime_seconds": 12345
}
```

The `"load"` field reflects the engine's current load level (`"normal"`,
`"elevated"`, or `"critical"`) based on the PI capacity ratio. When no
PI cap is configured, `load` is always `"normal"`.

No authentication required.

### `GET /metrics`

Prometheus exposition format. Returns all registered Telemetry metrics
as plain text (`text/plain; version=0.0.4`).

| Status | Condition |
|---|---|
| 200 | Metrics enabled (default) |
| 404 | `EVIL_METRICS_ENABLED=false` |

No authentication required (designed for Prometheus scraper access).

### `GET /info`

Engine identity and feature flags. No authentication required.

```json
{
  "engine_id": "evil-engine-local",
  "engine_name": "Evil Engine (local)",
  "version": "0.0.1",
  "started_at": "2026-05-03T15:00:00Z",
  "uptime_seconds": 3600,
  "auth_disabled": false,
  "event_sink_database": false
}
```

## Authenticated Endpoints

### `GET /stats`

Full engine state snapshot.

```json
{
  "engine": { "id": "...", "name": "...", "version": "...", "uptime_seconds": 3600 },
  "processes": { "total": 5 },
  "process_instances": { "running": 3, "finished": 12, "fatal": 0 },
  "flow_node_instances": { "active": 2, "waiting": 1 },
  "user_tasks_pending": 1,
  "timers": { "armed": 0 },
  "plugins": { "loaded": 2, "quarantined": 0 },
  "listeners": { "event_sinks_count": 3 }
}
```

### `GET /processes`

List all currently deployed processes. Returns the latest active version
of each process. Processes with no active versions (fully undeployed) are
excluded. No authorization claim required — any authenticated user can list.

**Success (200):**
```json
[
  { "id": "...", "processModelId": "order_process", "name": "Order Process", "enabled": true, "created_at": "...", "latest_version": "2.1.0" }
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
{ "deployed": [{ "processModelId": "order_process", "version": "1.0.0", "process_version_id": "..." }] }
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
{ "process_instance_id": "...", "processModelId": "order_process", "version": "1.0.0", "state": "running" }
```

| Status | Meaning |
|--------|---------|
| `201` | PI started |
| `403` | Process disabled, or caller has `"read"` / `observe_all` but not `"write"` on the Start Event's lane |
| `404` | Process not found, or caller has no observe claim on the Start Event's lane |
| `404` | Not found / no active version |
| `413` | Payload too large |
| `422` | Ambiguous start event |
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
Only terminal PIs (`finished`, `fatal`, `aborted`) can be deleted.

## Payload Cap

All endpoints accepting user payloads enforce `EVIL_TOKEN_MAX_BYTES` (default 64 KiB). Oversized payloads return:

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
