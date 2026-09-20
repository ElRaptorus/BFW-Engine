# Authorization

**Default-deny.** Every API endpoint, GraphQL query, and
WebSocket channel requires the caller to present a valid JWT bearer token
**unless** the endpoint is listed in the explicit exception list below.

Auth is **pluggable** via `@behaviour EvilEngine.Plugin.AuthProvider`.
The built-in JWT verifier (`JwtAuthProvider`) accepts HS256 (shared secret)
and RS256 / ES256 (asymmetric, via JWKS) and is the default. Plugins can
register a replacement provider during `on_load/1` via
`facade.register_auth_provider.(module)`. Only one provider may be active at
a time (first-writer wins).

## Dev / test override

Setting `TDE_AUTH_DISABLED=true` turns off JWT verification entirely. All
incoming requests are assigned a synthetic Identity with `id: "anonymous"`,
empty roles/groups, and all admin claims set to their **least-privileged**
defaults (`deploy_bpmn=false`, `abort_process_instance=none`, etc.).

The engine emits a `warn`-severity log line every 60 seconds while auth is
disabled, so a production deployment cannot run this way silently.

Integration tests use `TDE_AUTH_DISABLED=false` (the default) and mint JWTs
through the `engine_sdk`-shipped `MintTestToken` helper (§10).

---

## 2. Unauthenticated endpoints (exception list)

| Endpoint | Why open |
|---|---|
| `GET /health` | Liveness / readiness probes must work without credentials |
| `GET /info` | Returns Engine name and version |
| `GET /api/openapi` | Machine-readable OpenAPI 3.x spec for code generation (devtools-only; opt-in via `TDE_EXPOSE_OPENAPI_SPEC`) |
| `GET /` | Swagger UI (devtools-only) |
| `GET /admin/graphiql` | GraphQL Playground with example queries (devtools-only) |

**Devtools gating**: `GET /`, `GET /api/openapi`, and `GET /admin/graphiql` are
disabled in production by default (`TDE_DEVTOOLS_ENABLED` defaults to `false`
in prod, `true` in dev/test). The OpenAPI spec can be individually re-enabled
with `TDE_EXPOSE_OPENAPI_SPEC=true` for production CI pipelines that generate
client code.

Everything else — including `GET /stats` — requires a valid JWT.

---

## 3. Identity ↔ JWT mapping

The engine extracts a structured `Identity` from every verified JWT. The
mapping is fixed (not configurable in v1):

| Identity field | JWT claim | Required? | Notes |
|---|---|---|---|
| `id` | `sub` | **YES** — engine refuses tokens without `sub` | Unique caller identifier. Recorded on every auditable action, including `process_instances.started_by` |
| `name` | `name` | No | Display name; informational only |
| `email` | `email` | No | Informational only |
| `roles` | `roles` | No | Array of strings; matched against `<evil:assignees>` |
| `groups` | `groups` | No | Array of strings; matched against `<evil:assignees>` |
| `claims` | *(entire validated claim set)* | — | The full decoded JWT payload as a map. Available to plugins via `Identity.claims` for custom claim inspection on RestApiExtension endpoints |

### 3.1 Lane-claim mapping

BPMN `<bpmn:lane>` elements serve as the authorization scope for flow node
access. The engine matches lanes to JWT claims using a **namespaced claim
key**:

```
lane:<LANE_NAME> = "read" | "write"
```

Where `<LANE_NAME>` is the **user-facing `name` attribute** of the
`<bpmn:lane>` element, **not** its internal BPMN `id`. `"write"` observes
and acts. `"read"` observes only (GraphQL/WS). Absent, `true`, `false`,
and any other value are **none** (fail closed — HTTP 404 on writes).

**Namespace rationale:** a lane called `exp`, `iss`, `sub`, or `aud` would
collide with reserved JWT registered claims (RFC 7519 §4.1). The `lane:`
prefix eliminates this entirely. Example JWT payload:

