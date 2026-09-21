# API design

### Snake/camelCase Contract

All REST responses and WebSocket event envelopes use **camelCase** structural keys (for example `processInstanceId`, `processModelId`, `createdAt`). GraphQL already uses camelCase via AshGraphql, so all three API surfaces now speak the same convention.

**Opaque payload boundary rule:** user-payload subtrees are passed through unchanged. The encoder converts structural field names but does **not** recurse into fields designated as opaque (for example `payload`, `inputToken`, `outputToken`, `startedWithContext`, `startedBy`, `deployer`, `claims`, `typeProperties`, `errorInfo`, `violations`). This means keys inside a process token's `payload` are exactly what the process author set — the engine never rewrites them. Engine-structural error fields like `failures` and `conflicts` are **not** opaque — their nested keys (e.g. `processModelId`, `rulesetFailures`) are camelCased normally.

The boundary is enforced in `BfwEngine.Types.Wire` (`apps/core_types/lib/bfw_engine/types/wire.ex`). Jason.Encoder implementations for all event structs live in `apps/core_events/lib/bfw_engine/events/json_encoders.ex`.

### Centralized Error Responses

All REST error responses go through `BfwEngineWeb.Http.ErrorResponse` (`apps/api_web/lib/bfw_engine_web/http/error_response.ex`). This guarantees every error body:

1. Contains at least `error` (snake_case code) and `message` fields
2. Has all structural keys camelCased via `Wire.camelize_keys/1`
3. Uses field names matching the SDK's `ErrorMapper` expectations

Controllers use `render_error/4` (or `/5` with extras). Plugs that halt the conn before Phoenix.Controller is available use `render_error_halt/4` (or `/5`). The `api_auth` plug (`BfwEngine.Auth.Plug`) is in a separate umbrella app and uses its own `send_resp/3` calls — it cannot depend on `api_web`.

#### Audit-trail logging

Every error response is automatically logged by `ErrorResponse` for the server-side audit trail:

| HTTP status | Logger level | Example |
|---|---|---|
| 5xx (server errors) | `:error` | `API 500: POST /messages/foo/trigger — internal_error: Failed to publish message (actor: admin)` |
| 4xx (client errors) | `:warning` | `API 404: GET /processes/unknown — not_found: Process not found (actor: user1)` |

Log lines include HTTP method, path, status code, error code, message, and the acting identity. Metadata keys (`http_status`, `error_code`, `actor`) are available for structured JSON logging in production (via `LoggerJSON`).

Additional logging beyond `ErrorResponse`:

| Component | What is logged | Level |
|---|---|---|
| `Auth.Plug` | Missing auth header, no JWT key configured, JWT verification failures | `:warning` |
| `PayloadCapPlug` | Payload size exceeded (with field, size, limit) | `:warning` |
| `RateLimitPlug` | Start rate limit exceeded (with retry-after) | `:warning` |
| `MessageController` / `SignalController` | Full exception + stacktrace for rescued 500s | `:error` |
| `ErrorLogger` Absinthe phase | GraphQL errors (validation, policy denial, depth/complexity limit) | `:warning` |

**Unified terminal-state codes:** The `ProcessInstanceController` returns `process_already_terminal` (with a `currentState` field) instead of separate `process_already_finished` / `process_already_fatal` / `process_already_aborted` codes. Similarly, `process_instance_not_terminal` includes `currentState`.

### 10.1 REST surface (lightweight, trigger-style)

JWT bearer is required by default for authenticated routes ([authorization.md](./authorization.md)). **Public** routes (`GET /health`, `GET /info`, `GET /metrics`) bypass auth.

The umbrella currently mounts **process-catalog** REST handlers at the **root** path (e.g. `POST /processes`), not under `/api/v1`. **GraphQL** is at `POST /api/v1/graphql`. OpenAPI JSON is at `GET /api/openapi`.

