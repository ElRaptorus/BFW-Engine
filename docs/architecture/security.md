# Security

This document catalogues every security control in the engine, the threat model
that motivated each one, and the explicit gaps the engine knowingly accepts. It
is a quick-reference during audits and a checklist when adding new API
surfaces or plugin capabilities.

For the full authorization model (claim dictionary, per-endpoint rules, PI/FNI
visibility, lane-as-claim mapping, execution-time detachment, error shapes), see
[authorization.md](authorization.md).

---

## Threat Model

The engine runs as a single-tenant backend service behind a reverse proxy. The
trust boundary is drawn at the HTTP edge:

| Zone | Trust level | Examples |
|------|-------------|---------|
| **Inside the trust boundary** | Fully trusted | Engine process, in-BEAM plugins, database |
| **On the trust boundary** | Authenticated + authorized | REST/GraphQL/WS callers with valid JWT |
| **Outside the trust boundary** | Untrusted | Network clients without JWT |

Plugins are **in-BEAM only** and sit inside the trust boundary with a privileged `plugin:<name>` identity. Crash isolation for native code is OTP-process isolation, not OS-process isolation. `TDE_PLUGINS_SIDECAR_*` env vars do nothing.

---

## Authentication

**JWT by default, pluggable .** The built-in validator in `api_auth` accepts:

| Algorithm family | Configuration | Library |
|-----------------|---------------|---------|
| HS256 | `TDE_JWT_HS256_SECRET` (min 32 bytes) | Joken + JOSE |
| RS256 / ES256 | `TDE_JWT_JWKS_URL` (JWKS with caching + refresh + retry) | Joken + JOSE |

Both can coexist — the engine tries JWKS first, falls back to HS256. At least one
must be configured unless `TDE_AUTH_DISABLED=true`.

**`TDE_AUTH_DISABLED`:** When `true`, disables JWT verification entirely.
All requests receive a synthetic anonymous Identity with least-privilege defaults.
The engine logs a `warn` every 60 seconds while active. Not suitable for production
([authorization.md](authorization.md) §1.1).

Authentication is pluggable via `@behaviour EvilEngine.Plugin.AuthProvider`.
A plugin registers a custom auth provider during `on_load/1` via
`facade.register_auth_provider.(module)`. Only one provider may be active at a
time (first-writer wins; duplicates are rejected and the offending plugin is
quarantined). If no plugin registers a provider, the built-in JWT verifier is
used. The provider's `verify_and_resolve/1` callback receives the raw bearer
token and must return `{:ok, %Identity{}}` or `{:error, reason}`.

---

## Authorization

> Full specification: [authorization.md](authorization.md)

Key design choices (summary only — authorization.md is the source of truth):

- **Default-deny.** Every endpoint requires a valid JWT except `/health`, `/info`, the OpenAPI spec, and non-production admin UIs.
- **Lane-as-claim.** BPMN lanes map to `lane:<name>` JWT claims (`"read"` or `"write"`). Boolean `true` is not a write alias.
- **Engine claims**: `deploy_bpmn`, `delete_bpmn`, `purge_audit_data`, `zeeky_boogie_doog` (admin read+write), `observe_all` (unbounded read, never write), `trigger_message`, `trigger_signal`, `trigger_escalation` (boolean); `abort_process_instance`, `retry_process_instance`, `delete_process_instance` (`none|own|all`); `lane:<name>` (`"read"` \| `"write"`).
- **PI visibility (Option B)**: a caller sees a PI if they started it, OR if any FNI ever on the PI sits on an accessible `"read"`/`"write"` lane (or no lane), OR `zeeky_boogie_doog=true`, OR `observe_all=true`.
- **Execution-detached.** Once a PI starts, the starting user's claims are never re-checked.
- **Plugins bypass claim checks** with a privileged `plugin:<name>` identity; audit is preserved.
- **Triggers claim-gated.** Message / signal / escalation publish endpoints require `trigger_message` / `trigger_signal` / `trigger_escalation` respectively.

