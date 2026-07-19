---
title: Evil Engine — API Design
parent_document: ../ImplementationPlan.md
---

<!-- Extracted from ImplementationPlan.md §10 (API design). -->

## 10. API design

### Snake/camelCase Contract

All REST responses and WebSocket event envelopes use **camelCase** structural keys (for example `processInstanceId`, `processModelId`, `createdAt`). GraphQL already uses camelCase via AshGraphql, so all three API surfaces now speak the same convention.

**Opaque payload boundary rule:** user-payload subtrees are passed through unchanged. The encoder converts structural field names but does **not** recurse into fields designated as opaque (for example `payload`, `inputToken`, `outputToken`, `startedWithContext`, `startedBy`, `deployer`, `claims`, `typeProperties`, `errorInfo`, `violations`). This means keys inside a process token's `payload` are exactly what the process author set — the engine never rewrites them. Engine-structural error fields like `failures` and `conflicts` are **not** opaque — their nested keys (e.g. `processModelId`, `rulesetFailures`) are camelCased normally.

The boundary is enforced in `EvilEngine.Types.Wire` (`apps/core_types/lib/evil_engine/types/wire.ex`). Jason.Encoder implementations for all event structs live in `apps/core_events/lib/evil_engine/events/json_encoders.ex`.

### Centralized Error Responses

All REST error responses go through `EvilEngineWeb.Http.ErrorResponse` (`apps/api_web/lib/evil_engine_web/http/error_response.ex`). This guarantees every error body:

1. Contains at least `error` (snake_case code) and `message` fields
2. Has all structural keys camelCased via `Wire.camelize_keys/1`
3. Uses field names matching the SDK's `ErrorMapper` expectations

Controllers use `render_error/4` (or `/5` with extras). Plugs that halt the conn before Phoenix.Controller is available use `render_error_halt/4` (or `/5`). The `api_auth` plug (`EvilEngine.Auth.Plug`) is in a separate umbrella app and uses its own `send_resp/3` calls — it cannot depend on `api_web`.

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

JWT bearer is required by default for authenticated routes (`../ImplementationPlan.md §13`). **Public** routes (`GET /health`, `GET /info`, `GET /metrics`) bypass auth.

The umbrella currently mounts **process-catalog** REST handlers at the **root** path (e.g. `POST /processes`), not under `/api/v1`. **GraphQL** is at `POST /api/v1/graphql`. OpenAPI JSON is at `GET /api/openapi`.