#### 10.1.0 Process catalog & lifecycle (`ProcessController` — implemented)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/processes` | List all deployed processes (latest active version per process, no XML). Fully undeployed processes are excluded. Any authenticated user |
| `GET` | `/processes/{model_id}` | Process metadata (optional `?includeXml=true` for latest version's BPMN XML) |
| `GET` | `/processes/{model_id}/versions` | Version history (optional `?includeXml=true` per version) |
| `POST` | `/processes` | Deploy one or more BPMN definitions in a single **atomic batch**. Body: `{ "sources": ["<xml>", ...] }` (JSON array of BPMN XML strings). Each source must carry `<bfw:version>`. On deploy, `Process.enabled` is synced to the BPMN `isExecutable` flag. When the linter-score gate is enabled ([configuration.md](./configuration.md) — Linter-score deploy gate), each source is checked; on failure, returns `422` with `error: "linter_gate_failed"` and `failures`. On success, returns `201` with `deployed: [...]` |
| `POST` | `/processes/{model_id}/start` | Start a new PI from the latest non-deleted version of an enabled process. Body: `{startEventId?, payload?, context?, businessKey?}`. `context` is an optional opaque JSON object stored as `started_with_context` on the PI, accessible as `context.*` in FEEL expressions. When omitted, context is empty. Returns `201` with `{process_instance_id, process_model_id, version, state}`. Errors: `404` (not found / no active version), `403` (disabled), `422` (ambiguous start event / not found), `413` (payload too large), `429` with `Retry-After` when the global start rate limit is exceeded (`BFE_PI_START_RATE_LIMIT` > 0; Layer 2), `503` with `Retry-After` when `BFE_MAX_CONCURRENT_PIS` is exceeded (Layer 1), `401` (unauthenticated / expired JWT) |
| `PUT` | `/processes/{model_id}/enable` | Enable the process (204 No Content) |
| `PUT` | `/processes/{model_id}/disable` | Disable the process (204 No Content) |
| `DELETE` | `/processes/{model_id}` | **Undeploy** a process: deletes all versions. Rejects with 409 if non-terminal PIs exist on any version. Requires `delete_bpmn=true`. Returns 404 for unknown or already-undeployed processes |
| `DELETE` | `/processes/{model_id}/versions/{version}` | **Delete** a version: marks the matching version as deleted (204 No Content). Rejects with 409 if non-terminal PIs exist on the version |

#### 10.1.0.1 Public `/health`, `/metrics`, process-start back-pressure, and deprecation

**`GET /health`** — Liveness/readiness; **no auth**. Returns **204 No Content** (empty body). Kubernetes probes should check the status code only. Load level is **not** on `/health`; it is `engine.load` on **`GET /stats`** (`normal` / `elevated` / `critical`, derived from active PI count vs. `BFE_MAX_CONCURRENT_PIS` at 70% / 90% thresholds when the cap is finite; always `normal` when the cap is `:infinity`). This aligns with the `bfw_engine.process_instance.capacity.ratio` last-value metric and overload signaling.

**`GET /metrics`** — Prometheus text exposition (public; **no auth**). Served by `api_web` when `BFE_METRICS_ENABLED` is `true` (default). Metric definitions live in `BfwEngine.Telemetry.Metrics` (`peripheral_telemetry`); scrape output is plain text per Prometheus exposition format. When metrics are disabled, returns **404** with JSON `{"error":"metrics_disabled"}`.

**`POST /processes/{model_id}/start` — `503` / `429`** — When the admission pre-check rejects a new PI because `BFE_MAX_CONCURRENT_PIS` is reached, the facade returns `{:error, :engine_at_capacity, %{active, limit}}` and the controller responds with **503 Service Unavailable**, a `Retry-After` header, and a structured JSON body. When `BFE_PI_START_RATE_LIMIT` is greater than zero and the ETS token-bucket plug (`RateLimitPlug` on the authenticated pipeline) is exhausted, the controller responds with **429 Too Many Requests** and `Retry-After`. Env vars and defaults: [configuration.md](./configuration.md).

**Deprecation headers (RFC 8594)** — Routes mark themselves by setting `conn.private[:deprecated]` to `%{successor: path, sunset: optional_datetime}` (via `plug :put_private` or scope options). `DeprecationPlug` injects `Deprecation`, `Link` (`rel="successor-version"`), and optional `Sunset` on responses. Full rules: [§10.5](#105-deprecation-headers-rfc-8594).

Additional trigger-style paths in the table below remain specified for v1 parity; wire them through REST controllers (and the plugin facade) when not yet present on `BfwEngineWeb.Http.Router`. GraphQL is query-only — it is never a command surface.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness/readiness; **no auth**; **204 No Content**. Load is `engine.load` on `GET /stats` |
| `GET` | `/info` | Engine id/name/version/`startedAt`; **no auth** |
| `GET` | `/metrics` | Prometheus text exposition; **no auth** when enabled (`BFE_METRICS_ENABLED`, default `true`). Returns `404` with `{"error":"metrics_disabled"}` when disabled |
| `GET` | `/stats` | JSON snapshot of current engine state (see [observability.md](./observability.md)) |
| `POST` | `/processes/{model_id}/start` | Start a new PI (body: startEventId?, payload?, context?, businessKey?). `context` is stored as `started_with_context`; empty when omitted. Always resolves to the latest non-deleted version (`process_versions.deleted=false`) of an enabled process |
| `POST` | `/messages/{message_name}/trigger` | **Implemented** — publish a named message. Body: `{payload?, correlation?}` — message name is the path parameter. `correlation` is optional; if absent, the published `correlation_value` defaults to `:none` ([routing.md](./routing.md) §3.5.2). Routing follows [routing.md](./routing.md) §3.5.3: every subscription whose `(message_name, expected_correlation_value)` matches receives a copy (broadcast-within-key). If **any** subscription matches, Message Start Events are suppressed (catch-wins-over-Start); if none match and at least one deployed process has a Message Start Event with matching name, one PI is started per such process. If none match and no Start Event matches, the message is held in `pending_messages` for `BFE_MESSAGE_PENDING_TTL` ([configuration.md](./configuration.md)). Response body: `{messageId, correlationValue, deliveries: [{processInstanceId, flowNodeInstanceId}], startedProcessInstanceIds: [...], pending: boolean}`. Auth: `trigger_message` (`"all"`). Returns `503` with `Retry-After` when `MessageSubscriptions` is not yet ready (resume gate). The old RPC-style `POST /triggers/messages` was **removed**, not aliased. |
| `POST` | `/signals/{signal_name}/trigger` | **Implemented** — broadcast a named signal. Body: empty or `{}`; any `payload` key is silently ignored. Signals carry no payload and no correlation — pure broadcast by signal name. Response body: `{signalId, signalName, deliveries: [{processInstanceId, flowNodeInstanceId}], startedProcessInstanceIds: [string], pending: boolean}`. Auth: `trigger_signal` (`"all"`). Returns `503` with `Retry-After: 5` when `SignalSubscriptions` is not yet ready (resume gate). The old RPC-style `POST /triggers/signals` was **removed**, not aliased. |
| `PUT` | `/user-tasks/{fniId}/finish` | Complete with result |
| `PUT` | `/user-tasks/{fniId}/cancel` | |
| `PUT` | `/process-instances/{id}/abort` | |
| `PUT` | `/process-instances/{id}/retry` | **Retry**: retries a terminal PI. Gated by `retry_process_instance` claim (`own` / `all`). Supports optional version migration and checkpoint reset. 204 on success. |
| `DELETE` | `/process-instances/{id}` | **Delete**: deletes the PI and its FNIs. Gated by `delete_process_instance` claim (`own` = started-by-self only, `all` = any PI). Running PIs cannot be deleted — caller must abort first. Terminal PIs only |
| `POST` | `/timer-events/{flow_node_instance_id}/trigger` | **Implemented** — manually fire a waiting timer FNI (Intermediate Catch or Boundary). Body: empty or `{}`. Response: `{triggered: true}`. Auth: lane claim for the FNI's lane (or `zeeky_boogie_doog`). No dedicated trigger claim. See [§10.1.5](#1015-timer-event-manual-trigger-timereventcontroller--implemented) |
| `POST` | `/escalations/{escalation_code}/trigger` | **Implemented** — inject an escalation into waiting catchers engine-wide (Event Subprocess starts and waiting Escalation Boundary FNIs). Body: empty or `{}`; any `payload` key is silently ignored. Response: `{escalationCode, deliveries: [{processInstanceId, flowNodeInstanceId}], pending: false}`. Auth: boolean `trigger_escalation` via `Validation.check_claim/3`. Empty `deliveries` is success. Not a modeled BPMN throw; no pending table; unmatched PIs are not marked `:escalated`. See [§10.1.6](#1016-escalation-trigger-escalationcontroller--implemented) |

#### 10.1.2 DMN Decision catalog & evaluation (`DecisionController` — implemented)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/decisions` | List all deployed decisions (latest active version per definition). Any authenticated user |
| `GET` | `/decisions/{model_id}` | Show decision metadata (optional `?includeXml=true`). 404 if not found |
| `GET` | `/decisions/{model_id}/versions` | Version history (optional `?includeXml=true`). 404 if not found |
| `POST` | `/decisions` | Deploy DMN definitions (atomic batch). Body: `{sources: ["<xml>", ...]}`. Requires `deploy_dmn` claim. Returns 201 with `{deployed: [...]}`. 409 `decision_version_exists` on duplicate |
| `POST` | `/decisions/{model_id}/evaluate` | Ad-hoc DMN evaluation. Body: `{input: {...}, decisionModelId?, includeUnmatchedDetails?}`. Returns `EvaluationResult` with trace. 404 if definition or decision not found, 422 on evaluation errors |
| `POST` | `/decisions/{model_id}/versions/{version}/evaluate` | Version-pinned evaluation. Same body/response as `/evaluate` but bypasses latest-version resolution. Useful for regression testing and A/B comparison. 404 if definition or version not found |
| `POST` | `/decisions/{model_id}/services/{service_id}/evaluate` | Evaluate a Decision Service. Body: `{ "input": { ... } }`. 200: `ServiceEvaluationResult` — `{ "serviceId", "serviceName", "outputs": { "<outputVariable>": <value>, ... }, "trace": { "decisions": [...] }, "evaluatedAt", "durationMicroseconds" }` (camelCase via `Wire.camelize_keys/1` on `ServiceEvaluationResult.to_json_map/1`). 404: `service_not_found`, `decision_definition_not_found`. 422: `dmn_evaluation_error`, `missing_required_input` (same evaluation error surface as `/evaluate`) |
| `PUT` | `/decisions/{model_id}/enable` | Enable a decision definition (204). Requires `deploy_dmn` claim |
| `PUT` | `/decisions/{model_id}/disable` | Disable a decision definition (204). Requires `deploy_dmn` claim |
| `DELETE` | `/decisions/{model_id}` | Undeploy (soft-delete all versions, 204). Requires `delete_dmn` claim |
| `DELETE` | `/decisions/{model_id}/versions/{version}` | Soft-delete a specific version (204). Requires `delete_dmn` claim |

**Authorization claims:** `deploy_dmn` for deploy/enable/disable, `delete_dmn` for undeploy/version-delete. Enforced in `BfwEngine.Api` (not in `DecisionController`). Admin override (`zeeky_boogie_doog`) bypasses all claim checks.

#### 10.1.3 Message triggers (`MessageController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `POST` | `/messages/{message_name}/trigger` | Trigger a named message | `trigger_message` (`"all"`) |

Body: `{payload?, correlation?}`. Returns `200` with `{messageId, correlationValue, deliveries, startedProcessInstanceIds, pending}`. Errors: `403` (missing `trigger_message` claim), `413` (payload too large), `503` (subscription registry not ready during resume — includes `Retry-After`). Controller: `BfwEngineWeb.Http.MessageController` (`apps/api_web/lib/bfw_engine_web/http/controllers/message_controller.ex`). Delegates to `BfwEngine.Api.publish_message/5` (claim check + `MessagePublisher`).

#### 10.1.4 Signal triggers (`SignalController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `POST` | `/signals/{signal_name}/trigger` | Broadcast a named signal | `trigger_signal` (`"all"`) |

Body: empty or `{}`; any `payload` key is silently ignored. Returns `200` with `{signalId, signalName, deliveries, startedProcessInstanceIds, pending}`. Errors: `403` (missing `trigger_signal` claim), `503` (subscription registry not ready during resume — includes `Retry-After: 5`). Signals carry no payload and no correlation — they are pure broadcast by signal name. Controller: `BfwEngineWeb.Http.SignalController` (`apps/api_web/lib/bfw_engine_web/http/controllers/signal_controller.ex`). Delegates to `BfwEngine.Api.publish_signal/3` (claim check + `SignalPublisher`).

#### 10.1.5 Timer event manual trigger (`TimerEventController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `POST` | `/timer-events/{flow_node_instance_id}/trigger` | Manually fire a waiting timer FNI | `lane:<name>="write"` for the FNI's lane, or laneless FNI, or `zeeky_boogie_doog`. `"read"` / `observe_all` → **403**; invisible → **404** |

Body: empty or `{}`. Returns `200` with `{triggered: true}`. Errors: `404` (FNI not found or lane-invisible — indistinguishable), `403` (visible but not writable: `"read"` or `observe_all`), `409` (FNI not active/waiting or already terminal), `422` (`not_a_timer_event` — FNI is not an Intermediate Catch or Boundary timer event). Boolean `true` is not a write alias. Controller: `BfwEngineWeb.Http.TimerEventController` (`apps/api_web/lib/bfw_engine_web/http/controllers/timer_event_controller.ex`). Delegates to `BfwEngine.Api.trigger_timer_event/3`.

TypeScript client: `EventClient.triggerTimer(flowNodeInstanceId)` in `@elraptorus/bfw_engine_client` (`packages/js/client/src/rest/event-client.ts`). SDK type: `TimerTriggerResult` (`packages/js/sdk/src/types/trigger.ts`).

#### 10.1.6 Escalation trigger (`EscalationController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `POST` | `/escalations/{escalation_code}/trigger` | Inject an escalation into waiting catchers engine-wide | `trigger_escalation` (boolean) |

Body: empty or `{}`; any `payload` key is silently ignored. Escalations carry no payload. Returns `200` with `{escalationCode, deliveries: [{processInstanceId, flowNodeInstanceId}], pending: false}`. Empty `deliveries` is success (no waiter matched). Errors: `403` (missing / false `trigger_escalation`), `422` (`escalation_code_blank` or `escalation_code_too_long`). This is a debugger/operator inject, not a modeled BPMN throw: it delivers to matching waiting Escalation Boundary FNIs and Event Subprocess starts on every running PI. It does not walk the parent chain, does not insert pending rows, and does not mark unmatched PIs `:escalated`. Do not revive `POST /triggers/escalations`. Controller: `BfwEngineWeb.Http.EscalationController`. Delegates to `BfwEngine.Api.trigger_escalation/3`.

TypeScript client: `EventClient.triggerEscalation(escalationCode)` in `@elraptorus/bfw_engine_client`. SDK type: `EscalationTriggerResult`. Plugin facade: `facade.escalations.publish.(escalation_code)` with `skip_claims: true`.

#### 10.1.7 Ad-hoc subprocess control (`AdhocSubprocessController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `GET` | `/adhoc-subprocesses/{id}/activities` | List enabled/performed inner activities | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/activities/{activity_id}/activate` | Activate an inner activity | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/complete` | Signal completion | `manage_adhoc_subprocess` |
| `GET` | `/adhoc-subprocesses/{id}/status` | Query runtime status | `manage_adhoc_subprocess` |

The `{id}` path parameter is the **child process instance ID** spawned by the ad-hoc subprocess handler — not the parent PI or the shell FNI ID.

**List activities** returns `{data: [{id, name, type, enabled, performedCount, activeCount}]}`. **Activate** returns `{flowNodeInstanceId: "..."}`. **Complete** returns `{completed: true}`. **Status** returns `{activeCount, performedActivities: [id], enabledActivities: [id], completionSignaled: boolean}`.

Errors: `404` (PI not found or activity not found in scope), `422` (`not_adhoc_subprocess` — PI is not an ad-hoc subprocess child), `409` (`adhoc_already_completing` — completion already signaled), `403` (missing claim), `500` (`dispatch_failed`). Controller: `BfwEngineWeb.Http.AdhocSubprocessController` (`apps/api_web/lib/bfw_engine_web/http/controllers/adhoc_subprocess_controller.ex`). Delegates to `BfwEngine.Api.{get_adhoc_enabled_activities,activate_adhoc_activity,complete_adhoc_subprocess,get_adhoc_status}/3-4`.

Plugin facade: `facade.adhoc_subprocesses.{get_enabled_activities,activate_activity,complete,get_status}` — same operations with `skip_claims: true`.

**Async Service Tasks:** completion is **plugin-side** only — call `engine_facade.finish_async_service_task/2` or `fail_async_service_task/3` (or the matching `BfwEngine.Api.*` facade actions). There is **no** first-class `POST /async-flow-nodes/...` REST surface and **no** GraphQL mutation.

##### 10.1.1 Payload size limits

Every endpoint that accepts a user-supplied JSON payload — `payload` on `POST /processes/{model_id}/start`, `/messages/{message_name}/trigger`, `/user-tasks/{fniId}/finish`, and async completion payloads on the **plugin facade** — enforces the engine-wide `BFE_TOKEN_MAX_BYTES` cap (default `65536` = 64 KiB) on the **canonicalized JSON byte size** of the payload field, measured at request parse time before any engine-side work. On `POST /processes/{model_id}/start`, `payload` (= the PI's `started_with_context`) uses the same cap. `PUT /user-tasks/{fniId}/finish` checks the `result` field (`PayloadCapPlug` with `field: "result"`, then `BfwEngine.Api.finish_user_task/4`); HTTP 413 leaves the FNI `waiting`. `/signals/{signal_name}/trigger` and `/escalations/{escalation_code}/trigger` carry no payload — any `payload` key in the body is silently ignored, and PayloadCap is not invoked. There is no `POST /triggers/*` RPC surface (those routes were removed). GraphQL is query-only and does not accept command payloads.

On overflow the endpoint returns **HTTP 413 Payload Too Large** with a structured body:

```json
{
  "error": "payload_too_large",
  "field": "payload",          // or "correlation", etc.
  "size": 123456,
  "limit": 65536
}
```

No engine state changes on a 413 — the PI is not started, the message is not published, the User Task is not completed, the async Service Task FNI stays in `waiting`. API-caller retries with a smaller payload are first-class.

The cap is enforced identically whether the payload comes through REST (above) or through the plugin facade (`BfwEngine.Api.*` / `engine_facade`). Overflow on REST returns HTTP 413 as shown; overflow on the facade returns `{:error, :payload_too_large, %{field, size, limit}}` with the same shape. There are no GraphQL mutations, so GraphQL never carries a command payload.

Body-level limits (the total HTTP request byte size) are enforced separately by the upstream Phoenix endpoint at `max_body_bytes = 4 * BFE_TOKEN_MAX_BYTES` by default (headroom for JSON envelope + multiple payload-bearing fields on a single request) and return the standard Phoenix `413` before the per-field cap check runs.

### 10.2 GraphQL surface (query-only)

GraphQL is **strictly query-only**. It is the primary surface for everything Studio (and every other external consumer) needs beyond trigger-style REST: paginated lists, deep fetches, and structured access to the parsed Process Model itself. Two complementary blocks: **persistence-backed resources** (§10.2.1) and the **Process Model graph** (§10.2.2).

All commands (start, finish, abort, retry, deploy, purge, trigger) are REST and/or the plugin facade. Real-time event delivery is Phoenix Channels (§10.3), not GraphQL subscriptions. See also the consumer guide [`guides/api/graphql-reference.md`](../guides/api/graphql-reference.md).

#### 10.2.1 Persistence-backed resources

AshGraphql auto-emits queries for each Ash resource with filter/sort/page/sparse-fields. Every list query uses **offset pagination** (`paginate_with: :offset`) and returns a `PageOf<Resource>` type containing `results`, `count`, `hasNextPage`, `hasPreviousPage`, `pageNumber`, `lastPage`, and `limit`.

```graphql
type Query {
  processes(filter, sort, limit, offset)              : PageOfProcess
  processVersions(filter, sort, limit, offset)        : PageOfProcessVersion
  processInstances(filter, sort, limit, offset)       : PageOfProcessInstance
  flowNodeInstances(filter, sort, limit, offset)      : PageOfFlowNodeInstance
  decisionDefinitions(filter, sort, limit, offset)    : PageOfDecisionDefinition
  decisionVersions(filter, sort, limit, offset)       : PageOfDecisionVersion
  dataObjectValues(filter, sort, limit, offset)       : PageOfDataObjectValue
  dataObjectHistory(filter, sort, limit, offset)      : PageOfDataObjectHistoryEntry
}
```

There are **no GraphQL mutations or subscriptions**. Commands stay on REST (and the plugin facade). Real-time events use Phoenix Channels (§10.3).

Filter grammar is AshGraphql's built-in (type-safe, composable expressions including `ilike` for case-insensitive substring matching on string fields). **PI/FNI `state` and FNI `flowNodeType` are strings** — filter with `"running"` / `"waiting"` / `"user_task"`, not GraphQL enums. Sort accepts multiple keys with `field` (SCREAMING_SNAKE_CASE enum) and `order` (`ASC`/`DESC`). Pagination is offset-based: `limit`/`offset`.

All response field names use **camelCase** (Absinthe `LanguageConventions` adapter default). Query field names accept both camelCase and snake_case.

**Pagination vs complexity.** AshGraphql scores a paginated list as `limit × (selected result fields + page metadata)`. The Studio debugger's `dataObjectValues(limit: 500)` snapshot scores 6500; the default `BFE_GRAPHQL_MAX_COMPLEXITY` is **10000** so that query is admitted. Nested `processInstance { dataObjectValues { ... } }` (no `limit` argument) is scored as `child_complexity + 1` and is not the same query. See [configuration.md](./configuration.md).

##### 10.2.1.1 `ProcessInstance.finalTokens` calculation

`ProcessInstance` exposes a derived `finalTokens: [Json!]` field instead of the eliminated `final_token` column. The calc, implemented as an Ash `calculation` with a direct SQL projection for list queries:

- **`state = :finished`** → returns the ordered list of `output_token` values from every FNI where `flow_node_type = 'endEvent'` AND `state = 'finished'`, ordered by `finished_at`. For a linear process this is a singleton list. For a parallel-End process with N tokens reaching different End Events, the list has N entries in the order they terminated.
- **`state ∈ {:fatal, :aborted, :error, :escalated, :compensated}`** → returns `null`. These states did not produce a BPMN-sense "result"; treating any captured payload as a "final token" conflates error-path data with success results.
- **`state = :running`** → returns `null` (PI has not terminated).

Resolver implementation: for `ProcessInstance.finalTokens` on a single-PI query, a direct Ecto subquery joined to `flow_node_instances`. For list queries (`processInstances(...)`), Dataloader batches End-Event lookups across all requested PIs into one query and projects the calc into the parent-row results, so the N+1 problem does not materialize. Studio dashboards requesting `processInstances { id state finalTokens }` across 1000 PIs issue exactly two queries total.

#### 10.2.2 Process Model graph

Alongside the persistence resources, the GraphQL layer (`api_web`) projects the parsed `BfwEngine.BPMN.Model.*` AST into GraphQL as a **first-class structured graph** so external consumers can read the deployed process definition without re-parsing XML. These types are **not** Ash-resource-backed; their resolvers read `BfwEngine.BPMN.ModelCache` (warm path: ETS lookup; cold path: DB-backed loader — see the cold-cache pitfall below). Defined in `apps/api_web/lib/bfw_engine_web/graphql/model_types.ex`, `model_resolvers.ex`, and `dataloader/model_cache_source.ex`; wired into `schema.ex`.

**As-built shape** (abbreviated — the full struct-aligned field list lives in `model_types.ex` and is enforced at compile time, see below):

```graphql
# --- Process Model graph (resolved from ModelCache, not Ash) ---

enum FlowNodeType {
  TASK
  USER_TASK
  SERVICE_TASK
  MANUAL_TASK
  SCRIPT_TASK
  BUSINESS_RULE_TASK
  SEND_TASK
  RECEIVE_TASK
  CALL_ACTIVITY
  SUB_PROCESS               # embedded / event / ad-hoc / transaction — distinguished by SubProcessNode booleans, not by enum value
  EXCLUSIVE_GATEWAY
  PARALLEL_GATEWAY
  INCLUSIVE_GATEWAY
  EVENT_BASED_GATEWAY
  COMPLEX_GATEWAY
  START_EVENT
  END_EVENT
  INTERMEDIATE_CATCH_EVENT
  INTERMEDIATE_THROW_EVENT
  BOUNDARY_EVENT
  UNKNOWN
}
# 21 values total, one per FlowNodeData.* struct (D-1 = A). Event *kind*
# (message/timer/error/...) is NOT folded into this enum — it is exposed
# separately via the `EventDefinition` union on the five event-position
# node types (StartEventNode, EndEventNode, IntermediateCatchEventNode,
# IntermediateThrowEventNode, BoundaryEventNode).

union EventDefinition =
    NoneEventDefinition
  | MessageEventDefinition
  | SignalEventDefinition
  | TimerEventDefinition
  | ErrorEventDefinition
  | EscalationEventDefinition
  | ConditionalEventDefinition
  | CompensationEventDefinition
  | TerminateEventDefinition
  | CancelEventDefinition
  | LinkEventDefinition
# 11 members, one per EventDefinition.* struct.

interface FlowNode {
  id: ID!
  name: String
  type: FlowNodeType!
  incoming: [String!]!             # sequence-flow ids, document order
  outgoing: [String!]!             # sequence-flow ids, document order
  boundaryEventRefs: [String!]!
  dataContracts: [DataContract!]!
  dataInputAssociations: [DataAssociation!]!
  dataOutputAssociations: [DataAssociation!]!
  multiInstance: MultiInstance
  standardLoop: StandardLoop
  isForCompensation: Boolean!
  documentation: String
  parentSubProcessId: String        # only populated on ProcessModel.allFlowNodes entries (D-2 = C)
}

# One concrete type per FlowNodeData.* struct (21 total). Selected examples:

type ServiceTaskNode implements FlowNode {
  implementation: String
  payloadContract: JSON
  resultContract: JSON
  httpUrl: String
  httpMethod: String
  httpBody: String                  # FEEL source
  httpAuthHeader: String            # FEEL source
  httpResponseHeaders: String       # FEEL source
  inMappings: [Mapping!]!
  outMappings: [Mapping!]!
  # ...common FlowNode fields above
}

type CallActivityNode implements FlowNode {
  calledElement: String
  startEventId: String
  calledProcessVersion: String
  inMappings: [Mapping!]!
  outMappings: [Mapping!]!
}

type SubProcessNode implements FlowNode {
  triggeredByEvent: Boolean!
  isTransaction: Boolean!
  isAdHoc: Boolean!
  adhocOrdering: MultiInstanceOrdering
  cancelRemainingInstances: Boolean!
  flowNodes: [FlowNode!]!           # recurses — nested tree, D-2 option B half
  sequenceFlows: [SequenceFlow!]!
  dataObjects: [DataObjectModel!]!
  dataObjectReferences: [DataObjectReferenceModel!]!
}

type StartEventNode implements FlowNode {
  eventDefinition: EventDefinition!
  resultContract: JSON
  isInterrupting: Boolean!
}

# ... one concrete type per remaining FlowNodeData.* struct: TaskNode,
# UserTaskNode, ManualTaskNode, ScriptTaskNode, BusinessRuleTaskNode,
# SendTaskNode, ReceiveTaskNode, ExclusiveGatewayNode, ParallelGatewayNode,
# InclusiveGatewayNode, EventBasedGatewayNode, ComplexGatewayNode,
# EndEventNode, IntermediateCatchEventNode, IntermediateThrowEventNode,
# BoundaryEventNode, UnknownNode.

type ProcessModel {
  id: ID!
  name: String
  version: String
  isExecutable: Boolean!
  isTransactionScope: Boolean!
  isAdHocScope: Boolean!
  correlationKey: String            # FEEL source

  "Top-level flow nodes only; nested subprocess scopes recurse via SubProcessNode.flowNodes."
  flowNodes: [FlowNode!]!

  "Every flow node across every scope, flattened, each carrying parentSubProcessId. What FlowNodeInstance.flowNode resolves against (D-2 = C)."
  allFlowNodes: [FlowNode!]!

  sequenceFlows: [SequenceFlow!]!
  lanes: [Lane!]!
  dataObjects: [DataObjectModel!]!
  dataObjectReferences: [DataObjectReferenceModel!]!
  associations: [Association!]!
  extensions: [BpmnExtension!]!

  "Copied from the parent Definitions — catalogs are not on Model.Process but are exposed here so clients do not need a second type."
  definitionsId: ID
  messages: [MessageDefinition!]!
  signals: [SignalDefinition!]!
  errors: [ErrorDefinition!]!
  escalations: [EscalationDefinition!]!
  linterScores: [LinterRulesetScore!]!
}

# --- Existing Ash-backed types gain Model hooks ---

extend type ProcessVersion {
  processModel: ProcessModel        # ← resolver: ModelCache.fetch(self.id), pick the executable Process
}

extend type FlowNodeInstance {
  flowNode: FlowNode                # ← resolver: ModelCache.fetch(pi.process_version_id) → processModel.allFlowNodes[self.flowNodeId]
  processVersion: ProcessVersion    # ← resolver: PI → process_version_id → Ash.get
}
```

**Implementation invariants (as built):**

- **Declarative field table, not typespec introspection (D-3 = B).** `BfwEngineWeb.Graphql.ModelSchema.FieldTable` registers every `BfwEngine.BPMN.Model.*` struct field as `exposed` (with the GraphQL field it maps to) or `excluded` (with a reason). `FieldTable.verify!/0` runs at the top of `model_types.ex` and **fails the build** if any struct key is neither mapped nor excluded — this is the enforcement mechanism, not automatic derivation from `@type t`. A field added to an Elixir struct without a matching `FieldTable` entry is a compile error, not a silent gap. `verify!/0` does **not** inspect Absinthe types: a row marked `exposed` that was never declared as a GraphQL field would still compile. `BfwEngineWeb.Graphql.ModelGraphIntrospectionTest` closes that hole by asserting every `exposed` atom exists on the mapped Absinthe type (`FieldTable.graphql_identifier/1`) and that every `Model.*` struct module is registered.
- **`:json` scalar is reused, not redefined.** AshGraphql already registers a `:json` scalar on the same schema; `model_types.ex` imports it rather than declaring a second one (Absinthe requires globally unique type identifiers).
- **Compiled artifacts are never exposed.** `DataContract.compiled_schema`, the four `MultiInstance.compiled_*` fields, `StandardLoop.compiled_loop_condition`, the two `SubProcess.*_compiled` fields, `Process.inclusive_join_analyses`, `Process.complex_region_analyses`, and `Definitions.raw_xml` are all `excluded` entries in the `FieldTable` — enforced by `BfwEngineWeb.Graphql.ModelGraphIntrospectionTest`, which scans the entire introspected schema for any identifier matching `compiled`, `precompiled`, or `raw_xml` and fails if one is reachable.
- **Dataloader batching.** `BfwEngineWeb.Graphql.Dataloader.ModelCacheSource` batches `ModelCache.fetch/1` calls keyed by `process_version_id` via `Dataloader.KV`, registered in `Schema.context/1` with `get_policy: :tuples` (required — the default `:raise_on_error` would turn the ordinary `{:error, :not_found}` cold-cache-miss outcome into a raised exception). All `FlowNodeInstance.flowNode` resolutions in one request that share a `process_version_id` — e.g. every FNI of one PI, the Studio-debugger access pattern — collapse to exactly one `ModelCache.fetch/1` call, verified in `graphql_model_graph_wp7_test.exs` via `:telemetry` instrumentation on `[:bfw_engine, :model_cache, :fetch]`.
- **`process_instance_id` / `flow_node_id` reload guard.** AshGraphql only loads attributes the client's query selected. `ModelResolvers.ensure_required_ids_loaded/2` reloads these two `FlowNodeInstance` attributes via `Ash.load/3` whenever the resolver needs them but the client didn't select them as scalar fields — otherwise the resolver would crash on `%Ash.NotLoaded{}`.
- **Authorization.** No new policy layer — resolvers read the persistence parent (`ProcessVersion` or, via `FlowNodeInstance → ProcessInstance`, the owning PI) through `Ash.get/2` with the request's `actor`, so the same Ash policies that gate `ProcessVersion`/`FlowNodeInstance`/`ProcessInstance` visibility gate the attached Model data. A caller who cannot see the `FlowNodeInstance` at all gets `flowNode`/`processVersion` as unreachable fields on a `null` parent — never a separate authorization error. `ProcessVersion` read policy is `actor_present()`: any authenticated JWT can read `processModel` (the same bar as `bpmnXml`); an unauthenticated caller is rejected at the HTTP plug (401/403) before Absinthe runs.
- **`ProcessVersion.bpmnXml` is retained.** The raw XML remains the authoritative persistent form and the required input for `bpmn-js` diagram rendering. `processModel` is additive, not a replacement.

**Studio-debugger example query** (single round-trip for the full debugger view; mirrors `getProcessInstanceWithModel()` in the TS client):

```graphql
query OpenDebugger($piId: ID!) {
  getProcessInstance(id: $piId) {
    id
    state
    startedAt
    finishedAt
    startedWithContext
    finalTokens
    processVersion {
      id
      version
      bpmnXml
      processModel { id correlationKey }
    }
    flowNodeInstances {
      id
      state
      startedAt
      finishedAt
      inputToken
      outputToken
      typeProperties
      errorInfo
      flowNode {
        id
        type
        name
        ... on UserTaskNode      { formSchema resultContract }
        ... on ServiceTaskNode   { implementation httpUrl httpMethod }
        ... on CallActivityNode  { calledElement startEventId calledProcessVersion inMappings { source target } outMappings { source target } }
        ... on SendTaskNode      { messageRef inMappings { source target } outMappings { source target } }
      }
    }
    dataObjectValues { dataObjectId flowNodeInstanceId value createdAt }
  }
}
```

Real-time FNI updates use the WebSocket API (Phoenix Channels), not GraphQL subscriptions.

**TypeScript client support (WP-6).** `packages/js/client/src/graphql/query-builder.ts` accepts a `SelectionField[]` — a recursive union type (`packages/js/sdk/src/graphql/model-fields.ts`) that can express nested selections and inline fragments (`{ name: 'flowNode', on: { UserTaskNode: [...], ServiceTaskNode: [...] } }`), not just flat `string[]`. The SDK ships `buildFlowNodeSelection(depth)` and `buildProcessModelSelection(depth)` helpers that pre-build the canonical debugger-shaped selection (default recursion depth 4 for nested `SubProcessNode.flowNodes`), consumed via `GraphqlClient.getProcessVersionWithModel()`, `GraphqlClient.getFlowNodeInstanceWithModel()`, and `GraphqlClient.getProcessInstanceWithModel()`.

`TaskNode`, `ParallelGatewayNode`, and `EventBasedGatewayNode` have no extra fields beyond the `FlowNode` interface. `buildFlowNodeSelection` omits those types from `on`, and the query builder skips any remaining empty `... on Type { }` fragment. Empty selection sets are invalid GraphQL; Absinthe reports `syntax error before: '}'`.

#### Retention (no REST purge)

Manual purge is **not** a live REST or GraphQL field. Process-instance trees are hard-deleted by `mix bfw.retention.purge`. Ordinary `DELETE /process-instances/{id}` remains **soft-delete of one PI + its FNIs** and still omits `cancelled`. GraphQL is query-only.

See [configuration.md](./configuration.md) and [database.md](../guides/operations/database.md).

### 10.3 WebSocket (Phoenix Channels)

- **Implemented** topic shape: `engine:*`, `process_instance:<id>`, `user_tasks:pending`. Planned but not yet wired: `process:<model_id>`.
- Subscriptions require the same JWT as HTTP.
- `process_instance:<id>` join enforces §5.1 PI visibility. Dispatch-time filtering (`EventDelivery.should_deliver?/2`) then applies the FNI lane gate and, on `engine:events`, §5.1 PI visibility from emit-time stamps (`startedById`, `hasLanelessFlowNode`, `laneNames`). `user_tasks:pending` is a lane-filtered inbox of `UserTaskCreated` / `UserTaskFinished`.
- GraphQL has **no** subscriptions (and no mutations). Real-time events use the Phoenix Channel push model. GraphQL FNI **reads** remain PI-scoped (§5.2); WebSocket FNI dispatch is the stricter lane gate.

### 10.4 OpenAPI + GraphQL SDL

- OpenAPI 3.x served at `GET /api/openapi`; Swagger UI at `GET /` (path to the spec configured in the plug). All three devtools routes are gated by `BFE_DEVTOOLS_ENABLED` (defaults to `false` in prod). The OpenAPI spec can be individually re-enabled via `BFE_EXPOSE_OPENAPI_SPEC=true`.
- GraphQL Playground at `/admin/graphiql` (devtools-only, pre-loaded with example query tabs). SDL export endpoint is not currently implemented.
- Client generation is CI-driven ([plugins.md](./plugins.md) — SDK packages).

### 10.5 Deprecation headers (RFC 8594)

When a REST endpoint is superseded by a newer route, the old route is **not removed immediately**. Instead, it continues to function but carries standard deprecation headers so clients can discover and migrate to the replacement at their own pace:

| Header | Value | Purpose |
|--------|-------|---------|
| `Deprecation` | `true` | Signals the endpoint is deprecated (RFC 8594) |
| `Link` | `<{replacement_url}>; rel="successor-version"` | Points the client to the replacement route |
| `Sunset` | HTTP-date per RFC 7231 (optional) | When set, indicates the date after which the deprecated route may be removed |

**Mechanism:** A `DeprecationPlug` reads `conn.private[:deprecated]` (set via `plug :put_private` or a per-route plug option on the deprecated scope). The value is a map:

```elixir
%{
  successor: "/processes/{model_id}/start",   # required — replacement path
  sunset: ~U[2027-01-01 00:00:00Z]      # optional — removal date
}
```

If `conn.private[:deprecated]` is present, the plug injects the three headers (two if no `sunset`). If absent, it is a no-op. The plug sits in the `:authenticated` pipeline so all authenticated routes gain automatic deprecation support.

**What deprecation headers are _not_:** They do not enforce migration. They do not block requests. They do not version-negotiate. Actual migration guidance (changelogs, upgrade scripts, client library updates) is documentation work, not engine work.

**OpenAPI:** Deprecated endpoints carry `deprecated: true` in `spec.yaml`. The `Link` header is documented as a response header on each deprecated operation.

### 10.6 API-vs-Core boundary rule

Every Ash action (mutation) maps to exactly one Core access point. API layers never mutate persistence directly — they go through Core, which emits telemetry → peripheral_persistence updates the DB.

### 10.7 Soft-delete filtering

All soft-deletable Ash resources (`ProcessInstance`, `FlowNodeInstance`, `ProcessVersion`, `DecisionVersion`) enforce `filter expr(deleted == false)` on their primary `:read` action. This guarantees that deleted records are invisible through every external surface — GraphQL, REST, WebSocket, Ash calculations, and plugin queries — without requiring per-endpoint filtering.

There is no `:read_including_deleted` bypass action. The invariant is: **a version cannot be soft-deleted while non-terminal PIs exist on it.** Both `DELETE /processes/{model_id}/versions/{version}` and `DELETE /processes/{model_id}` (undeploy) reject with `409 active_instances_exist` when non-terminal PIs are found on the target version(s). If a version is deleted despite this guard (e.g. manual DB manipulation), resume fails with a generic not-found error — the engine never leaks the fact that a record is soft-deleted.

### 10.8 Validation layering (Api facade as authoritative enforcement)

Authorization and business-rule validation follow a strict three-layer model:

| Layer | Responsibility | Must NOT do |
|---|---|---|
| **REST controllers** (`apps/api_web/lib/bfw_engine_web/http/controllers/`) | Parse HTTP (path params, body, identity from conn assigns); call `BfwEngine.Api.*`; map error tuples to HTTP status codes via `ErrorResponse` | Claim checks, lane checks, existence/state guards, direct `Ash.*` or publisher calls |
| **`BfwEngine.Api` facade** (`apps/api_facade/lib/bfw_engine/api.ex`) | **Single authoritative enforcement point** for all claim checks, lane access, and business rules (existence, type, state, enabled, active PIs) before delegating to Core or publishers | HTTP-specific concerns |
| **PI `:gen_statem`** (`ProcessInstance`) | Minimal defensive race-condition guards only (e.g. FNI no longer active in in-memory state at call time) | Claim or lane enforcement |

Claim and lane helpers live in `BfwEngine.Api.Validation` (`apps/api_facade/lib/bfw_engine/api/validation.ex`). See [authorization.md](./authorization.md) §13 for function signatures and claim-to-facade mapping.

#### `skip_claims` opt-out

Every Api function that enforces claims accepts `opts \\ []`. When `skip_claims: true` is passed, **claim checks and lane checks are skipped**; business rule checks always apply. The plugin loader (`apps/peripheral_plugins/lib/bfw_engine/plugins/loader.ex`) passes `skip_claims: true` when constructing all plugin facade closures so in-BEAM plugins operate inside the trust boundary without per-plugin JWT claim configuration. REST controllers never pass this flag.

```elixir
# Plugin closure — claims skipped, business rules still enforced
BfwEngine.Api.abort_process_instance(id, reason, identity, skip_claims: true)

# REST path — full claim + lane enforcement
BfwEngine.Api.abort_process_instance(id, reason, identity)
```

### `PUT /process-instances/:id/retry` (implemented)

Retries a terminal (fatal, aborted, or error) process instance. The Api facade (`BfwEngine.Api.retry_process_instance/3`) validates prerequisites (PI existence, terminal state, not running, version resolution) then delegates tree analysis and execution to Core (`Execution.retry_process_instance/1`).

**Request body** (all fields optional):

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Target version to migrate to. Omit = same version. `"latest"` = most recent enabled version of the same process. |
| `resetToFlowNodeInstanceId` | UUID | Flow node instance to use as a reset checkpoint. FNIs downstream of the checkpoint are deleted. |

**Auth claim:** `retry_process_instance` (value: `own` or `all`). Ownership is checked against the targeted PI's `started_by.id`.

**Response codes:**

| Code | Error code | When |
|------|-----------|------|
| 204 | — | Retry initiated successfully |
| 403 | `forbidden` | Caller lacks `retry_process_instance` claim |
| 404 | `not_found` | PI not found (or soft-deleted) |
| 404 | `version_not_found` | Target version not found |
| 404 | `flow_node_instance_not_found` | Checkpoint FNI not found on this PI |
| 422 | `process_instance_not_retriable` | PI is not in a retriable terminal state (`fatal`, `aborted`, or `error`) |
| 422 | `root_process_instance_not_terminal` | Ancestor PI in the tree is not terminal |
| 422 | `version_disabled` | Target process is disabled |
| 422 | `version_migration_incompatible` | Active FNIs reference flow nodes absent in target model |
| 422 | `retry_checkpoint_is_ebg_loser` | Checkpoint FNI was interrupted by an Event-Based Gateway race — retry at the gateway or upstream instead |
| 422 | `retry_checkpoint_is_join_gateway` | Checkpoint FNI is a parallel/inclusive join gateway — retry at the fork or upstream instead |
| 422 | `retry_checkpoint_is_non_retryable` | Checkpoint FNI was interrupted by a BPMN flow mechanism (boundary cancellation, EBG, Terminate/Error End Event) — retry without a checkpoint or select a different flow node |
| 503 | `engine_at_capacity` | `BFE_MAX_CONCURRENT_PIS` limit reached |

**Version resolution flow:** The Api layer resolves the version using `CalledElementResolver`:
- No `version` → same version (`pi_data.process_version_id`)
- `"latest"` → `resolve_latest_version_for_process_id/1` via the PI's process UUID
- Specific version string → `resolve_specific_version/2` via the PI's process model ID

## Message, signal, and timer-schedule REST

These routes are implemented on `BfwEngineWeb.Http.Router`, documented in OpenAPI, and covered by integration tests. The TypeScript client methods match these paths. There is no `x-engine-status: planned` marker in the spec.

### `POST /messages/{message_name}/trigger` — **implemented**

Triggers a named message event. Correlates with waiting `ReceiveTask`, `IntermediateCatchEvent`, or `MessageBoundaryEvent` instances; starts PIs via Message Start Events when no catch subscription matches (catch-wins-over-Start). See [§10.1.3](#1013-message-triggers-messagecontroller--implemented).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `payload` | object | no | Message payload (defaults to `{}`) |
| `correlation` | string | no | Correlation value for targeted delivery |

Auth claim: `trigger_message` (`"all"`).

The legacy RPC-style `POST /triggers/messages` was **removed**. Use this resource-oriented route.

### `POST /signals/{signal_name}/trigger` — **implemented**

Triggers a named signal event. Broadcasts to all waiting signal catchers. See [§10.1.4](#1014-signal-triggers-signalcontroller--implemented).

Body: empty or `{}`. Any `payload` key is silently ignored.

Auth claim: `trigger_signal` (`"all"`).

Returns `503` with `Retry-After: 5` when signal subscriptions are not ready (engine resuming).

Response: `{ signalId, signalName, deliveries: [{processInstanceId, flowNodeInstanceId}], startedProcessInstanceIds: [string], pending: boolean }`.

Note: Signals carry no payload and no correlation — they are pure broadcast by signal name.

The legacy RPC-style `POST /triggers/signals` was **removed**. Use this resource-oriented route.

### Timer Schedule Management

Endpoints for managing Timer Start Event schedules. These schedules are created automatically when a process version with timer start events is deployed, and removed when the version is soft-deleted.

| Method | Path | Action | Auth claim |
|--------|------|--------|------------|
| `GET` | `/timer-schedules` | List all schedules | `deploy_bpmn` |
| `GET` | `/timer-schedules/:id` | Get single schedule | `deploy_bpmn` |
| `PUT` | `/timer-schedules/:id/enable` | Re-enable a disabled schedule | `deploy_bpmn` |
| `PUT` | `/timer-schedules/:id/disable` | Disable a schedule | `deploy_bpmn` |

Query params for `GET /timer-schedules`: `?processVersionId=...`, `?enabled=true|false`

Response shape for list:
```json
{
  "data": [{
    "id": "uuid",
    "processModelId": "order-process",
    "processVersionId": "uuid",
    "flowNodeId": "TimerStart_1",
    "kind": "cycle",
    "isoSpec": "R/PT1H",
    "enabled": true,
    "nextFireAt": "2026-06-02T10:00:00Z",
    "lastTriggeredAt": "2026-06-02T09:00:00Z",
    "cycleTotal": null,
    "cycleRemaining": null
  }]
}
```

Controller: `BfwEngineWeb.Http.TimerScheduleController` (`apps/api_web/lib/bfw_engine_web/http/controllers/timer_schedule_controller.ex`)

Delegates to `BfwEngine.Timers.StartEventManager` for all operations.

## BPMN Runtime Facade Functions (claim-enforced)

These `BfwEngine.Api` functions centralize claim checks previously scattered across REST controllers. All accept `opts \\ []` with optional `skip_claims: true` (see §10.8).

| Function | Signature | Claim / access | Business rules |
|----------|-----------|----------------|----------------|
| `deploy_bpmn/3` | `([map()], Identity.t(), keyword())` | `deploy_bpmn` | Parse, validate, linter gate, uniqueness check, atomic deploy |
| `start_process_instance/3` | `(map(), Identity.t(), keyword())` | Lane access (start event lane) | Process enabled, start event resolution, lane check |
| `update_process_enabled/3` | `(struct(), boolean(), keyword())` | `deploy_bpmn` | — |
| `delete_process_version/4` | `(model_id, version_string, Identity.t(), keyword())` | `delete_bpmn` | No active PIs on version |
| `undeploy_process/3` | `(model_id, Identity.t(), keyword())` | `delete_bpmn` | No active PIs; ≥1 active version |
| `abort_process_instance/4` | `(id, reason, Identity.t(), keyword())` | `abort_process_instance` (scoped) | PI exists |
| `retry_process_instance/4` | `(id, retry_opts, Identity.t(), keyword())` | `retry_process_instance` (scoped) | Terminal state, version resolution |
| `delete_process_instance/3` | `(id, Identity.t(), keyword())` | `delete_process_instance` (scoped) | Terminal state only |
| `publish_message/5` | `(message_name, payload, correlation, Identity.t(), keyword())` | `trigger_message` (`"all"`) | Subscription readiness, delegates to `MessagePublisher` |
| `publish_signal/3` | `(signal_name, Identity.t(), keyword())` | `trigger_signal` (`"all"`) | Subscription readiness, delegates to `SignalPublisher` |
| `trigger_timer_event/3` | `(flow_node_instance_id, Identity.t(), keyword())` | Lane access (`check_lane_access/3`) | Timer FNI type, active/waiting state |
| `finish_user_task/4` | `(fni_id, result, Identity.t(), keyword())` | Lane access | User/manual task type, waiting state |
| `cancel_user_task/4` | `(fni_id, reason, Identity.t(), keyword())` | Lane access | User/manual task type, waiting state |

`persist_deploy_batch/3` remains available for plugins that supply pre-parsed data. Creates inside the transaction use `return_notifications?: true`; `Ash.Notifier.notify/1` runs after commit so Ash does not warn about missed notifications.

`trigger_timer_event/3` validation pipeline: `get_flow_node_instance/1` → `validate_timer_event_type/1` (position + `event_type: "timer"`) → `validate_fni_active_or_waiting/1` → `Validation.check_lane_access/3` → `Execution.trigger_timer_event/2`.

## Ad-hoc Subprocess Facade Functions

| Function | Signature | Required Claim | Notes |
|----------|-----------|----------------|-------|
| `get_adhoc_enabled_activities/3` | `(pi_id, Identity.t(), keyword())` | `manage_adhoc_subprocess` | Returns list of inner activities with enabled/performed status |
| `activate_adhoc_activity/4` | `(pi_id, flow_node_id, Identity.t(), keyword())` | `manage_adhoc_subprocess` | Activates an inner activity, returns `{:ok, %{flow_node_instance_id: id}}` |
| `complete_adhoc_subprocess/3` | `(pi_id, Identity.t(), keyword())` | `manage_adhoc_subprocess` | Signals completion; child PI finishes when all active FNIs complete |
| `get_adhoc_status/3` | `(pi_id, Identity.t(), keyword())` | `manage_adhoc_subprocess` | Returns active count, performed/enabled activities, completion signal state |

The `pi_id` parameter is the **child PI ID** — the process instance spawned by the ad-hoc subprocess handler, not the parent PI.

Plugin facade closures (`facade.adhoc_subprocesses.*`) call the same functions with `skip_claims: true`.

## DMN (Decision) Facade Functions

The `BfwEngine.Api` module exposes DMN operations via the same facade convergence pattern as BPMN. DMN deploy/enable/disable/undeploy claim checks (`deploy_dmn`, `delete_dmn`) are enforced in the facade via `BfwEngine.Api.Validation` (not in `DecisionController`).

| Function | Signature | Purpose |
|----------|-----------|---------|
| `deploy_dmn/3` | `([map()], map(), keyword())` | Deploy DMN definitions. Parse, validate, atomic deploy. Claim: `deploy_dmn`. |
| `deploy_dmn_batch/3` | `([map()], map(), keyword())` | Lower-level: atomic batch deploy of pre-parsed DMN models. Upserts `DecisionDefinition`, creates `DecisionVersion`, primes `DMN.ModelCache`. Used by plugins with pre-parsed data. |
| `evaluate_decision/3` | `(String.t(), map(), keyword()) :: {:ok, EvaluationResult.t()} \| {:error, term()}` | Resolves latest version via `DecisionResolver`, fetches from cache, evaluates, returns `EvaluationResult` with trace. |
| `evaluate_decision_service/4` | `(String.t(), String.t(), map(), keyword()) :: {:ok, ServiceEvaluationResult.t()} \| {:error, term()}` | Evaluate a Decision Service. Resolves latest version, evaluates the service sub-DRG, returns only output decision results. |
| `list_decision_definitions/1` | `(keyword()) :: {:ok, list()} \| {:error, term()}` | List all decision definitions. |
| `get_decision_by_model_id/1` | `(String.t()) :: {:ok, struct()} \| :not_found` | Find a decision definition by its `decision_definition_id`. |
| `get_latest_decision_version/1` | `(binary()) :: {:ok, struct()} \| {:error, :no_active_version}` | Latest non-deleted version for a definition. |
| `find_decision_version_by_key/2` | `(binary(), String.t()) :: {:ok, struct()} \| :not_found` | Find a version by definition ID + version string. |
| `list_decision_versions_for_definition/2` | `(binary(), keyword()) :: list()` | All non-deleted versions, newest-first. |
| `update_decision_enabled/2` | `(struct(), boolean()) :: {:ok, struct()} \| {:error, term()}` | Toggle `enabled` flag. |
| `soft_delete_decision_version/3` | `(struct(), map(), keyword())` | Low-level soft-delete a decision version (claim check included). |
| `delete_decision_version/4` | `(model_id, version_string, Identity.t(), keyword())` | Full orchestration: lookup + claim check + soft-delete. Claim: `delete_dmn`. |
| `undeploy_decision/3` | `(model_id, Identity.t(), keyword())` | Full orchestration: lookup + claim check + soft-delete all versions. Claim: `delete_dmn`. |
| `find_latest_decision_versions_by_definition_ids/1` | `([binary()]) :: %{binary() => struct()}` | Bulk-fetch latest version per definition. |

`deploy_dmn_batch/3` mirrors the BPMN `persist_deploy_batch/3` pattern: it runs inside a `Repo.transaction`, rolls back on duplicate version conflicts, primes the `DMN.ModelCache` after a successful commit, and flushes Ash notifications after commit.

`evaluate_decision/3` accepts options:
- `:decision_model_id` — target a specific decision within a multi-decision DMN model
- `:include_unmatched_details` — include full traces for rules that did not match

## Design Decisions Affecting the API

### Conditional Flows Only on Split Gateways

`<bpmn:conditionExpression>` is honored only on sequence flows whose source is a Split Gateway. Conditions on outgoing flows of any other element type are silently ignored at runtime. This affects BPMN parser behavior and the TypeScript SDK's BPMN model documentation. See [expressions.md](expressions.md).

### `BfwEngine.Api` Convergence Layer

All external entry points (REST controllers, GraphQL resolvers, WebSocket channel handlers, external plugins) converge through a single `BfwEngine.Api` facade module, located in the `api_facade` umbrella app (`apps/api_facade/lib/bfw_engine/api.ex`). This module wraps Ash domain reads/writes (with `authorize?: false` for internal calls), **enforces all claim and lane authorization** via `BfwEngine.Api.Validation`, validates business rules, and delegates runtime operations to `BfwEngine.Execution`. REST controllers are thin HTTP adapters — they call `BfwEngine.Api.*` and map error tuples; they never perform claim checks or call Ash/publishers directly. Plugins call the same facade functions with `skip_claims: true`. A static enforcement test (`apps/api_web/test/architecture/d51_enforcement_test.exs`) scans all `api_web` lib files and fails if any direct `Ash.*` call is found.

The TypeScript SDK types are designed against the `BfwEngine.Api` facade surface.