### Ash Policy Layer for the BPMN Catalog

`Process` and `ProcessVersion` resources are protected by `Ash.Policy.Authorizer`
with the following policies (implemented 2026-05-07, S-1):

| Resource | Action type | Policy |
|----------|-------------|--------|
| `Process` | `:read` | `authorize_if actor_present()` — any authenticated caller can browse the catalog |
| `Process` | `:create` | `authorize_if expr(^actor(:deploy_bpmn) == true)` |
| `Process` | `:update` | `authorize_if expr(^actor(:deploy_bpmn) == true)` (covers enable/disable) |
| `ProcessVersion` | `:read` | `authorize_if actor_present()` |
| `ProcessVersion` | `:create` | `authorize_if expr(^actor(:deploy_bpmn) == true)` |
| `ProcessVersion` | `:update` | `authorize_if expr(^actor(:delete_bpmn) == true)` (covers `soft_delete`) |
| All above | any | `bypass do authorize_if {ZeekyBoogieDoog, []} end` — admin override |

`ProcessInstance` and `FlowNodeInstance` were already policy-protected (PI/FNI
visibility §5.1). The `authorize_if actor_absent()` bypass that previously
allowed reads without any actor has been removed (S-2). All legitimate internal
reads (`execution_adapter`, `called_element_resolver_impl`, `final_tokens`, system
safety checks in `process_controller`) use `authorize?: false` explicitly.

**Ash actor propagation for REST.** `EvilEngineWeb.Http.Plugs.AshActorPlug` is the
third plug in the `:authenticated` pipeline (after `EvilEngine.Auth.Plug`). It calls
`Ash.PlugHelpers.set_actor/2` to store a flat actor map on `conn.private[:ash][:actor]`,
derived from the JWT-resolved `%Identity{}`:

```elixir
%{
  id:               identity.id,
  accessible_lanes: [lane names extracted from "lane:*" claims],
  zeeky_boogie_doog: bool,
  deploy_bpmn:      bool,
  delete_bpmn:      bool
}
```

GraphQL requests use the same actor map shape, set via `AbsintheContext` into the
Absinthe context (`context: %{actor: actor}`). Both paths share
`AbsintheContext.prepare_actor/1` as the single construction point.

### Subprocess Start-Event Isolation

**Invariant: a Start Event nested inside an embedded / event / (future)
transactional subprocess can never be started directly by an external caller
(REST, plugin, or Call Activity).** Inner scopes are reachable only when the
owning subprocess element is executed by its parent process instance.

Two enforcement layers guarantee this:

| Layer | Location | Behaviour |
|-------|----------|-----------|
| **Public boundary** | `EvilEngineWeb.Http.ProcessController` (private `do_start`) + `EvilEngine.Api.start_process_instance/3` | The public start contract is Model/Version + Start Event + payload/context/businessKey. `subprocess_node_id` is not a public parameter; extraneous request-body params are **ignored** (consistent with every other endpoint), not rejected. The controller builds `start_opts` from only the public request fields plus server-derived `identity`/`process_instance_id`, so internal execution keys are *structurally absent* from the REST path. |
| **Core chokepoint** | `EvilEngine.Execution.start_process_instance/1` | The authoritative guard: if `subprocess_node_id` is present but `parent_process_instance_id` is not, the call is rejected with `{:error, :orphan_subprocess_start}` before the PI is ever supervised. Every entry point (REST, plugin, Call Activity, SubProcess, ESP) flows through this pipeline. |

Supporting guarantees:

- **Resolution scoping** — `ProcessInstance.resolve_start_event/2` resolves start
  events strictly against `process_model.flow_nodes` (the top-level model, or the
  synthetic inner-scope model only when `subprocess_node_id` is set). Inner nodes
  live under `type_data.flow_nodes` and are never visible to top-level resolution.