```json
{
  "sub": "user-42",
  "name": "Jane Doe",
  "roles": ["reviewer"],
  "lane:Management": "write",
  "lane:Engineering": "write",
  "deploy_bpmn": true,
  "abort_process_instance": "own"
}
```

A caller with this JWT can interact with flow nodes residing on the
"Management" or "Engineering" lanes. Flow nodes on lanes they don't have —
or flow nodes with no lane — follow the rules in §5.

---

## 4. Claim dictionary

v1 has a small, finite set of engine-recognized claims. Anything outside this
list is ignored by the engine but preserved in `Identity.claims` for plugin
use.

### 4.1 Boolean claims

| Claim key | Type | Effect when `true` | Default if absent |
|---|---|---|---|
| `deploy_bpmn` | boolean | Allows: `POST /processes` (BPMN upload), `PUT /processes/{model_id}/enable`, `PUT /processes/{model_id}/disable` — all catalog-mutation operations | `false` |
| `delete_bpmn` | boolean | Allows: `DELETE /processes/{model_id}/versions/{version}`, `DELETE /processes/{model_id}` (version/process deletion ) | `false` |
| `purge_audit_data` | boolean | Unused. REST/CLI purge is not shipped. Mix `evil.retention.purge` is not JWT-gated | `false` |
| `lane:<name>` | `"read"` \| `"write"` | `"write"`: act on flow nodes on that lane. `"read"`: observe only. Boolean `true` is rejected. | none |
| `observe_all` | boolean | Unbounded read/observe of PIs, FNIs, data objects, and WS events. **Never** grants write. | `false` |
| `zeeky_boogie_doog` | boolean | Admin override: full read **and** write bypass. Distinct from `observe_all`. | `false` |
| `trigger_message` | `"none"`, `"all"` | Allows: Triggering any Message Event Instance on the Engine via `POST /messages/{message_name}/trigger`. | `"none"` |
| `trigger_signal` | `"none"`, `"all"` | Allows: Broadcasting any Signal on the Engine via `POST /signals/{signal_name}/trigger`. | `"none"` |
| `trigger_escalation` | boolean | Allows: Triggering any Escalation Event Instance on the Engine. | `false` |

### 4.2 Enum claims

| Claim key | Allowed values | Semantics | Default if absent |
|---|---|---|---|
| `abort_process_instance` | `none`, `own`, `all` | `none`: cannot abort any PI. `own`: can abort own PIs (i.e. where `PI.started_by.id == caller.sub`). `all`: can abort any PI (admin) | `none` |
| `retry_process_instance` | `none`, `own`, `all` | `none`: cannot retry any PI. `own`: can retry own PIs (i.e. where `PI.started_by.id == caller.sub`). `all`: can retry any PI (admin) | `none` |
| `delete_process_instance` | `none`, `own`, `all` | `none`: cannot delete any PI. `own`: can delete own PIs (i.e. where `PI.started_by.id == caller.sub`). `all`: can delete any PI (admin) | `none` |

### 4.3 System / admin token convention

Operators who need a CI/CD deploy token, a seeding-directory loader identity,
or an engine-to-engine integration token mint a JWT with the appropriate
composite claim set:

```json
{
  "sub": "system:deployer",
  "deploy_bpmn": true,
  "delete_bpmn": true,
  "abort_process_instance": "all",
  "retry_process_instance": "all",
  "delete_process_instance": "all",
  "purge_audit_data": true,
  "zeeky_boogie_doog": true
}
```

There is **no** special `super_user=true` or `admin=true` claim — each
capability is independently enumerable, so operators can construct least-
privilege tokens for each use case.

The seeding-directory loader runs under the Identity `{id: "system:seeder"}`
with `deploy_bpmn=true` only. This identity is recorded in
`process_versions.deployed_by` like any other deploy.

---

## 5. Visibility rules — Process Instances, Flow Node Instances, Data Objects