#### 10.1.0 Process catalog & lifecycle (`ProcessController` — implemented)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/processes` | List all deployed processes (latest active version per process, no XML). Fully undeployed processes are excluded. Any authenticated user |
| `GET` | `/processes/{model_id}` | Process metadata (optional `?includeXml=true` for latest version's BPMN XML) |
| `GET` | `/processes/{model_id}/versions` | Version history (optional `?includeXml=true` per version) |
| `POST` | `/processes` | Deploy one or more BPMN definitions in a single **atomic batch**. Body: `{ "sources": ["<xml>", ...] }` (JSON array of BPMN XML strings). Each source must carry `<evil:version>`. On deploy, `Process.enabled` is synced to the BPMN `isExecutable` flag. When the linter-score gate is enabled ([configuration.md](./configuration.md) §14.5), each source is checked; on failure, returns `422` with `error: "linter_gate_failed"` and `failures`. On success, returns `201` with `deployed: [...]` |
| `POST` | `/processes/{model_id}/start` | Start a new PI from the latest non-deleted version of an enabled process. Body: `{startEventId?, payload?, context?, businessKey?}`. `context` is an optional opaque JSON object stored as `started_with_context` on the PI, accessible as `context.*` in FEEL expressions. When omitted, context is empty. Returns `201` with `{process_instance_id, process_model_id, version, state}`. Errors: `404` (not found / no active version), `403` (disabled), `422` (ambiguous start event / not found), `413` (payload too large), `429` with `Retry-After` when the global start rate limit is exceeded (`EVIL_PI_START_RATE_LIMIT` > 0; Layer 2), `503` with `Retry-After` when `EVIL_MAX_CONCURRENT_PIS` is exceeded (Layer 1), `401` (unauthenticated / expired JWT) |
| `PUT` | `/processes/{model_id}/enable` | Enable the process (204 No Content) |
| `PUT` | `/processes/{model_id}/disable` | Disable the process (204 No Content) |
| `DELETE` | `/processes/{model_id}` | **Undeploy** a process: deletes all versions. Rejects with 409 if non-terminal PIs exist on any version. Requires `delete_bpmn=true`. Returns 404 for unknown or already-undeployed processes |
| `DELETE` | `/processes/{model_id}/versions/{version}` | **Delete** a version: marks the matching version as deleted (204 No Content). Rejects with 409 if non-terminal PIs exist on the version |

#### 10.1.0.1 Public `/health`, `/metrics`, process-start back-pressure, and deprecation

**`GET /health`** — Liveness/readiness; **no auth**. JSON includes a `load` field: `"normal"`, `"elevated"`, or `"critical"`, derived from active PI count vs. `EVIL_MAX_CONCURRENT_PIS` at 70% / 90% thresholds when the cap is finite; always `"normal"` when the cap is `:infinity`. This aligns with the `evil_engine.process_instance.capacity.ratio` last-value metric and overload signaling.

**`GET /metrics`** — Prometheus text exposition (public; **no auth**). Served by `api_web` when `EVIL_METRICS_ENABLED` is `true` (default). Metric definitions live in `EvilEngine.Telemetry.Metrics` (`peripheral_telemetry`); scrape output is plain text per Prometheus exposition format. When metrics are disabled, returns **404** with JSON `{"error":"metrics_disabled"}`.

**`POST /processes/{model_id}/start` — `503` / `429`** — When the dynamic supervisor rejects a new PI because `EVIL_MAX_CONCURRENT_PIS` is reached, the facade returns `{:error, :engine_at_capacity, %{active, limit}}` and the controller responds with **503 Service Unavailable**, a `Retry-After` header, and a structured JSON body. When `EVIL_PI_START_RATE_LIMIT` is greater than zero and the ETS token-bucket plug (`RateLimitPlug` on the authenticated pipeline) is exhausted, the controller responds with **429 Too Many Requests** and `Retry-After`. Env vars and defaults: [configuration.md](./configuration.md).

**Deprecation headers (RFC 8594)** — Routes mark themselves by setting `conn.private[:deprecated]` to `%{successor: path, sunset: optional_datetime}` (via `plug :put_private` or scope options). `DeprecationPlug` injects `Deprecation`, `Link` (`rel="successor-version"`), and optional `Sunset` on responses. Full rules: [§10.5](#105-deprecation-headers-rfc-8594).

Additional trigger-style paths in the table below remain **specified** for v1 parity with `ImplementationPlan.md` §10; wire them through GraphQL (or future controllers) when not yet present on `EvilEngineWeb.Http.Router`.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness/readiness; **no auth**; JSON includes `load` (`normal` / `elevated` / `critical` when `EVIL_MAX_CONCURRENT_PIS` is finite) |
| `GET` | `/info` | Engine id/name/version/uptime/feature flags; **no auth** |
| `GET` | `/metrics` | Prometheus text exposition; **no auth** when enabled (`EVIL_METRICS_ENABLED`, default `true`). Returns `404` with `{"error":"metrics_disabled"}` when disabled |
| `GET` | `/stats` | JSON snapshot of current engine state (see [observability.md](./observability.md) §11.2) |
| `POST` | `/processes/{model_id}/start` | Start a new PI (body: startEventId?, payload?, context?, businessKey?). `context` is stored as `started_with_context`; empty when omitted. Always resolves to the latest non-deleted version (`process_versions.deleted=false`) of an enabled process |
| `POST` | `/process-instances/{id}/restart` | New PI with original inputs |
| `POST` | `/messages/{message_name}/trigger` | **Implemented** — publish a named message. Body: `{payload?, correlation?}` — message name is the path parameter. `correlation` is optional; if absent, the published `correlation_value` defaults to `:none` ([routing.md](./routing.md) §3.5.2). Routing follows [routing.md](./routing.md) §3.5.3: every subscription whose `(message_name, expected_correlation_value)` matches receives a copy (broadcast-within-key). If **any** subscription matches, Message Start Events are suppressed (catch-wins-over-Start); if none match and at least one deployed process has a Message Start Event with matching name, one PI is started per such process. If none match and no Start Event matches, the message is held in `pending_messages` for `EVIL_MESSAGE_PENDING_TTL` ([configuration.md](./configuration.md) §14.3). Response body: `{messageId, correlationValue, deliveries: [{processInstanceId, flowNodeInstanceId}], startedProcessInstanceIds: [...], pending: boolean}`. Auth: `trigger_message` (`"all"`). Returns `503` with `Retry-After` when `MessageSubscriptions` is not yet ready (resume gate). Supersedes the RPC-style `POST /triggers/messages` |
| `POST` | `/signals/{signal_name}/trigger` | **Implemented** — broadcast a named signal. Body: empty or `{}`; any `payload` key is silently ignored. Signals carry no payload and no correlation — pure broadcast by signal name. Response body: `{signalId, signalName, deliveries: [{processInstanceId, flowNodeInstanceId}], startedProcessInstanceIds: [string], pending: boolean}`. Auth: `trigger_signal` (`"all"`). Returns `503` with `Retry-After: 5` when `SignalSubscriptions` is not yet ready (resume gate). Supersedes the RPC-style `POST /triggers/signals` |
| `POST` | `/triggers/messages` | **Deprecated** — superseded by `POST /messages/{message_name}/trigger`. Same semantics; message name was in the request body `{name, payload, correlation?}` |
| `POST` | `/triggers/signals` | **Deprecated** — superseded by `POST /signals/{signal_name}/trigger`. Same semantics; signal name was in the request body `{name, payload?}` |
| `POST` | `/triggers/escalations` | Publish escalation |
| `PUT` | `/user-tasks/{fniId}/finish` | Complete with result |
| `PUT` | `/user-tasks/{fniId}/cancel` | |
| `PUT` | `/process-instances/{id}/abort` | |
| `PUT` | `/process-instances/{id}/retry` | **Retry**: retries a terminal PI. Gated by `retry_process_instance` claim (`own` / `all`). Supports optional version migration and checkpoint reset. 204 on success. |
| `DELETE` | `/process-instances/{id}` | **Delete**: deletes the PI and its FNIs. Gated by `delete_process_instance` claim (`own` = started-by-self only, `all` = any PI). Running PIs cannot be deleted — caller must abort first. Terminal PIs only |
| `POST` | `/timer-events/{flow_node_instance_id}/trigger` | **Implemented** — manually fire a waiting timer FNI (Intermediate Catch or Boundary). Body: empty or `{}`. Response: `{triggered: true}`. Auth: lane claim for the FNI's lane (or `zeeky_boogie_doog`). No dedicated trigger claim. See [§10.1.5](#1015-timer-event-manual-trigger-timereventcontroller--implemented) |

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

**Authorization claims:** `deploy_dmn` for deploy/enable/disable, `delete_dmn` for undeploy/version-delete. Enforced in `EvilEngine.Api` (not in `DecisionController`). Admin override (`zeeky_boogie_doog`) bypasses all claim checks.

#### 10.1.3 Message triggers (`MessageController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `POST` | `/messages/{message_name}/trigger` | Trigger a named message | `trigger_message` (`"all"`) |

Body: `{payload?, correlation?}`. Returns `200` with `{messageId, correlationValue, deliveries, startedProcessInstanceIds, pending}`. Errors: `403` (missing `trigger_message` claim), `413` (payload too large), `503` (subscription registry not ready during resume — includes `Retry-After`). Controller: `EvilEngineWeb.Http.MessageController` (`apps/api_web/lib/evil_engine_web/http/controllers/message_controller.ex`). Delegates to `EvilEngine.Api.publish_message/5` (claim check + `MessagePublisher`).

#### 10.1.4 Signal triggers (`SignalController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `POST` | `/signals/{signal_name}/trigger` | Broadcast a named signal | `trigger_signal` (`"all"`) |

Body: empty or `{}`; any `payload` key is silently ignored. Returns `200` with `{signalId, signalName, deliveries, startedProcessInstanceIds, pending}`. Errors: `403` (missing `trigger_signal` claim), `503` (subscription registry not ready during resume — includes `Retry-After: 5`). Signals carry no payload and no correlation — they are pure broadcast by signal name. Controller: `EvilEngineWeb.Http.SignalController` (`apps/api_web/lib/evil_engine_web/http/controllers/signal_controller.ex`). Delegates to `EvilEngine.Api.publish_signal/3` (claim check + `SignalPublisher`).

#### 10.1.5 Timer event manual trigger (`TimerEventController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `POST` | `/timer-events/{flow_node_instance_id}/trigger` | Manually fire a waiting timer FNI | Lane access only (`lane:<name>` or `zeeky_boogie_doog`) |

Body: empty or `{}`. Returns `200` with `{triggered: true}`. Errors: `404` (FNI not found or lane-invisible — indistinguishable), `403` (lane claim missing), `409` (FNI not active/waiting or already terminal), `422` (`not_a_timer_event` — FNI is not an Intermediate Catch or Boundary timer event). Controller: `EvilEngineWeb.Http.TimerEventController` (`apps/api_web/lib/evil_engine_web/http/controllers/timer_event_controller.ex`). Delegates to `EvilEngine.Api.trigger_timer_event/3`.

TypeScript client: `EventClient.triggerTimer(flowNodeInstanceId)` in `@elraptorus/daemonengine_client` (`packages/js/client/src/rest/event-client.ts`). SDK type: `TimerTriggerResult` (`packages/js/sdk/src/types/trigger.ts`).

#### 10.1.6 Ad-hoc subprocess control (`AdhocSubprocessController` — implemented)

| Method | Path | Purpose | Required Claim |
|---|---|---|---|
| `GET` | `/adhoc-subprocesses/{id}/activities` | List enabled/performed inner activities | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/activities/{activity_id}/activate` | Activate an inner activity | `manage_adhoc_subprocess` |
| `POST` | `/adhoc-subprocesses/{id}/complete` | Signal completion | `manage_adhoc_subprocess` |
| `GET` | `/adhoc-subprocesses/{id}/status` | Query runtime status | `manage_adhoc_subprocess` |

The `{id}` path parameter is the **child process instance ID** spawned by the ad-hoc subprocess handler — not the parent PI or the shell FNI ID.

**List activities** returns `{data: [{id, name, type, enabled, performedCount, activeCount}]}`. **Activate** returns `{flowNodeInstanceId: "..."}`. **Complete** returns `{completed: true}`. **Status** returns `{activeCount, performedActivities: [id], enabledActivities: [id], completionSignaled: boolean}`.

Errors: `404` (PI not found or activity not found in scope), `422` (`not_adhoc_subprocess` — PI is not an ad-hoc subprocess child), `409` (`adhoc_already_completing` — completion already signaled), `403` (missing claim), `500` (`dispatch_failed`). Controller: `EvilEngineWeb.Http.AdhocSubprocessController` (`apps/api_web/lib/evil_engine_web/http/controllers/adhoc_subprocess_controller.ex`). Delegates to `EvilEngine.Api.{get_adhoc_enabled_activities,activate_adhoc_activity,complete_adhoc_subprocess,get_adhoc_status}/3-4`.

Plugin facade: `facade.adhoc_subprocesses.{get_enabled_activities,activate_activity,complete,get_status}` — same operations with `skip_claims: true`.

**Async Service Tasks:** completion is **plugin-side** only — call `engine_facade.finish_async_service_task/2` or `fail_async_service_task/3` (or the matching `EvilEngine.Api.*` actions / GraphQL mutations when exposed). There is **no** first-class `POST /async-flow-nodes/...` REST surface.

##### 10.1.1 Payload size limits

Every endpoint that accepts a user-supplied JSON payload — `payload` on `/processes/{model_id}/start`, `/messages/{message_name}/trigger`, `/triggers/messages` (deprecated), `/triggers/escalations`, `/user-tasks/{fniId}/finish`, and async completion payloads on the **facade / GraphQL** path — enforces the engine-wide `EVIL_TOKEN_MAX_BYTES` cap (default `65536` = 64 KiB) on the **canonicalized JSON byte size** of the payload field, measured at request parse time before any engine-side work. `startProcessInstance`'s `payload` (= the PI's `started_with_context`) uses the same cap. `/signals/{signal_name}/trigger` and `/triggers/signals` (deprecated) carry no payload — any `payload` key in the body is silently ignored.

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

The cap is enforced identically whether the payload comes through REST (above) or through the GraphQL Mutation fields in §10.2.1 (`startProcessInstance.input.payload`, `finishUserTask.input.result`, etc.). For GraphQL the same overflow produces a typed error in the response's `errors[]` with `extensions.code = "PAYLOAD_TOO_LARGE"` and the same `size`/`limit`/`field` shape.

Body-level limits (the total HTTP request byte size) are enforced separately by the upstream Phoenix endpoint at `max_body_bytes = 4 * EVIL_TOKEN_MAX_BYTES` by default (headroom for JSON envelope + multiple payload-bearing fields on a single request) and return the standard Phoenix `413` before the per-field cap check runs.

### 10.2 GraphQL surface (heavyweight querying)

GraphQL is the primary surface for everything Studio (and every other external consumer) needs beyond trigger-style REST: paginated lists, deep fetches, live subscriptions, and — — structured access to the parsed Process Model itself. Two complementary blocks: **persistence-backed resources** (§10.2.1) and the **Process Model graph** (§10.2.2).

#### 10.2.1 Persistence-backed resources

AshGraphql auto-emits queries for each Ash resource with filter/sort/page/sparse-fields. Every list query returns a `KeysetPageOf<Resource>` type containing `results`, `count`, `startKeyset`, and `endKeyset`. Note: AshGraphql does **not** expose a `hasNextPage` field — clients compute it as `results.length < count` (see common-pitfalls.md §P28).

```graphql
type Query {
  processes(filter, sort, first, after, last, before)         : KeysetPageOfProcess
  processVersions(filter, sort, first, after, last, before)   : KeysetPageOfProcessVersion
  processInstances(filter, sort, first, after, last, before)  : KeysetPageOfProcessInstance
  flowNodeInstances(filter, sort, first, after, last, before) : KeysetPageOfFlowNodeInstance
  decisionDefinitions(filter, sort, first, after, last, before) : KeysetPageOfDecisionDefinition
  decisionVersions(filter, sort, first, after, last, before)  : KeysetPageOfDecisionVersion
  dataObjectValues(filter, sort, first, after, last, before)  : KeysetPageOfDataObjectValue
  dataObjectHistory(filter, sort, first, after, last, before) : KeysetPageOfDataObjectHistoryEntry
}

type Mutation {
  startProcessInstance(input)                    : StartProcessInstanceResult
  finishUserTask(input)                          : FinishUserTaskResult
}

type Subscription {
  processInstance(id: ID!)                       : ProcessInstanceEvent!
  processInstances(processModelId: String)       : ProcessInstanceEvent!
  flowNodeInstance(id: ID!)                      : FlowNodeInstanceEvent!
  engineEvents(types: [EventType!])              : EngineEvent!
}
```

Filter grammar is AshGraphql's built-in (type-safe, composable expressions including `ilike` for case-insensitive substring matching on string fields). Sort accepts multiple keys with `field` (SCREAMING_SNAKE_CASE enum) and `order` (`ASC`/`DESC`). Pagination is keyset-based: `first`/`after` for forward paging, `last`/`before` for backward paging.

All response field names use **camelCase** (Absinthe `LanguageConventions` adapter default). Query field names accept both camelCase and snake_case.

##### 10.2.1.1 `ProcessInstance.finalTokens` calculation

`ProcessInstance` exposes a derived `finalTokens: [Json!]` field instead of the eliminated `final_token` column. The calc, implemented as an Ash `calculation` with a direct SQL projection for list queries:

- **`state = :finished`** → returns the ordered list of `output_token` values from every FNI where `flow_node_type = 'endEvent'` AND `state = 'finished'`, ordered by `finished_at`. For a linear process this is a singleton list. For a parallel-End process with N tokens reaching different End Events, the list has N entries in the order they terminated.
- **`state ∈ {:fatal, :aborted, :error, :escalated, :compensated}`** → returns `null`. These states did not produce a BPMN-sense "result"; treating any captured payload as a "final token" conflates error-path data with success results.
- **`state = :running`** → returns `null` (PI has not terminated).

Resolver implementation: for `ProcessInstance.finalTokens` on a single-PI query, a direct Ecto subquery joined to `flow_node_instances`. For list queries (`processInstances(...)`), Dataloader batches End-Event lookups across all requested PIs into one query and projects the calc into the parent-row results, so the N+1 problem does not materialize. Studio dashboards requesting `processInstances { id state finalTokens }` across 1000 PIs issue exactly two queries total.

#### 10.2.2 Process Model graph

Alongside the persistence resources, the GraphQL layer (`api_web`) projects the parsed `EvilEngine.BPMN.Model.*` AST into GraphQL as a **first-class structured graph** so external consumers can read the deployed process definition without re-parsing XML. These types are **not** Ash-resource-backed; their resolvers are ETS reads against `EvilEngine.BPMN.ModelCache.fetch/1`.

**Shape:**

```graphql
# --- Process Model graph (resolved from ModelCache, not Ash) ---

enum FlowNodeType {
  START_EVENT
  END_EVENT
  USER_TASK
  SERVICE_TASK
  MANUAL_TASK
  SCRIPT_TASK
  SEND_TASK
  RECEIVE_TASK
  CALL_ACTIVITY
  EMBEDDED_SUBPROCESS
  EVENT_SUBPROCESS
  EXCLUSIVE_GATEWAY
  PARALLEL_GATEWAY
  INCLUSIVE_GATEWAY
  EVENT_BASED_GATEWAY
  MESSAGE_CATCH_EVENT
  MESSAGE_THROW_EVENT
  SIGNAL_CATCH_EVENT
  SIGNAL_THROW_EVENT
  TIMER_CATCH_EVENT
  ESCALATION_EVENT
  ERROR_EVENT
  COMPENSATION_EVENT
  CONDITIONAL_CATCH_EVENT
  TERMINATE_EVENT
  # …one value per FlowNodeData.* struct
}

interface FlowNode {
  id: String!                      # bpmn:flowNode/@id
  type: FlowNodeType!
  name: String
  laneId: String
  incoming: [String!]!             # sequence-flow ids
  outgoing: [String!]!             # sequence-flow ids
  boundaryEvents: [BoundaryEvent!]!
  multiInstance: MultiInstance
  extensions: [BpmnExtension!]!    # raw `<bpmn:extensionElements>` content not otherwise modelled
}

# One concrete type per FlowNodeData.* Elixir struct. Examples:

type UserTaskNode implements FlowNode {
  formSchema: JSON                 # JSON Schema source (uncompiled)
  resultContract: JSON             # JSON Schema source
  assignableClaims: [String!]!
  # … all UserTask-specific fields
}

type ServiceTaskNode implements FlowNode {
  implementation: String!            # handler key (e.g. "http", plugin-registered key)
  http: HttpConfig
}

type CallActivityNode implements FlowNode {
  calledProcessModelId: String!
  inputMappings: [Mapping!]        # FEEL source/target pairs
  outputMappings: [Mapping!]       # FEEL source/target pairs
}

type MessageCatchEventNode implements FlowNode {
  messageName: String!
  correlationRetrievalExpression: String    # FEEL source
}

# … one concrete type per remaining FlowNodeData.* struct.

type ProcessModel {
  id: String!                      # bpmn:process/@id
  name: String
  version: String!                 # <evil:version>
  correlationKey: String           # FEEL source
  flowNodes: [FlowNode!]!
  sequenceFlows: [SequenceFlow!]!
  lanes: [Lane!]!
  dataObjects: [DataObjectModel!]! # BPMN-model Data Object declarations (NOT the runtime `DataObject` resource)
  linterScores: [LinterRulesetScore!]!
  extensions: [BpmnExtension!]!
}

# --- Existing Ash-backed types gain Model hooks ---

extend type ProcessVersion {
  bpmnXml: String!                 # kept — authoritative + required for bpmn-js diagram rendering
  processModel: ProcessModel!      # ← resolver: ModelCache.fetch(self.id)
}

extend type FlowNodeInstance {
  flowNode: FlowNode!              # ← resolver: ModelCache.fetch(pi.process_version_id).flowNodes[self.flowNodeId]
  processVersion: ProcessVersion!
}
```

**Implementation invariants:**

- **Compile-time derivation.** The Absinthe types (`ProcessModel`, `FlowNode`, every concrete `*Node`, `SequenceFlow`, `Lane`, `DataObjectModel`, `BoundaryEvent`, `MultiInstance`, `LinterRulesetScore`, `BpmnExtension`) are generated by a macro in `api_web/lib/evil_engine_web/graphql/model_schema.ex` from the `%EvilEngine.BPMN.Model.*{}` Elixir struct definitions. Adding a field to a struct **automatically** adds a GraphQL field on the next compile — the Model graph is guaranteed to stay in sync with the parser.
- **Zero re-parse, zero DB read.** Every resolver is an ETS lookup on `EvilEngine.BPMN.ModelCache`. No lazy parsing from `bpmn_xml` at query time.
- **Dataloader batching.** All `FlowNodeInstance.flowNode` resolutions within a single GraphQL request that share the same `process_version_id` — i.e. all FNIs of a single PI, which is the Studio-debugger access pattern — collapse to exactly one `ModelCache.fetch/1` call. Cross-PI list queries batch by distinct `process_version_id`.
- **Compiled artifacts are not exposed.** `DataContract.precompiled` (an `ExJsonSchema.Schema.Root.t()`) and compiled FEEL ASTs live only on the engine side. GraphQL exposes the **source** JSON Schema / FEEL strings — these are what clients need for display and for any client-side validation they choose to run.
- **Authorization.** Ash policies continue to gate access to the persistence parents (`ProcessVersion`, `FlowNodeInstance`, `ProcessInstance`). A caller authorized to read a given `ProcessVersion` or `FlowNodeInstance` is authorized to read the attached Model graph — Model data is identical for every authorized reader of that version.
- **`ProcessVersion.bpmnXml` is retained.** The raw XML is still the authoritative persistent form and still the input that `bpmn-js` / `diagram-js` need for diagram rendering. Clients are free to use either surface independently or in combination (typical Studio-debugger pattern: XML → diagram, Model graph → per-FNI detail panels and live overlays).

**Studio-debugger example query** (single round-trip for the full debugger view):

```graphql
query OpenDebugger($piId: ID!) {
  processInstance(id: $piId) {
    id state startedAt finishedAt startedWithContext
    finalTokens                   # derived via Ash calc — [Json!] for `finished` PIs, null otherwise
    processVersion {
      id version
      bpmnXml                       # fed to bpmn-js
      processModel { id correlationKey }
    }
    flowNodeInstances(first: 500) {
      edges { node {
        id state startedAt finishedAt inputToken outputToken typeProperties errorInfo
        flowNode {                  # ← Model data, resolved from ModelCache
          id type name laneId
          ... on UserTaskNode      { formSchema resultContract }
          ... on ServiceTaskNode   { implementation http { url method } }
          ... on CallActivityNode  { calledProcessModelId inputMappings { source target } outputMappings { source target } }
        }
      }}
    }
    activeTokens { id flowNodeInstanceId payload }
    dataObjectValues  { edges { node { dataObjectId flowNodeInstanceId value createdAt } } }
  }
}

subscription LiveFnis($piId: ID!) {
  flowNodeInstance(processInstanceId: $piId) { /* same shape; Studio applies deltas */ }
}
```

#### 10.2.3 Retention + manual purge

One operator-only mutation surfaces database housekeeping through GraphQL. Ordinary API JWTs never succeed on this field — a dedicated `:can_purge_audit_data` Ash Policy gates it; the built-in check verifies `purge_audit_data=true` in the caller's JWT claims ([authorization.md](./authorization.md) §4.1). Operators can layer additional policy checks (e.g. source-IP allowlist) on top without forking the mutation.

```graphql
enum TerminalPiState { FINISHED FATAL ABORTED ERROR ESCALATED COMPENSATED }

type PurgedRowCounts {
  processInstances:    Int!
  flowNodeInstances:   Int!
  dataObjectValues:    Int!
  dataObjectHistory:   Int!
  processInstanceEvents: Int!   # always zero since the built-in database sink was removed
}

type PurgeResult {
  dryRun:     Boolean!
  purgedPis:  Int!              # number of PIs that were (or would be) deleted
  rowCounts:  PurgedRowCounts!
  cutoff:     DateTime!
  statesPurged: [TerminalPiState!]!
  ranAt:      DateTime!
}

extend type Mutation {
  """
  Cascade-delete terminal PIs older than `olderThan` whose final state is in
  `states`. Runs inside a bounded batch (`batchSize`, default 500) per
  transaction; returns after the first batch even if more rows exist — the
  caller is expected to loop until `purgedPis == 0`.

  When `dryRun: true` (the default), returns the row counts that WOULD have
  been deleted without touching the DB. Policy guard: `:can_purge_audit_data`
  (admin-only — ).
  """
  purgeProcessInstances(
    olderThan: DateTime!
    states:    [TerminalPiState!]!
    dryRun:    Boolean = true
    batchSize: Int      = 500
  ): PurgeResult!
}
```

Semantic invariants:

- Only **terminal** PIs are eligible — `running` is never touched. Violations return a domain error.
- Purge is atomic-per-PI: a PI's `process_instances` row, all its `flow_node_instances`, `data_objects`, `data_object_writes`, and `process_instance_events` rows are deleted in one transaction. If any child PI (via Call Activity) is still `running`, the parent PI is skipped and reported in the response metadata.
- Every successful batch emits exactly one `Event.RetentionPurged{process_instance_id, purged_at, row_counts, policy_source: :manual_purge}` per purged PI on `EngineEventBus`, so audit-sink plugins can ship a "PI X was purged on Y" record to external long-term storage.
- Catalog rows (`processes`, `process_versions`) are **never** touched — their lifecycle is governed by version deletion.
- The same endpoint is also callable from the engine CLI as `evil_engine purge --older-than=<ISO8601> --states=finished,error [--dry-run] [--batch-size=500]`, which hits the GraphQL mutation internally with an operator-token.

### 10.3 WebSocket (Phoenix Channels)

- **Implemented** topic shape: `engine:*`, `process_instance:<id>`. Planned but not yet wired: `process:<model_id>`, `user_tasks:pending`.
- Subscriptions require the same JWT as HTTP.
- `process_instance:<id>` join enforces §5.1 PI visibility; events are lane-filtered at dispatch time.
- GraphQL Subscriptions are **not** currently implemented. Real-time events use the Phoenix Channel push model.

### 10.4 OpenAPI + GraphQL SDL

- OpenAPI 3.x served at `GET /api/openapi`; Swagger UI at `GET /` (path to the spec configured in the plug). All three devtools routes are gated by `EVIL_DEVTOOLS_ENABLED` (defaults to `false` in prod). The OpenAPI spec can be individually re-enabled via `EVIL_EXPOSE_OPENAPI_SPEC=true`.
- GraphQL Playground at `/admin/graphiql` (devtools-only, pre-loaded with example query tabs). SDL export endpoint is not currently implemented.
- Client generation is CI-driven ([plugins.md](./plugins.md) §9.5).

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

Every Ash action (mutation) maps to exactly one Core access point (`../ImplementationPlan.md §5.4`). API layers never mutate persistence directly — they go through Core, which emits telemetry → peripheral_persistence updates the DB.

### 10.7 Soft-delete filtering

All soft-deletable Ash resources (`ProcessInstance`, `FlowNodeInstance`, `ProcessVersion`, `DecisionVersion`) enforce `filter expr(deleted == false)` on their primary `:read` action. This guarantees that deleted records are invisible through every external surface — GraphQL, REST, WebSocket, Ash calculations, and plugin queries — without requiring per-endpoint filtering.

There is no `:read_including_deleted` bypass action. The invariant is: **a version cannot be soft-deleted while non-terminal PIs exist on it.** Both `DELETE /processes/{model_id}/versions/{version}` and `DELETE /processes/{model_id}` (undeploy) reject with `409 active_instances_exist` when non-terminal PIs are found on the target version(s). If a version is deleted despite this guard (e.g. manual DB manipulation), resume fails with a generic not-found error — the engine never leaks the fact that a record is soft-deleted.

### 10.8 Validation layering (Api facade as authoritative enforcement)

Authorization and business-rule validation follow a strict three-layer model:

| Layer | Responsibility | Must NOT do |
|---|---|---|
| **REST controllers** (`apps/api_web/lib/evil_engine_web/http/controllers/`) | Parse HTTP (path params, body, identity from conn assigns); call `EvilEngine.Api.*`; map error tuples to HTTP status codes via `ErrorResponse` | Claim checks, lane checks, existence/state guards, direct `Ash.*` or publisher calls |
| **`EvilEngine.Api` facade** (`apps/api_facade/lib/evil_engine/api.ex`) | **Single authoritative enforcement point** for all claim checks, lane access, and business rules (existence, type, state, enabled, active PIs) before delegating to Core or publishers | HTTP-specific concerns |
| **PI `:gen_statem`** (`ProcessInstance`) | Minimal defensive race-condition guards only (e.g. FNI no longer active in in-memory state at call time) | Claim or lane enforcement |

Claim and lane helpers live in `EvilEngine.Api.Validation` (`apps/api_facade/lib/evil_engine/api/validation.ex`). See [authorization.md](./authorization.md) §13 for function signatures and claim-to-facade mapping.

#### `skip_claims` opt-out

Every Api function that enforces claims accepts `opts \\ []`. When `skip_claims: true` is passed, **claim checks and lane checks are skipped**; business rule checks always apply. The plugin loader (`apps/peripheral_plugins/lib/evil_engine/plugins/loader.ex`) passes `skip_claims: true` when constructing all plugin facade closures so in-BEAM plugins operate inside the trust boundary without per-plugin JWT claim configuration. REST controllers never pass this flag.

```elixir
# Plugin closure — claims skipped, business rules still enforced
EvilEngine.Api.abort_process_instance(id, reason, identity, skip_claims: true)

# REST path — full claim + lane enforcement
EvilEngine.Api.abort_process_instance(id, reason, identity)
```

### `PUT /process-instances/:id/retry` (implemented)

Retries a terminal (fatal, aborted, or error) process instance. The Api facade (`EvilEngine.Api.retry_process_instance/3`) validates prerequisites (PI existence, terminal state, not running, version resolution) then delegates tree analysis and execution to Core (`Execution.retry_process_instance/1`).

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
| 503 | `engine_at_capacity` | `EVIL_MAX_CONCURRENT_PIS` limit reached |

**Version resolution flow:** The Api layer resolves the version using `CalledElementResolver`:
- No `version` → same version (`pi_data.process_version_id`)
- `"latest"` → `resolve_latest_version_for_process_id/1` via the PI's process UUID
- Specific version string → `resolve_specific_version/2` via the PI's process model ID

## Roadmap Endpoints (Phase 2)

The following endpoints are planned for Phase 2 and documented in the OpenAPI spec with `x-engine-status: planned`. The TypeScript client (`@elraptorus/daemonengine_client`) provides typed methods for these now; integration tests are pending until the engine routes are wired.

### `POST /messages/{message_name}/trigger` — **implemented**

Triggers a named message event. Correlates with waiting `ReceiveTask`, `IntermediateCatchEvent`, or `MessageBoundaryEvent` instances; starts PIs via Message Start Events when no catch subscription matches (catch-wins-over-Start). See [§10.1.3](#1013-message-triggers-messagecontroller--implemented).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `payload` | object | no | Message payload (defaults to `{}`) |
| `correlation` | string | no | Correlation value for targeted delivery |

Auth claim: `trigger_message` (`"all"`).

The legacy RPC-style `POST /triggers/messages` (body: `{name, payload, correlation?}`) is superseded by this resource-oriented route.

### `POST /signals/{signal_name}/trigger` — **implemented**

Triggers a named signal event. Broadcasts to all waiting signal catchers. See [§10.1.4](#1014-signal-triggers-signalcontroller--implemented).

Body: empty or `{}`. Any `payload` key is silently ignored.

Auth claim: `trigger_signal` (`"all"`).

Returns `503` with `Retry-After: 5` when signal subscriptions are not ready (engine resuming).

Response: `{ signalId, signalName, deliveries: [{processInstanceId, flowNodeInstanceId}], startedProcessInstanceIds: [string], pending: boolean }`.

Note: Signals carry no payload and no correlation — they are pure broadcast by signal name.

The legacy RPC-style `POST /triggers/signals` (body: `{name, payload?}`) is superseded by this resource-oriented route.

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

Controller: `EvilEngineWeb.Http.TimerScheduleController` (`apps/api_web/lib/evil_engine_web/http/controllers/timer_schedule_controller.ex`)

Delegates to `EvilEngine.Timers.StartEventManager` for all operations.

## BPMN Runtime Facade Functions (claim-enforced)

These `EvilEngine.Api` functions centralize claim checks previously scattered across REST controllers. All accept `opts \\ []` with optional `skip_claims: true` (see §10.8).

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

`persist_deploy_batch/3` remains available for plugins that supply pre-parsed data.

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

The `EvilEngine.Api` module exposes DMN operations via the same facade convergence pattern as BPMN. DMN deploy/enable/disable/undeploy claim checks (`deploy_dmn`, `delete_dmn`) are enforced in the facade via `EvilEngine.Api.Validation` (not in `DecisionController`).

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

`deploy_dmn_batch/3` mirrors the BPMN `persist_deploy_batch/3` pattern: it runs inside a `Repo.transaction`, rolls back on duplicate version conflicts, and primes the `DMN.ModelCache` after a successful commit.

`evaluate_decision/3` accepts options:
- `:decision_model_id` — target a specific decision within a multi-decision DMN model
- `:include_unmatched_details` — include full traces for rules that did not match

## Design Decisions Affecting the API

### Conditional Flows Only on Split Gateways

`<bpmn:conditionExpression>` is honored only on sequence flows whose source is a Split Gateway (Exclusive Gateway in v1; Inclusive Gateway in Phase 4). Conditions on outgoing flows of any other element type are silently ignored at runtime. This affects BPMN parser behavior and the TypeScript SDK's BPMN model documentation. See `docs/ImplementationPlan.md`.

### `EvilEngine.Api` Convergence Layer

All external entry points (REST controllers, GraphQL resolvers, WebSocket channel handlers, external plugins) converge through a single `EvilEngine.Api` facade module, located in the `api_facade` umbrella app (`apps/api_facade/lib/evil_engine/api.ex`). This module wraps Ash domain reads/writes (with `authorize?: false` for internal calls), **enforces all claim and lane authorization** via `EvilEngine.Api.Validation`, validates business rules, and delegates runtime operations to `EvilEngine.Execution`. REST controllers are thin HTTP adapters — they call `EvilEngine.Api.*` and map error tuples; they never perform claim checks or call Ash/publishers directly. Plugins call the same facade functions with `skip_claims: true`. A static enforcement test (`apps/api_web/test/architecture/d51_enforcement_test.exs`) scans all `api_web` lib files and fails if any direct `Ash.*` call is found.

The TypeScript SDK types are designed against the `EvilEngine.Api` facade surface.