- **Start-event indexing** — `ModelCache.find_message_start_events/1` and
  `find_signal_start_events/1` index only top-level start events, so an inner
  Message/Signal Start Event can never be triggered by publishing its
  message/signal.
- **Deploy-time uniqueness** — `BPMN.Validator` rejects a definitions document
  whose flow-node IDs collide across the process and any nested subprocess scope
  (`duplicate_flow_node_id`), removing resolution ambiguity.

A dedicated request-validation layer that *rejects* unknown parameters (rather
than ignoring them) is acknowledged as useful but is a separate, out-of-scope
concern.

---

## Input Validation

- **JSON Schema 2020-12** on every inbound payload: triggers, task completions, data contracts. Strict mode is always on. Library: `ex_json_schema`.
- **Payload cap**: `TDE_TOKEN_MAX_BYTES` (default 64 KiB, minimum 1 KiB) enforced at every boundary — facade, REST, async completion. Overflow returns `{:error, :payload_too_large, ...}` from the facade; HTTP 413 from wire adapters. See [database.md](../guides/operations/database.md).
- **BPMN linter gate**: deploy-time validation of `<evil:linterRulesetScore>` entries against configured thresholds. See [configuration.md](configuration.md).

---

## SQL Injection Prevention

All database access goes through Ash resources or raw Ecto queries with bound
parameters. **No user-controlled input is ever interpolated into SQL.** The
single exception — partition DDL in
`apps/peripheral_persistence/lib/evil_engine/persistence/partitions.ex` — uses
inline interpolation because Postgres does not support parameter binding inside
`CREATE TABLE ... PARTITION OF ... FOR VALUES FROM (...) TO (...)`. The values
that flow into that DDL are the engine-controlled `@partitioned_tables` constant
and `%Date{}` structs computed from `Date.utc_today/0`; the function head guards
the date arguments with a `%Date{}` pattern, so non-Date callers fail fast with
a `FunctionClauseError` before any string is built. No path from API request to
partition DDL exists.

---

## Plugin Trust Model

| Plugin | Process isolation | Identity | Trust rationale |
|--------|------------------|----------|-----------------|
| In-BEAM OTP app | None — same BEAM VM | `plugin:<name>` (privileged, bypasses claim checks) | Operator compiled it into the release; same trust as engine code |

In-BEAM plugins:

- Run with a privileged identity that bypasses all engine claim checks ([authorization.md](authorization.md)).
- Are audited — every `EvilEngine.Api.*` call records the plugin identity in the audit trail.
- Can be include-listed / exclude-listed via `TDE_PLUGINS_INCLUDE` / `TDE_PLUGINS_EXCLUDE` ([plugins.md](plugins.md)).
- Are quarantined on `on_load` / `on_ready` failure ([plugins.md](plugins.md)).

Per-plugin authorization scoping (per-plugin claim sets, per-action allow/deny) is not shipped.

There is no sidecar / gRPC plugin host. `TDE_PLUGINS_SIDECAR_*` env vars do nothing.

---

## Secrets Management

- All secrets are read from environment variables (`TDE_JWT_HS256_SECRET`, `TDE_DATABASE_URL`, etc.) or a configurable secret-provider behaviour.
- **No hard-coded secrets** anywhere in the codebase — enforced by `mix sobelow` in CI.
- In test environments, `engine_sdk.MintTestToken` uses `TDE_JWT_HS256_SECRET` to sign test JWTs.

---

## CORS (Cross-Origin Resource Sharing)

**Delegated to the reverse proxy.** The engine itself does not set CORS headers.

Browser-based clients (e.g. Evil Studio) that call the engine's REST / GraphQL /
WebSocket APIs from a different origin require permissive CORS headers on
responses. Because the engine already assumes a reverse proxy for TLS
termination (see Transport Security below), CORS header injection is handled at
the same layer — the proxy knows the deployment topology and allowed origins
better than the engine does.