### 5.1 PI visibility (Option B — extended)

A caller can see a Process Instance if **any** of the following is true:

1. **Starter match:** `process_instances.started_by.id == caller.sub`
2. **Lane match (any FNI, any state):** the PI has **at least one FNI
   (in any state, including finished/fatal/aborted)** whose owning lane the
   caller can access (i.e. the caller's JWT has `lane:<lane_name>` set to
   `"read"` or `"write"` for that FNI's lane), **or** the caller has
   `observe_all=true`
3. **No-lane escape hatch:** the PI has at least one FNI that sits on **no
   lane at all** (process has lanes, but this particular element is outside
   them)
4. **No-lanes-in-process:** the process definition has zero `<bpmn:lane>`
   elements — the PI is visible to every authenticated caller
5. **Admin override:** caller has `zeeky_boogie_doog=true`
6. **Unbounded observe:** caller has `observe_all=true` (read/observe only — never write)

For terminal PIs (`finished`, `fatal`, `aborted`, `error`, `escalated`,
`compensated`), **rule 2 evaluates against the historical FNI set** (all FNIs
that ever existed on that PI, not just currently active ones). This means a
manager who finished a User Task on "Management" lane can still see the PI
after it terminates, even if no active FNIs remain.

**Negative case:** a caller who cannot see a PI receives:
- `404` on single-PI-by-ID lookups (not `403`, so callers cannot probe for existence)
- The PI is simply absent from paginated list results

### 5.2 FNI visibility

Cascades from PI visibility: if a caller can see the PI, they can see **all**
its FNIs. There is no per-FNI lane filtering on read queries — the lane
system gates **actions** (§6), not row-level read visibility within a visible
PI.

**Rationale:** a user who can see a PI needs full context to understand its
state — hiding half the FNIs in a flow would produce an incoherent picture.
The lane system controls *who can act* on which FNI, not *who can observe*.

### 5.3 DataObject visibility

Same as FNI: inherits from PI visibility. If you can see the PI, you can read
all its Data Objects.

### 5.4 Event visibility (process_instance_events)

The built-in database EventSink was removed. `process_instance_events` is
retained empty for schema compatibility; there is no GraphQL `list`/`get` on
it. Typed engine events are not a persistence-visibility concern. Kernel
tables (PI, FNI, Data Objects, messages/signals) remain the queryable
history, with PI visibility as in §5.1.

### 5.5 Implementation notes

The visibility rule is implemented as an Ash Policy scope (a base-query
filter) applied to every `ProcessInstance` read action. The filter performs:

```sql
WHERE (
  pi.started_by_id = :caller_sub                          -- rule 1
  OR EXISTS (
    SELECT 1 FROM flow_node_instances fni
    WHERE fni.process_instance_id = pi.id
    AND (fni.lane_name IS NULL                             -- rules 3+4
         OR fni.lane_name = ANY(:caller_lanes))            -- rule 2
  )
)
```

The `zeeky_boogie_doog=true` override short-circuits the entire filter.
`observe_all=true` is a **separate** read-only short-circuit (Ash `ObserveAll`
check on PI / FNI / Data Object reads). It does **not** grant write.

This requires a `lane_name` column on `flow_node_instances` — see §5.6.

### 5.6 FNI `lane_name` column

`flow_node_instances` gains a **denormalized** `lane_name text NULL` column,
set at FNI creation time by looking up the flow node's `lane_id` in the
parsed AST and resolving it to `lane.name`. `NULL` means the flow node is
not in any lane (or the process has no lanes).

**Index:** `INDEX (process_instance_id, lane_name)` — supports the SEMI JOIN
in the visibility filter efficiently.

This is a denormalization of data that lives in the AST (`FlowNode.lane_id` →
`Lane.name`), justified by the frequency of the visibility query (every
authenticated list request runs it).

---

## 6. Per-action authorization rules

**Enforcement location:** All claim checks and lane access gates for REST-triggered operations are enforced in **`EvilEngine.Api`** via `EvilEngine.Api.Validation` — not in REST controllers. The tables below describe the *required* claims; the facade function that enforces each claim is listed in §13. PI visibility filters (§5) remain Ash Policy scopes on read actions.

### 6.1 Catalog operations (deployed BPMNs)

| Action | Claim required | Notes |
|---|---|---|
| Read deployed processes / versions / BPMN XML | *(valid JWT only)* | Always allowed for any authenticated caller. No specific claim needed |
| Deploy BPMN (`POST /processes`) | `deploy_bpmn=true` | Also covers re-deploy (new version of existing process) |
| Enable / disable process (`PUT /processes/{model_id}/enable\|disable`) | `deploy_bpmn=true` | Same claim as deploy — both are "catalog mutation" |
| Delete version (`DELETE /processes/{model_id}/versions/{version}`) | `delete_bpmn=true` | Separate from deploy: "I deploy a lot but never delete" is a valid persona |
| Undeploy process (`DELETE /processes/{model_id}`) | `delete_bpmn=true` | Deletes all versions of a process |

### 6.2 Process Instance lifecycle

| Action | Rule | Notes |
|---|---|---|
| **Start PI** (`POST /processes/{model_id}/start`) | **Lane check against the chosen Start Event.** If the process has lanes and the Start Event resides on a lane, the caller must have `lane:<lane_name>="write"`. `"read"` or `observe_all` on a visible start event returns **403**. Absent / leftover `true` / garbage / wrong lane returns **404**. If the process has no lanes, or the Start Event is not in any lane, any authenticated caller may start | Enforced in `EvilEngine.Api.start_process_instance/3` via `Validation.check_lane_access`. The starting user's identity is recorded as `started_by` and never re-checked during execution |
| **Resume** | *(engine-internal, always automatic )* | No user-initiated Resume in v1. The engine's resume path runs with the PI's original `started_by` context — no JWT involved |
| **Abort** (`PUT /process-instances/{id}/abort`) | `abort_process_instance=own` (PI where `started_by.id == caller.sub`) **or** `abort_process_instance=all` (any PI) | `abort_process_instance=none` or absent → `403` |
| **Retry** (`PUT /process-instances/{id}/retry`) | `retry_process_instance=own` (PI where `started_by.id == caller.sub`) **or** `retry_process_instance=all` (any PI) | `retry_process_instance=none` or absent → `403`. Enforced in `EvilEngine.Api.retry_process_instance/4` via `Validation.check_scoped_claim/4` — not in the controller. Ownership is checked on the *targeted* PI even in tree-retry scenarios (ancestors are reset implicitly) |
| Soft-**Delete** (`DELETE /process-instances/{id}`) | `delete_process_instance=own` (PI where `started_by.id == caller.sub`) **or** `delete_process_instance=all` (any PI) | `delete_process_instance=none` or absent → `403` |
| **Purge** (deferred REST; Mix task is the v1 path) | `purge_audit_data` unused | Admin-only Mix/eval; not a GraphQL field |

**Start contract excludes internal execution options.** The public start surface
(`POST /processes/{model_id}/start` and `EvilEngine.Api.start_process_instance/3`)
accepts only Model/Version + Start Event + payload/context/businessKey. Internal
execution options such as `subprocess_node_id`, `parent_process_instance_id`, and
`triggerer_flow_node_instance_id` are **not** public parameters — extraneous
request-body params are ignored (consistent with other endpoints), not rejected.
Isolation of inner subprocess Start Events is enforced by the core invariant in
`Execution.start_process_instance/1` (`subprocess_node_id` ⇒ `parent_process_instance_id`,
else `{:error, :orphan_subprocess_start}`), which every entry point flows through.
See [security.md](security.md) §Subprocess Start-Event Isolation.

### 6.3 Flow Node Instance interaction

| Action | Rule | Notes |
|---|---|---|
| **Finish User Task** (`PUT /user-tasks/{fniId}/finish`) | Caller must have `lane:<lane_name>="write"` for the User Task's lane. `"read"` or `observe_all` (visible, not writable) → **403**. No observe of that lane → **404**. If the User Task is not on any lane, any authenticated caller may finish it. `<evil:assignees>` is evaluated **additionally** against `Identity.id`, `Identity.roles`, `Identity.groups` — both checks must pass | Lane check + assignee check are AND-combined |
| **Cancel User Task** (`PUT /user-tasks/{fniId}/cancel`) | Same as Finish | |
| **Complete async Service Task** (`engine_facade.finish_async_service_task` / `EvilEngine.Api.finish_async_service_task/2`) | Plugins complete via the facade with the privileged plugin identity (§7), bypassing lane checks. There is **no** `PUT /async-flow-nodes/{fniId}/complete` REST route | REST was never shipped for this callback |
| **Fail async Service Task** (`engine_facade.fail_async_service_task` / `EvilEngine.Api.fail_async_service_task/3`) | Same as Complete. There is **no** `PUT /async-flow-nodes/{fniId}/fail` REST route | |

### 6.4 Trigger endpoints (messages, signals, escalations)

| Action | Rule | Notes |
|---|---|---|
| `POST /messages/{message_name}/trigger` | `trigger_message` | `trigger_message` not `"all"` or absent → 403 |
| `POST /signals/{signal_name}/trigger` | `trigger_signal` | `trigger_signal` not `"all"` or absent → 403 |
| `POST /escalations/{escalation_code}/trigger` | `trigger_escalation` (boolean) | Enforced via `Validation.check_claim/3`. Absent / false → 403. Empty `deliveries` is still 200. No payload. Do not revive `POST /triggers/escalations` |
| `POST /timer-events/{flow_node_instance_id}/trigger` | Lane access (`lane:<lane_name>="write"` for the FNI's lane, or FNI is laneless, or `zeeky_boogie_doog=true`) | No dedicated trigger claim. Enforced in `EvilEngine.Api.trigger_timer_event/3` via `Validation.check_lane_access/3`. Visible but not writable (`"read"` / `observe_all`) → `403`. Invisible lane → `404` |

### 6.5 Observability / admin endpoints

| Action | Rule | Notes |
|---|---|---|
| `GET /info` | Open | No specific claim |
| `GET /stats` | *(valid JWT only)* | No specific claim |
| `GET /admin/` (HTML dashboard) | *(valid JWT only)* | Non-production endpoints (`/admin/swagger`, `/admin/graphiql`) are in the exception list (§2) |

---

## 7. Plugin authorization model

### 7.1 Plugin → engine calls (engine_facade)

Plugins run with a **privileged plugin identity**
auto-injected by the `engine_facade`:

```elixir
%Identity{
  id: "plugin:<name>",
  roles: [:plugin],
  groups: [],
  claims: %{}
}
```

This identity **does not carry user JWT claims**, but plugin facade closures call `EvilEngine.Api.*` with **`skip_claims: true`** (see §13). Claim and lane checks are therefore skipped for plugin-initiated facade calls; business rule validation still applies. This replaces the earlier pattern of a blanket identity-level bypass — enforcement is explicit at the Api layer via the opt-out flag, not implicit from the plugin identity shape.

**Audit is preserved:** every `EvilEngine.Api.*` invocation records the plugin
identity just as it would a user identity. "Plugin X started PI Y" is as
queryable as "User A started PI B".

**Rationale:** plugins are co-loaded with the engine by the operator — they are
inside the trust boundary. Forcing operators to configure per-plugin claim sets
would be pure ceremony with no security benefit in a single-tenant engine.

### 7.2 Plugin-exposed API endpoints (RestApiExtension plugins)

When a plugin registers a `RestApiExtension` handler, the engine:

1. Matches the request path against registered prefixes (longest-prefix wins). Unknown paths return HTTP 404 **without** requiring a JWT.
2. When a prefix matches, validates the caller's JWT and resolves the Identity (same as any engine endpoint)
3. Passes the resolved Identity to the plugin's Plug (`conn.assigns.identity`)
4. **Does not apply any engine-level claim policy** to the plugin's endpoint

Per-endpoint authorization is **the plugin's responsibility**. The plugin
reads whatever claims it needs from `Identity.claims` and enforces its own
rules.

**Engine-level claims (`deploy_bpmn`, `abort_process_instance`, etc.) are not applied
to plugin endpoints** — a plugin endpoint that happens to do something
deploy-adjacent is not subject to `deploy_bpmn=true` unless the plugin
chooses to check it.

---

## 8. Execution-time authorization detachment

Once a Process Instance has been started, the **starting user's claims are
irrelevant to the running process**. This is a fundamental invariant:

- The PI's `:gen_statem` process runs with the engine's own BEAM identity
- Flow Node handlers do not receive or inspect the starting user's JWT
- Timer-triggered, message-triggered, and signal-triggered state transitions
  happen asynchronously — there is no "current user" to check against
- JWT expiry during execution has **zero effect** on the running PI

This applies equally to:

| Scenario | Behavior |
|---|---|
| Call Activities | The child PI inherits the parent PI's `started_by` as an immutable audit field but does **not** re-check the starting user's claims against the child process's lanes. Call Activity execution is engine-internal — the lane model gates user-initiated starts only |
| Resume after crash | Automatic . The engine resumes with the PI's stored `process_version_id`. No JWT is involved or needed |
| Retry | The **retrying user's** claims are checked (`retry_process_instance=own\|all`); the retry itself executes without ongoing claim checks |
| Compensate | Engine-internal. No user JWT involved |
| Escalation propagation | Engine-internal scope-chain walk. No claim checks |

---

## 9. WebSocket subscription authorization

WebSocket connections (Phoenix Channels) require the same JWT as HTTP
endpoints. Authorization is applied at two points:

### 9.1 Join-time validation

Implemented channel topics:

| Topic | Join rule |
|-------|-----------|
| `engine:*` | Valid JWT only (same as `/stats` — no specific claim) |
| `process_instance:<id>` | Caller must be able to see the PI per §5.1. Join is rejected with `{:error, %{reason: "not_found"}}` if the PI is invisible. |
| `user_tasks:pending` | Valid JWT only. Dispatch then applies the FNI lane rule to `UserTaskCreated` / `UserTaskFinished`. Unknown `user_tasks:*` subtopics are rejected with `not_found`. |

> **Planned (not yet implemented):** `process:<model_id>` needs a multi-PI visibility design of its own and is deferred.

### 9.2 Dispatch-time lane filtering

**Path:** `apps/api_web/lib/evil_engine_web/ws/event_delivery.ex`

Filtering runs in the channel process after PubSub broadcast so each subscriber applies its own join-cached identity (`accessible_lanes`, `admin_override`, `identity_id`). Classification uses the envelope `type` string (explicit allow-lists), not field presence — JSON `null` and a missing `laneName` are indistinguishable via `get_in/2`.

`admin_override` is `zeeky_boogie_doog` only. A future read-only observe-all claim must be a separate assign so write bypass stays locked.

| Subscriber | Event class | Rule |
|---|---|---|
| `zeeky_boogie_doog` | any | always deliver |
| any topic | engine-level (`Engine*`, `PluginQuarantined`, `ProcessDefinition*`, `Decision*`, `MessagePublished`, `SignalPublished`) | always deliver |
| `process_instance:*` | PI-level (`ProcessInstanceStateChanged`, `ProcessInstanceRetried`) | always deliver (join already proved §5.1) |
| `engine:events` | PI-level | deliver iff `startedById` matches the subscriber **or** `hasLanelessFlowNode` **or** any `laneNames` entry is in `accessible_lanes` |
| any topic | FNI-originating (explicit allow-list, including `TimerFired`) | deliver if `laneName` is `nil`; else iff `laneName` is in `accessible_lanes` |
| `user_tasks:pending` | `UserTaskCreated` / `UserTaskFinished` only | same FNI lane rule; other types are dropped |
| any topic | unknown `type` | drop (`admin_override` still delivers) |

PI-level events are stamped at emit time (`startedById`, `hasLanelessFlowNode`, `laneNames`) so `engine:events` never queries the database. There is no `PiFinished` event — PI terminal transitions are `ProcessInstanceStateChanged`. Classification uses three explicit allow-lists in `EventDelivery`; a missing or unknown envelope type is dropped rather than treated as a laneless FNI.

The subscriber's lane-claim set is resolved **at join time** and cached for
the lifetime of the socket. A JWT refresh mid-connection does not change
the cached claims — the client must disconnect and rejoin to pick up new
claims. This is acceptable because JWT claim changes are rare operational
events, not request-to-request variability.

GraphQL FNI reads stay PI-scoped (§5.2: if you see the PI, you see all FNIs). WebSocket FNI dispatch is stricter (action-style lane gate). That split is intentional.

---

## 10. Error response shape

| HTTP status | When | Body |
|---|---|---|
| `401 Unauthorized` | Missing, expired, or structurally invalid JWT | `{"error": "unauthorized", "reason": "token_expired\|token_invalid\|token_missing"}` |
| `403 Forbidden` | Valid JWT, but the caller lacks the required claim | `{"error": "forbidden", "required_claim": "<claim_key>", "required_value": "<value>", "resource": "<resource_type>"}` |

For GraphQL, the equivalent is:
- `401` → connection-level rejection (no GraphQL response)
- `403` → `errors[].extensions.code = "FORBIDDEN"` with the same
  `required_claim` / `required_value` / `resource` shape

**Visibility-filtered nulls (§5.1) do NOT return `403`** — they return `null`
on single lookups and are simply absent from lists. This prevents existence
probing.

---

## 11. SDK test helper

`engine_sdk` ships a `MintTestToken` module alongside `TestSink`:

```elixir
EvilEngine.SDK.Test.MintTestToken.mint(%{
  sub: "test-user-1",
  "lane:Management" => "write",
  deploy_bpmn: true,
  abort_process_instance: "own"
})
# => "eyJhbGciOiJIUzI1NiIs..."
```

Uses the test-config JWT secret (`TDE_JWT_HS256_SECRET` in test env).
Integration tests use this exclusively — no hard-coded tokens, no
auth-disabled shortcuts.

---

## 12. Engine boot validation

| Condition | Behavior |
|---|---|
| No `TDE_JWT_JWKS_URL` and no `TDE_JWT_HS256_SECRET` and `TDE_AUTH_DISABLED != true` | **Refuse to start.** Log `error`: "No JWT configuration found. Set TDE_JWT_JWKS_URL or TDE_JWT_HS256_SECRET, or set TDE_AUTH_DISABLED=true for development" |
| `TDE_AUTH_DISABLED=true` | Start with auth disabled. Log `warn` every 60s: "JWT authentication is DISABLED — not suitable for production" |
| JWKS URL unreachable at boot | Start, but log `warn`. JWKS refresh retries on the cached-refresh schedule. Tokens requiring JWKS validation are rejected until the first successful fetch |

---

## 13. Api facade validation module (`EvilEngine.Api.Validation`)

**Path:** `apps/api_facade/lib/evil_engine/api/validation.ex`

All JWT claim checks, lane access checks, and admin override logic are centralized here. **REST controllers do not call this module directly** — they delegate to `EvilEngine.Api` functions that invoke Validation internally. GraphQL and WebSocket adapters follow the same pattern where claim-gated operations exist on the facade.

### Functions

| Function | Signature | Purpose |
|----------|-----------|---------|
| `check_claim/3` | `(Identity.t(), claim_name :: String.t(), opts :: keyword())` | Boolean claims: `deploy_bpmn`, `delete_bpmn`, `deploy_dmn`, `delete_dmn` |
| `check_scoped_claim/4` | `(Identity.t(), claim_name, resource_owner_id, opts)` | Scoped enum claims: `abort_process_instance`, `retry_process_instance`, `delete_process_instance` (`"none"` / `"own"` / `"all"`) |
| `check_required_claim/4` | `(Identity.t(), claim_name, required_value, opts)` | Value claims: `trigger_message`, `trigger_signal` (require `"all"`) |
| `check_lane_access/3` | `(record_with_lane_name, Identity.t(), opts)` | FNI **write** gate. `:ok` for `"write"` / zeeky / laneless / `skip_claims`. `{:error, :forbidden, details}` when the caller can observe (`"read"` or `observe_all`) but not write. `{:error, :not_found}` when the caller cannot observe that lane |
| `admin_override?/1` | `(Identity.t()) :: boolean()` | True when `zeeky_boogie_doog=true` in claims |
| `has_lane_claim?/2` | `(Identity.t(), lane_name :: String.t()) :: boolean()` | True when `lane:<lane_name>="write"` (act). `"read"` is **not** a write grant |

Private `skip_claims?/1` reads `Keyword.get(opts, :skip_claims, false)`. When true, all claim and lane helpers short-circuit to `:ok`.

### Claim-to-facade mapping

| Claim | Api facade function(s) |
|-------|------------------------|
| `deploy_bpmn` | `persist_deploy_batch/3`, `update_process_enabled/3` |
| `delete_bpmn` | `delete_process_version/4`, `undeploy_process/3` |
| `deploy_dmn` | `deploy_dmn_batch/2`, `update_decision_enabled/3` |
| `delete_dmn` | `soft_delete_decision_version/2`, DMN undeploy paths |
| `abort_process_instance` | `abort_process_instance/4` |
| `retry_process_instance` | `retry_process_instance/4` |
| `delete_process_instance` | `delete_process_instance/3` |
| `trigger_message` | `publish_message/5` |
| `trigger_signal` | `publish_signal/3` |
| `lane:<name>` | `finish_user_task/4`, `cancel_user_task/4`, `trigger_timer_event/3` |

Admin override (`zeeky_boogie_doog`) bypasses all claim checks in every helper above.

### Plugin `skip_claims` opt-out

The plugin loader (`apps/peripheral_plugins/lib/evil_engine/plugins/loader.ex`) passes `skip_claims: true` on every claim-gated facade closure it constructs (deploy, enable/disable, delete, abort, retry, delete PI, finish/cancel user task, publish message/signal, etc.). Plugins remain inside the operator trust boundary; audit still records the `plugin:<name>` identity on each Api invocation.

---

## Appendix: Claim reference card

Quick-reference for operators configuring JWTs:

```
# Required
sub: "<unique user id>"

# Boolean claims (default: false if absent)
deploy_bpmn: true|false       Deploy, enable/disable processes
delete_bpmn: true|false       Delete process versions / undeploy processes
purge_audit_data: true|false   Unused in v1 (Mix purge is the retention path)
zeeky_boogie_doog: true|false Admin read+write override
observe_all: true|false       Unbounded read/observe; never write
trigger_escalation: true|false

# Enum claims (default: "none" if absent)
trigger_message: "none"|"all"
trigger_signal: "none"|"all"
abort_process_instance: "none"|"own"|"all"
retry_process_instance: "none"|"own"|"all"
delete_process_instance: "none"|"own"|"all"

# Lane claims (dynamic, one per BPMN lane name: none if absent)
# Values: "read" (observe) | "write" (observe+act). Boolean true is garbage.
lane:<LaneName>: "read"|"write"
```