**Operator responsibility:**

| Header | Recommended value | Notes |
|--------|-------------------|-------|
| `Access-Control-Allow-Origin` | Explicit origin list (not `*`) | Wildcards disable credentialed requests |
| `Access-Control-Allow-Methods` | `GET, POST, PUT, DELETE, OPTIONS` | Match the engine's REST surface |
| `Access-Control-Allow-Headers` | `Authorization, Content-Type` | `Authorization` is required for JWT |
| `Access-Control-Allow-Credentials` | `true` | Needed if cookies or `Authorization` headers are sent |
| `Access-Control-Max-Age` | `86400` | Cache preflight for 24 h to reduce OPTIONS traffic |

Example snippets for nginx, Caddy, and Traefik are shipped in the deployment
documentation alongside the TLS examples.

**Why not engine-level CORS?** Adding a Plug (e.g. `corsica`) would duplicate
configuration that the reverse proxy already owns and create a second source of
truth for allowed origins. If a future deployment model removes the reverse
proxy (e.g. edge-deployed engine with native TLS), a `corsica` Plug gated
behind an `TDE_CORS_ALLOWED_ORIGINS` env var becomes the natural upgrade path.

---

## XSS Prevention

The engine's primary API surface is JSON-only (REST + GraphQL). JSON responses
with `Content-Type: application/json` are not interpreted as HTML by browsers,
making reflected/stored XSS via API responses a non-issue.

**HTML surfaces** that do exist:

| Surface | XSS risk | Mitigation |
|---------|----------|------------|
| `/stats` HTML dashboard | Low — renders server-side counters, no user-supplied content | Phoenix templates with default auto-escaping; no `raw`/`Phoenix.HTML.raw` calls |
| Swagger UI (`/api/docs`) | Low — static asset bundle | Served from a pinned, vendored release; no dynamic interpolation |
| Admin UIs (non-production) | Low — dev-only, no user-supplied rendering | `TDE_AUTH_DISABLED` required or valid admin JWT |

**Engine-level controls:**

- All Phoenix templates use EEx auto-escaping (default). `raw/1` is banned in
  code review and flagged by `mix sobelow`.
- JSON API responses always set `Content-Type: application/json; charset=utf-8`.
- Error responses never reflect raw user input — structured error bodies use
  fixed keys (`error`, `field`, `code`) with engine-controlled values.

**Reverse-proxy responsibility:**

The proxy should set the following headers on responses for browser-facing
surfaces (the engine already emits `X-Content-Type-Options`, `X-Frame-Options`,
and `Referrer-Policy` via `SecurityHeadersPlug` — see [Security Headers](#security-headers)):

| Header | Recommended value |
|--------|-------------------|
| `Content-Security-Policy` | `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'` (adjust for Swagger UI assets) |

---

## Rate Limiting and DDoS Mitigation

**Delegated to the reverse proxy** for network-layer and coarse-grained
application-layer protection. The engine provides application-level guardrails
that limit the blast radius of excessive requests.

### Reverse-proxy responsibility

| Concern | Recommended approach |
|---------|---------------------|
| Network-layer DDoS (SYN flood, UDP amplification) | Cloud provider / infrastructure-level mitigation (AWS Shield, Cloudflare, etc.) |
| Application-layer request flooding | Per-IP / per-token rate limiting at the proxy (nginx `limit_req`, Caddy `rate_limit`, Traefik `rateLimit` middleware) |
| Slowloris / slow-read attacks | Connection timeouts and max-connection limits at the proxy |

### Engine-level guardrails

The engine does not ship a built-in rate limiter in v1. It does, however,
enforce several controls that limit the damage an attacker can cause even at
high request volume:

| Control | Effect |
|---------|--------|
| **Payload cap** | `TDE_TOKEN_MAX_BYTES` (default 64 KiB) — rejects oversize bodies before allocation, preventing memory exhaustion via large payloads |
| **Bandit/Cowboy connection limits** | The HTTP server enforces configurable `max_connections` (Bandit default: 16384) and `idle_timeout` — prevents connection-pool exhaustion |
| **Ecto pool size** | Database connection pools (`TDE_DB_POOL_SIZE`, production default 100 for writes; `TDE_DB_READ_POOL_SIZE`, production default 50 for reads) bound concurrent DB work — excess requests queue or timeout rather than overloading Postgres. Size Postgres with `max_connections >= (write + read) * engine_nodes + 20` |
| **Plugin quarantine** | Repeatedly-failing plugins are quarantined ([plugins.md](plugins.md) §9.3), preventing a misbehaving plugin from amplifying load |
| **JWT validation is stateless** | No database lookup on auth — a flood of invalid JWTs costs CPU (JOSE signature verification) but does not hit the database |

**Why not engine-level rate limiting?** Rate limiting requires per-client state
(IP, token, sliding window). In a reverse-proxy deployment, the proxy already
tracks connections per-client and is better positioned to enforce limits before
requests reach the BEAM. Adding a Plug-level rate limiter (e.g. `hammer`,
`ex_rated`) is a viable v2 enhancement if deployments without a proxy emerge.

---

## Brute-Force Protection

The engine does not have a login endpoint — JWT tokens are issued by an
external Identity Provider (IdP). Brute-force attacks against the engine take
the form of repeated requests with invalid, expired, or stolen JWTs.

### Responsibility split

| Concern | Owner | Rationale |
|---------|-------|-----------|
| **Credential brute-forcing** (username/password) | Identity Provider | The engine never sees credentials; it only validates signed JWTs |
| **JWT guessing / forgery** | Cryptographically infeasible | HS256 with min 32-byte secret; RS256/ES256 with asymmetric keys. Key space makes brute-force impractical |
| **Replaying stolen JWTs** | IdP + operator | Short-lived tokens (`exp` claim) limit the replay window; the engine validates `exp` and rejects expired tokens |
| **Hammering endpoints with invalid JWTs** | Reverse proxy | Per-IP rate limiting on 401 responses; the engine returns 401 immediately without DB work |
| **Token enumeration** (probing for valid tokens) | Engine + proxy | The engine returns identical 401 responses for all rejection reasons (expired, malformed, invalid signature) — no information leakage. Proxy rate-limits per-IP |

### Engine-level controls

- **Constant-time JWT comparison**: JOSE library uses constant-time comparison
  for HMAC verification, preventing timing side-channels.
- **Uniform error responses**: All JWT rejection reasons produce the same HTTP
  401 body (`{"error": "unauthorized"}`) — no distinction between "expired",
  "invalid signature", or "malformed" to external callers.
- **No account lockout state**: The engine holds no per-user session or failure
  counter. There is no lockout to bypass and no state to corrupt via repeated
  failures.

---

## Transport Security

TLS is a **reverse-proxy concern** in v1. The engine natively serves plain HTTP.
HTTPS termination example configurations for nginx, Caddy, and Traefik are
shipped in documentation.

The engine does not implement:
- TLS termination
- mTLS for client certificate authentication
- HTTP Strict Transport Security (HSTS) with the `preload` directive (the engine emits HSTS without `preload` on HTTPS requests; `preload` requires operator-level opt-in at the proxy where the public hostname is controlled)

---

## Security Headers

The engine injects a baseline set of defensive headers on all JSON/REST/GraphQL
responses via `EvilEngineWeb.Http.Plugs.SecurityHeadersPlug`, which is the
second plug in both the `:api` and `:authenticated` router pipelines.

### Engine-emitted headers (always present on JSON responses)

| Header | Value | Purpose |
|--------|-------|---------|
| `x-content-type-options` | `nosniff` | Prevent MIME sniffing |
| `x-frame-options` | `DENY` | Prevent clickjacking |
| `referrer-policy` | `strict-origin-when-cross-origin` | Limit referrer leakage |
| `permissions-policy` | `geolocation=(), camera=(), microphone=()` | Disable unnecessary browser APIs |
| `strict-transport-security` | `max-age=63072000; includeSubDomains` | 2-year HSTS (emitted only when `conn.scheme == :https`). The `preload` directive is intentionally omitted — the engine is commonly deployed behind a reverse proxy that terminates TLS and is not necessarily the public-facing hostname that can safely enter the preload list. |

The `:swagger_ui` pipeline is handled separately by Phoenix's built-in
`put_secure_browser_headers/2` (which also covers `Content-Security-Policy`
tailored for Swagger UI assets) and is not affected by `SecurityHeadersPlug`.

### Reverse-proxy layer (recommended additions)

When the engine is deployed behind a reverse proxy, the proxy should augment
the engine's headers with:

| Header | Recommended value | Purpose |
|--------|-------------------|---------|
| `Content-Security-Policy` | `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'` (adjust for Swagger UI assets) | Prevent inline script execution |
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` | Add `preload` at the proxy level where the hostname is the public TLS terminator |

The proxy can safely override or extend the engine-emitted `Strict-Transport-Security`
value without conflict (duplicate headers of the same name are merged by most
proxies, or the proxy sets its own and strips the engine's).

---

## Penetration Test Surface

This section maps the OWASP Top 10 (2021) and common pentest findings to the
engine's controls and known dispositions. It serves as a pre-engagement
reference when commissioning a penetration test.

| OWASP Category | Engine disposition | Details |
|----------------|-------------------|---------|
| **A01 — Broken Access Control** | Addressed | Default-deny JWT auth; lane-as-claim; PI visibility rules; execution-detached model. Ash policy layer on all five Ash resources (`Process`, `ProcessVersion`, `ProcessInstance`, `FlowNodeInstance`, `GatewayPendingArrival`); `actor_absent()` bypass removed from PI/FNI reads. See [authorization.md](authorization.md) and Authorization §Ash Policy Layer above. |
| **A02 — Cryptographic Failures** | Addressed | JWT via JOSE (HS256 min-32-byte / RS256 / ES256); no custom crypto; secrets from env vars; `mix sobelow` enforces no hardcoded secrets |
| **A03 — Injection** | Addressed | SQL: Ash/Ecto parameterization (zero string interpolation). NoSQL: not applicable. LDAP: not applicable. OS command: no `System.cmd` with user input. FEEL expressions: sandboxed evaluator with no side effects |
| **A04 — Insecure Design** | Addressed | Threat model documented (see above); defense-in-depth via payload cap, plugin quarantine, uniform error responses |
| **A05 — Security Misconfiguration** | Partially addressed | `mix sobelow` in CI; no debug endpoints in production; `TDE_AUTH_DISABLED` logs persistent warnings. Gap: no startup-time config validator beyond individual env var checks |
| **A06 — Vulnerable Components** | Addressed | `mix deps.audit` in CI; `mix sobelow` for Elixir-specific vulnerabilities; Dependabot / Renovate recommended for automated PR-level checks |
| **A07 — Auth Failures** | Addressed | Stateless JWT; constant-time HMAC; uniform 401 responses; no session management; no login endpoint. Brute-force: delegated to IdP + proxy (see above) |
| **A08 — Data Integrity Failures** | Addressed | JWT signature verification on every request; BPMN deploy-time linter gate; JSON Schema validation on all inbound payloads; no deserialization of untrusted binary formats |
| **A09 — Logging & Monitoring Failures** | Partially addressed | Structured JSON logging for all auth events; `/stats` counters; console and websocket event sinks. The `process_instance_events` table is retained for migration compatibility but is no longer populated (the built-in database sink was removed). Gap: no dedicated security-event log stream or SIEM integration in v1 |
| **A10 — SSRF** | Operator-trust | The builtin HTTP Service Task (`implementation="http"`) **does** make outbound HTTP to the URL in deployed `evil:httpUrl`. That URL is process-author / operator-controlled BPMN, not an unauthenticated request parameter. JWKS URL is operator-configured. Treat deployed models and plugins as trusted; SSRF mitigation (URL allowlists, egress proxy) is an operator/plugin-trust concern, not an engine invariant that "the engine never dials out." |

### Additional pentest-relevant controls

| Finding category | Disposition |
|-----------------|-------------|
| **Error message information leakage** | Production error responses use structured JSON with fixed keys — no stack traces, no internal module names, no SQL fragments |
| **HTTP verb tampering** | Phoenix router enforces method matching; unmatched verbs return 404 |
| **Request body size limit** | `TDE_TOKEN_MAX_BYTES` at the application layer; Bandit/Cowboy `max_request_body_size` at the HTTP server layer |
| **Timeout and resource exhaustion** | Bandit `idle_timeout` + `request_timeout`; Ecto pool checkout timeout; GenServer call timeouts on engine internals |
| **Directory traversal** | Not applicable — the engine does not serve static files from user-supplied paths; BPMN upload is parsed as XML, not stored as a file |
| **WebSocket abuse** | Channel authentication via JWT on connect; topic-level authorization (lane filtering); idle connection timeout |
| **GraphQL-specific** | Implemented: `analyze_complexity: true` + `max_complexity: TDE_GRAPHQL_MAX_COMPLEXITY` (default **10000**, sized for the Studio debugger `dataObjectValues(limit: 500)` snapshot which AshGraphql scores at 6500) applied at request time by `EvilEngineWeb.Graphql.PipelineModifier`; `EvilEngineWeb.Graphql.Phases.DepthLimit` rejects queries deeper than `TDE_GRAPHQL_MAX_DEPTH` (default 16, sized for recursive `SubProcessNode.flowNodes`); `EvilEngineWeb.Graphql.Phases.BlockIntrospection` rejects `__schema`/`__type` root fields when `TDE_GRAPHQL_INTROSPECTION_DISABLED=true` (default false). Depth and complexity are read from `Application.get_env/3` at request time — no recompile required. |

---

## Explicit Non-Goals and Known Gaps

The following security-relevant capabilities are intentionally deferred beyond v1.
Each entry documents what is missing, why it was deferred, and (where applicable)
the recommended workaround.

| Gap | Rationale | Workaround |
|-----|-----------|------------|
| ~~Pluggable authentication~~ | **Implemented** via `@behaviour EvilEngine.Plugin.AuthProvider`. Pluggable claim resolution deferred to v2 | Register a custom provider via `facade.register_auth_provider.(module)` |
| **Plugin-tier authorization** (per-plugin claim sets, per-action allow/deny) | Plugins are inside the trust boundary by design | Operator controls which plugins are loaded via allow/deny lists |
| **OpenTelemetry export** (OTLP logs, metrics, traces) | Minimal observability stack in v1 | Plugin `EventSink` for Datadog/Loki/Kafka; `/stats` JSON for counters; optional `GET /metrics` when `TDE_METRICS_ENABLED=true` |
| **Push-gateway / remote-write for Prometheus** | Engine exposes pull-only `/metrics` | Run Prometheus scrape against the engine or federate via your own agent |
| **Per-plugin capability scoping** | Deferred to v2 alongside tenant-isolation model | Trust plugins implicitly; use allow/deny lists to limit which plugins load |
| **Cross-cluster message routing** | Single-node deployment expected in v1 | Messages reach only same-node subscriptions |
| **Content-addressed blob store** | Complexity vs. payoff at v1 scale | `TDE_TOKEN_MAX_BYTES` caps individual payloads; LZ4 compression reduces storage |
