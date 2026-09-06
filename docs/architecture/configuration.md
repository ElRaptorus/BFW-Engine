---
title: "Evil Engine — Configuration"
parent_document: "../ImplementationPlan.md"
---

<!--
  Split from packaging.md (ImplementationPlan.md §14).
  For Docker, docker-compose, and deployment options, see shipping.md.
-->

### 14.3 Configuration sources (priority order)

1. Env vars (`EVIL_*`)
2. `config.exs` compiled-in defaults
3. `runtime.exs` reading env
4. `/etc/evil-engine/engine.toml` override (optional, mounted into container)

#### 14.3.1 Application keys (besides `EVIL_*` env vars)

| App / key path | Purpose |
|---|---|
| `config :core_execution, :service_task_dispatch` | Module implementing `EvilEngine.Execution.ServiceTaskDispatch` behaviour. Default **`EvilEngine.Plugins.RegistryDispatch`** (wired in `config/config.exs`) resolves `implementation` handlers from the plugin registry in `peripheral_plugins`. |
| `config :core_execution, :persistence_adapter` | Module implementing `EvilEngine.Execution.Persistence` behaviour. Default **`EvilEngine.Persistence.ExecutionAdapter`** (production). Set to `EvilEngine.Execution.Persistence.NoOp` in test environments. Used by `ResumeRunner` at boot and by runtime PI/FNI persistence. |
| `config :core_bpmn, :model_cache_loader` | MFA tuple `{Module, :function}` called by `ModelCache.fetch/1` on a cache miss. The function receives a `process_version_id` (string) and must return `{:ok, bpmn_xml}` or `{:error, :not_found}`. Configured as `{EvilEngine.Persistence.ExecutionAdapter, :load_bpmn_xml}` in `config.exs` to auto-heal the cache from the `process_versions` DB table. |
| `config :core_bpmn, :seeding_persist_fn` | Optional **callable** (function capture or `&Mod.fun/4`-style) invoked as `persist_fn.(process, bpmn_xml, version_id)` after parse/validate/(optional) linter gate — must return `{:ok, _}` or `{:error, reason}`. Wired at boot by `peripheral_persistence` (or tests) to write `processes` / `process_versions` rows. When `nil`, seeding only populates `ModelCache` (no catalog writes). |
| `config :core_bpmn, :linter_gate` | Keyword list: `:rules` (JSON string from `EVIL_LINTER_GATE`), `:skip_seeding` (boolean from `EVIL_LINTER_GATE_SKIP_SEEDING`). See §14.5. |
| `config :peripheral_plugins, :inbeam_apps` | OTP app atoms to load as in-BEAM plugins (from `EVIL_PLUGINS_INBEAM`). |
| `config :peripheral_plugins, :include_plugins` | Include-only list of plugin names (from `EVIL_PLUGINS_INCLUDE`); when non-empty, only listed names load. |
| `config :peripheral_plugins, :exclude_plugins` | Exclude list of plugin names (from `EVIL_PLUGINS_EXCLUDE`); **exclude wins** over include on the same name. |
| `config :ash, :default_string_length_count` | Required since Ash 3.33. Set to `:codepoints` in `config/config.exs` so `min_length` / `max_length` match PostgreSQL `LENGTH`. Compile fails without it. |

Notable env vars:

| Var | Purpose | Default |
|---|---|---|
| `EVIL_DATABASE_URL` | Postgres connection string (`ecto://USER:PASS@HOST/DB`). Mutually exclusive with the individual `EVIL_DATABASE_*` vars below — if both are set, `EVIL_DATABASE_URL` wins | required (unless individual vars are set) |
| `EVIL_DATABASE_HOST` | Postgres hostname. When set, `EVIL_DATABASE_NAME`, `EVIL_DATABASE_USER`, and `EVIL_DATABASE_PASS` become required | — |
| `EVIL_DATABASE_PORT` | Postgres port (only used with `EVIL_DATABASE_HOST`) | `5432` |
| `EVIL_DATABASE_NAME` | Postgres database name (only used with `EVIL_DATABASE_HOST`) | required |
| `EVIL_DATABASE_USER` | Postgres username (only used with `EVIL_DATABASE_HOST`) | required |
| `EVIL_DATABASE_PASS` | Postgres password (only used with `EVIL_DATABASE_HOST`) | required |
| `EVIL_DB_POOL_SIZE` | Write connection pool size (production default). Size Postgres with `max_connections >= (write + read) * engine_nodes + 20` | `100` |
| `EVIL_DB_READ_POOL_SIZE` | Read connection pool size (production default). Combined with write pool, production defaults already exceed Postgres's default `max_connections` of 100 — raise it (recommend 200 on a single node) | `50` |
| `EVIL_DB_CHECKOUT_RETRIES` | DBConnection Layer 1 retries on mid-query disconnect | `3` |
| `EVIL_DB_QUEUE_TARGET` | CoDel target latency (ms) | `100` |
| `EVIL_DB_QUEUE_INTERVAL` | CoDel measurement interval (ms) | `2000` |
| `EVIL_DB_CHECKOUT_TIMEOUT` | Max wait for a pool connection (ms) | `15000` |
| `EVIL_DB_QUEUE_TIME_WARNING_MS` | Log warning threshold for queue_time (ms) | `500` |
| `EVIL_DB_IPV6` | Connect to Postgres over IPv6 | `false` |
| `EVIL_DB_SSL` | Enable SSL for the Postgres connection | `false` |
| `EVIL_DEVTOOLS_ENABLED` | Toggle Swagger UI (`/`), GraphQL Playground (`/admin/graphiql`), and OpenAPI spec (`/api/openapi`). Disabled in production to prevent schema reconnaissance | `true` (dev/test), `false` (prod) |
| `EVIL_EXPOSE_OPENAPI_SPEC` | Allow `GET /api/openapi` even when devtools are off. Supports production CI pipelines that need the spec for client generation | `false` |
| `EVIL_HTTP_PORT` | HTTP, GraphQL, and WebSocket listen port | `4000` |
| `EVIL_WS_CHECK_ORIGIN` | WebSocket `check_origin` setting. `false` disables the Origin header check (safe when using JWT auth). `true` restricts to the endpoint's own origin. A comma-separated list of URLs (e.g. `http://localhost:5173,https://studio.example.com`) allows specific origins. Defaults to `false` because the engine uses bearer-token auth, not cookie-based sessions, so the Origin header carries no security value | `false` |
| `EVIL_HTTP_SECRET_KEY_BASE` | Phoenix secret key base (min 64 chars). Generate with `mix phx.gen.secret` | required |
| `EVIL_ENGINE_ID` / `EVIL_ENGINE_NAME` | Identity on `/info` and `/stats` | derived from hostname |
| `EVIL_METRICS_ENABLED` | When `true`, starts the Prometheus reporter + poller in `peripheral_telemetry` and serves `GET /metrics`; when `false`, `/metrics` returns `404` | `true` |
| `EVIL_SEEDING_DIRECTORY` | Filesystem path whose `*.bpmn` files are deployed exactly like `POST /processes` calls at startup. If unset, no seeding runs | *(unset)* |
| `EVIL_JWT_JWKS_URL` | JWKS endpoint URL for RS256/ES256 validation. Cached with automatic refresh + retry. At least one of `EVIL_JWT_JWKS_URL` or `EVIL_JWT_HS256_SECRET` must be set unless `EVIL_AUTH_DISABLED=true` — engine refuses to start otherwise ([authorization.md](./authorization.md) §12) | — |
| `EVIL_JWT_HS256_SECRET` | Shared secret for HS256 validation. Minimum 32 bytes. Can coexist with `EVIL_JWT_JWKS_URL` — the engine tries JWKS first, falls back to HS256. In test environments, `engine_sdk.MintTestToken` uses this to sign test JWTs | — |
| `EVIL_AUTH_DISABLED` | When `true`, disables JWT verification entirely. All requests are assigned a synthetic anonymous Identity with least-privilege defaults. Engine logs `warn` every 60s while active. **Not suitable for production** ([authorization.md](./authorization.md) §1.1) | `false` |
| `EVIL_JWKS_REFRESH_SECONDS` | How often the JWKS key set is re-fetched from `EVIL_JWT_JWKS_URL` | `3600` |
| `EVIL_JWT_AUDIENCE` | Expected `aud` claim in JWT tokens. If unset, audience is not validated | *(unset)* |
| `EVIL_JWT_ISSUER` | Expected `iss` claim in JWT tokens. If unset, issuer is not validated | *(unset)* |
| `EVIL_TIMER_TICK_MS` | Scheduler precision; `1000` in prod | `1000` |
| `EVIL_LINTER_GATE` | Compact JSON array of linter-gate rules (see §14.5). Unset = gate disabled | *(unset)* |
| `EVIL_LINTER_GATE_SKIP_SEEDING` | `true` turns the gate off for Seeding-Directory auto-deploys while leaving it on for `POST /processes` | `false` |
| `EVIL_MESSAGE_PENDING_TTL` | How long a published message with zero matching subscriptions and zero matching Message Start Events is held in `pending_messages` before being dropped ([routing.md](./routing.md) §3.5.4). Accepts ISO 8601 duration (e.g. `PT60S`, `PT5M`). Set to `PT0S` to disable pending-message hold (unmatched publishes are recorded to `messages` with `correlations=[]` and immediately expired) | `PT60S` |
| `EVIL_SIGNAL_PENDING_TTL` | How long a published signal with zero matching Signal Catch / Signal Boundary subscriptions and zero matching Signal Start Events is held in `pending_signals` before being dropped ([routing.md](./routing.md) §3.5.6). Accepts ISO 8601 duration. Set to `PT0S` to disable pending-signal hold (zero-match publishes are recorded to `signals` with `correlations=[]` and immediately expired, matching pre-pending-signal-hold behavior). Default matches `EVIL_MESSAGE_PENDING_TTL` intentionally — a unified "resume-race window" is easier for operators to reason about than per-event-type knobs | `PT60S` |
| ~~`EVIL_ESCALATION_PENDING_TTL`~~ | **Removed.** Escalation D1 dropped the pending-escalation cache; there is no `pending_escalations` table and no late-catch hold | — |
| `EVIL_LOG_MIN_SEVERITY` | Global severity floor for the `console` event sink ([event-system.md](./event-system.md) §3.3.3, [observability.md](./observability.md) §11.2). Values: `error` / `warn` / `info` / `debug` / `verbose`. Events below this level are dropped by the console sink only; other sinks filter independently | `info` |
| `EVIL_EVENT_SINK_CONSOLE` | Toggle for the `console` sink. Values: `on` / `off` | `on` |
| `EVIL_EVENT_SINK_TELEMETRY` | Toggle for the `telemetry` sink that backs `/stats`. Disabling this makes `/stats` counters permanently zero | `on` |
| `EVIL_EVENT_SINK_WEBSOCKET` | Toggle for the `websocket` sink that pushes events to connected Phoenix Channels clients | `on` |
| ~~`EVIL_EVENT_SINK_WEBSOCKET_MIN_SEVERITY`~~ | **Does not exist.** Console severity is `EVIL_LOG_MIN_SEVERITY` only. The WebSocket sink drops `debug`/`verbose` by default. | — |
| ~~`EVIL_EVENT_SINK_DATABASE`~~ | **Removed.** The built-in database sink has been removed. Use a plugin sink for DB-backed event persistence. | — |
| `EVIL_RETENTION_RUN_INTERVAL` | **Ignored.** Cron/systemd owns the Mix-task interval. The key remains in `runtime.exs` unused | `PT1H` |
| `EVIL_RETENTION_BATCH_SIZE` | Max number of **root trees** purged per `mix evil.retention.purge` invocation | `500` |
| `EVIL_RETENTION_FINISHED_DAYS` | Max age, in days, for PIs with state `finished` before they are eligible for Mix purge. Unset = never auto-purge `finished` PIs | *(unset)* |
| `EVIL_RETENTION_ERROR_DAYS` | Same, for state `error` | *(unset)* |
| `EVIL_RETENTION_FATAL_DAYS` | Same, for state `fatal` | *(unset)* |
| `EVIL_RETENTION_ABORTED_DAYS` | Same, for state `aborted` | *(unset)* |
| `EVIL_RETENTION_ESCALATED_DAYS` | Same, for state `escalated` | *(unset)* |
| `EVIL_RETENTION_COMPENSATED_DAYS` | Same, for state `compensated` | *(unset)* |
| `EVIL_RETENTION_CANCELLED_DAYS` | Same, for state `cancelled`. REST `DELETE /process-instances/{id}` still omits `cancelled`; only the Mix purge uses this knob | *(unset)* |
| `EVIL_RETENTION_ENGINE_AUDIT_DAYS` | **Unused by the engine.** Operator convention for the Pass B SQL recipe cutoff ([database.md](../guides/operations/database.md)). Unset = operators should not DELETE engine-audit rows | *(unset)* |
| `EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION` | When `true` (default), `pending_messages` rows persist after their state transitions away from `pending` (delivery-attempt audit). They are then eligible for operator SQL via the `EVIL_RETENTION_ENGINE_AUDIT_DAYS` cutoff convention. When `false`, the engine physically deletes the row on deliver/expire/cancel, so the table only ever holds live `pending` rows. Destroy still requires `state == 'pending'` | `true` |
| `EVIL_PENDING_SIGNALS_KEEP_AFTER_TRANSITION` | Same semantics as `EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION`, applied to `pending_signals` | `true` |
| ~~`EVIL_PENDING_ESCALATIONS_KEEP_AFTER_TRANSITION`~~ | **Removed / not applicable.** Escalation D1 dropped the pending-escalation cache; there is no `pending_escalations` table | — |
| `EVIL_PARTITION_AHEAD_MONTHS` | Number of future monthly partitions the `mix evil.partitions.ensure` boot hook creates ahead of time for the tables in `EvilEngine.Persistence.Partitions`: `process_instance_events`, `data_object_writes`, `messages`, `pending_messages`, `signals`, `pending_signals`. There is no `pending_escalations` table. There are no `escalations` / `compensations` / `engine_timers` tables. `timer_start_schedules` is operational and unpartitioned. At least 1 is enforced regardless of configured value | `3` |
| `EVIL_TOKEN_MAX_BYTES` | **Hard payload cap** applied to the canonicalized JSON byte size of every user-supplied payload across: FNI output tokens via `write_result/2`, Data Object values at DOA-commit time (DOA-only: check runs when the engine materializes each `dataOutputAssociation` post-`onFinished`), published messages/signals/escalations via the PI facade + API trigger surfaces, PI `started_with_context` at start, User Task completion results, async Service Task completion/fail payloads via `engine_facade.finish_async_service_task/2` and `fail_async_service_task/3` (../ImplementationPlan.md §3.6 / [plugins.md](./plugins.md) §9.2.5) — **no dedicated public REST path** for async plugin callbacks; cap is enforced on the facade and REST. Overflow → structured `{:error, :payload_too_large, size, limit}` from the facade; causing FNI transitions to `fatal`; HTTP endpoints return HTTP 413 before any engine-side work runs. Minimum enforced `1024` (1 KiB); no max — operators running legitimately large-payload workloads can raise this arbitrarily. Configurable for the **entire engine**; no per-process/per-endpoint override in v1 | `65536` (64 KiB) |
| `EVIL_MAX_CONCURRENT_PIS` | **PI admission control (Layer 1)** — soft cap on **new** PI starts via the public API. Enforced as a pre-check inside `Execution.start_process_instance/1` (not on the `DynamicSupervisor`, which runs with `max_children: :infinity`). When the active PI count is at or above the cap, the function returns `{:error, :engine_at_capacity, %{active, limit}}` and `POST /processes/{model_id}/start` responds **503** with `Retry-After: 5`. **Does not apply during resume at boot** — `ResumeRunner` brings every `:running` PI back online regardless of the cap, so the cap may be briefly exceeded after a restart. The cap then resumes governing new starts until active count drops back below the limit. See [`execution.md`](execution.md) §Resume on Startup. Literal `infinity` (default) disables the cap. | `infinity` |
| `EVIL_RESUME_BATCH_SIZE` | **Resume pagination (PF-1)** — batch size for paginated resume of `:running` PIs at boot. `ResumeRunner` pages through the DB one batch at a time, loading at most this many root PI rows (plus their resume-relevant FNIs) before processing them and moving to the next batch. Higher = faster resume on small datasets; lower = bounded peak memory at boot. Must be a positive integer; refusing values ≤ 0 at startup | `1000` |
| `EVIL_PI_START_RATE_LIMIT` | **Start rate limiting (Layer 2)** — maximum number of `POST /processes/{model_id}/start` calls allowed per `EVIL_PI_START_RATE_WINDOW_MS` sliding window, **globally** (not per caller). Enforced in `EvilEngineWeb.Http.Plugs.RateLimitPlug` via an ETS token bucket. `0` (default) disables the plug entirely | `0` |
| `EVIL_PI_START_RATE_WINDOW_MS` | Window length in milliseconds for `EVIL_PI_START_RATE_LIMIT`. Used only when the limit is > 0 | `1000` |
| `EVIL_JSONB_COMPRESSION` | JSONB column compression algorithm for all heavy-payload columns listed in [data-model.md](./data-model.md) §4.2 / §4.3. `lz4` requires Postgres ≥ 14. Setting this changes only the `default_toast_compression` used by new migrations — existing column data retains whatever compression was applied at write time until rewritten. Intended as the Phase-5 safety hatch if LZ4 measures >10% slower than PGLZ on a representative workload | `lz4` |
| `EVIL_PLUGINS_INBEAM` | **[plugins.md](./plugins.md) §9.2.2**: Comma- or whitespace-separated list of OTP-app names to load as in-BEAM plugins. Order is significant — `on_load` is invoked in list order, sequentially. Apps named here must be present in the release; missing apps are quarantined per [plugins.md](./plugins.md) §9.3. Unset = no in-BEAM plugins | *(unset)* |
| `EVIL_PLUGINS_SIDECAR_DIR` | **[plugins.md](./plugins.md) §9.2.3**: Reserved. Filesystem path that *would* be scanned for sidecar plugin subdirectories with `plugin.toml` manifests. **Unused in v1** (PLUG-D1) — no `SidecarLoader` exists. Parsed in `runtime.exs` as a no-op. Empty string would disable sidecar loading if the host were implemented | `~/.evil/engine/plugins` |
| `EVIL_PLUGINS_INCLUDE` | **[plugins.md](./plugins.md) §9.2 + §9.3**: Comma-separated **include** list of plugin names (OTP-app name string for in-BEAM). When non-empty, only listed plugins are candidates; when unset/empty, no include filter is applied. Sidecar names are reserved for a possible post-v1 host | *(unset)* |
| `EVIL_PLUGINS_EXCLUDE` | **[plugins.md](./plugins.md) §9.2 + §9.3**: Comma-separated **exclude** list. Always evaluated against in-BEAM candidates. **Exclude wins** on conflict with `EVIL_PLUGINS_INCLUDE` — a name appearing in both is rejected with `reason: :ambiguous_policy` | *(unset)* |
| `EVIL_PLUGINS_SIDECAR_RECONNECT_LIMIT` | **[plugins.md](./plugins.md) §9.2.3**: Reserved. Consecutive failed sidecar process restarts before quarantine. **Unused in v1** (PLUG-D1) | `5` |

No `EVIL_OTEL_*` variables exist in v1. **`EVIL_METRICS_ENABLED`** toggles the
public Prometheus scrape endpoint and in-process reporter startup (`config :peripheral_telemetry, :metrics_enabled`, default `true`).

#### Copy-paste reference: complete configuration with defaults

The following shows every `EVIL_*` environment variable with its default value.
Copy this block and adjust only the values you need to override.

```bash
# ==============================================================================
# Evil Engine — Full Configuration Reference
# ==============================================================================
# Copy this into your .env, docker-compose.yml environment block, or
# Kubernetes ConfigMap/Secret. Lines marked "required" have no default and
# must be set explicitly.

# --- Database -----------------------------------------------------------------
# Option A: connection string (preferred for production)
EVIL_DATABASE_URL=ecto://evil_engine:evil_engine@localhost:5432/evil_engine

# Option B: individual fields (alternative to EVIL_DATABASE_URL)
# EVIL_DATABASE_HOST=localhost
# EVIL_DATABASE_PORT=5432
# EVIL_DATABASE_NAME=evil_engine
# EVIL_DATABASE_USER=evil_engine
# EVIL_DATABASE_PASS=evil_engine

EVIL_DB_POOL_SIZE=100
EVIL_DB_READ_POOL_SIZE=50
# Postgres max_connections >= (write + read) * engine_nodes + 20
# With production defaults on one node: 100 + 50 + 20 = 170; recommend 200.
EVIL_DB_CHECKOUT_RETRIES=3
EVIL_DB_QUEUE_TARGET=100
EVIL_DB_QUEUE_INTERVAL=2000
EVIL_DB_CHECKOUT_TIMEOUT=15000
EVIL_DB_QUEUE_TIME_WARNING_MS=500
EVIL_DB_IPV6=false
EVIL_DB_SSL=false

# --- Developer UIs (Swagger, Playground, OpenAPI spec) -----------------------
# EVIL_DEVTOOLS_ENABLED=true          # false in prod by default
# EVIL_EXPOSE_OPENAPI_SPEC=false      # opt-in for /api/openapi in prod

# --- HTTP / GraphQL / WebSocket -----------------------------------------------
EVIL_HTTP_PORT=4000
EVIL_HTTP_SECRET_KEY_BASE=CHANGE_ME_generate_with_mix_phx_gen_secret_min_64_chars

# --- Engine identity ----------------------------------------------------------
EVIL_ENGINE_ID=evil-engine-local
EVIL_ENGINE_NAME=Evil Engine (local)
EVIL_METRICS_ENABLED=true

# --- Authentication (JWT) -----------------------------------------------------
# At least one of HS256_SECRET or JWKS_URL is required unless AUTH_DISABLED=true.
# The docker-compose default uses HS256 with a known dev secret.
# Mint tokens with: mix evil.mint_token  (or ./scripts/mint-token.sh)
EVIL_JWT_HS256_SECRET=BloodForTheBloodGod!_SkullsForTheSkullThrone!
# EVIL_AUTH_DISABLED=false
# EVIL_JWT_JWKS_URL=https://auth.example.com/.well-known/jwks.json
EVIL_JWKS_REFRESH_SECONDS=3600
# EVIL_JWT_AUDIENCE=
# EVIL_JWT_ISSUER=

# --- Payload & compression ---------------------------------------------------
EVIL_TOKEN_MAX_BYTES=65536
# EVIL_MAX_CONCURRENT_PIS=infinity
# EVIL_RESUME_BATCH_SIZE=1000
# EVIL_PI_START_RATE_LIMIT=0
# EVIL_PI_START_RATE_WINDOW_MS=1000
EVIL_JSONB_COMPRESSION=lz4

# --- Seeding ------------------------------------------------------------------
# EVIL_SEEDING_DIRECTORY=/app/seeding

# --- Timers -------------------------------------------------------------------
EVIL_TIMER_TICK_MS=1000

# --- Linter gate (unset = disabled) -------------------------------------------
# EVIL_LINTER_GATE=[{"rulesetId":"bpmn-production-ready","minScorePercent":100}]
EVIL_LINTER_GATE_SKIP_SEEDING=false

# --- Event sinks -------------------------------------------------------
EVIL_EVENT_SINK_CONSOLE=on
EVIL_EVENT_SINK_TELEMETRY=on
EVIL_EVENT_SINK_WEBSOCKET=on
EVIL_LOG_MIN_SEVERITY=info

# --- Pending TTLs (ISO 8601 duration) ----------------------------------------
EVIL_MESSAGE_PENDING_TTL=PT60S
EVIL_SIGNAL_PENDING_TTL=PT60S

# --- Retention (unset = never auto-purge) -------------------------------------
EVIL_RETENTION_RUN_INTERVAL=PT1H
EVIL_RETENTION_BATCH_SIZE=500
# EVIL_RETENTION_FINISHED_DAYS=
# EVIL_RETENTION_ERROR_DAYS=
# EVIL_RETENTION_FATAL_DAYS=
# EVIL_RETENTION_ABORTED_DAYS=
# EVIL_RETENTION_ESCALATED_DAYS=
# EVIL_RETENTION_COMPENSATED_DAYS=
# EVIL_RETENTION_CANCELLED_DAYS=
# EVIL_RETENTION_ENGINE_AUDIT_DAYS=
EVIL_PARTITION_AHEAD_MONTHS=3
EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION=true
EVIL_PENDING_SIGNALS_KEEP_AFTER_TRANSITION=true

# --- Plugins ------------------------------------------------------------------
# EVIL_PLUGINS_INBEAM=
# Sidecar vars are reserved no-ops in v1 (PLUG-D1); parsed, unused.
EVIL_PLUGINS_SIDECAR_DIR=~/.evil/engine/plugins
# EVIL_PLUGINS_INCLUDE=
# EVIL_PLUGINS_EXCLUDE=
EVIL_PLUGINS_SIDECAR_RECONNECT_LIMIT=5
```

### 14.4 Minting dev tokens

The `docker-compose.yml` ships with `EVIL_JWT_HS256_SECRET` set to a known dev
secret and `EVIL_AUTH_DISABLED` **unset** (auth is enforced). Authenticated routes
like `/stats` require a valid `Authorization: Bearer <token>` header.

Two tools are provided for minting tokens locally:

**Mix task** (requires Elixir project checkout):

```bash
# Quick admin token (24h, default claims)
mix evil.mint_token

# Custom operator with 1h expiry
mix evil.mint_token --sub operator-1 --roles admin,viewer --exp 3600

# Arbitrary extra claims
mix evil.mint_token --sub qa-bot --claim tenant_id=acme --claim env=staging

# Use with curl in one shot
curl -H "Authorization: Bearer $(mix evil.mint_token)" http://localhost:4000/stats
```

**Standalone shell script** (no Elixir needed — uses `openssl`):

```bash
# Default dev-user / admin / 24h
./scripts/mint-token.sh

# Custom claims (requires python3 or jq for JSON merge)
./scripts/mint-token.sh '{"sub":"operator-1","roles":["admin","viewer"]}'

# Override secret or expiry
EVIL_JWT_HS256_SECRET=my-secret EVIL_TOKEN_EXP_SECONDS=3600 ./scripts/mint-token.sh
```

Both tools default to the same secret as `docker-compose.yml`, so tokens work
against the local engine out of the box.

### 14.5 Linter-score deploy gate

An external component (the Studio's `bpmn-linter` extension) attaches one or
more `<evil:LinterRulesetScore>` entries to the BPMN XML at the **definitions
level**, under `<bpmn:definitions>/<bpmn:extensionElements>/<evil:Properties>`,
each summarizing the result of one linter ruleset evaluation. The element name
is capitalised (`evil:LinterRulesetScore`, upper-L) and every field is a string
attribute (numeric values are bare, no `%`). This is the authoritative shape
written by the Studio's `UpdateEvilLinterRulesetScoreHandler` (ESP-D17); the
engine parser matches it exactly:

```xml
<bpmn:definitions ...>
  <bpmn:extensionElements>
    <evil:Properties>
      <evil:LinterRulesetScore
        rulesetId="bpmn-production-ready"
        scorePercent="100"
        complianceStatus="valid"
        computedAtIso="2026-04-22T14:08:37.849Z"
        schemaVersion="1"
        maxPoints="52"
        penaltyPoints="0"
        rawErrorFindings="0"
        rawWarningFindings="0" />
    </evil:Properties>
  </bpmn:extensionElements>
  <!-- processes ... -->
</bpmn:definitions>
```

The engine **never runs a linter itself**. It only reads these attributes and, at
deploy time, compares them against the configured gate thresholds. Scores are
scoped to the **definitions** (carried on `%Definitions{linter_scores: [...]}`),
not to individual processes.

#### 14.5.1 Configuration

The gate is configured once at engine boot via the compact JSON env var
`EVIL_LINTER_GATE`. If the var is unset, the gate is disabled and no linter
checks are performed.

Shape (JSON array of per-ruleset rules):

```jsonc
[
  {
    "rulesetId": "bpmn-production-ready",

    // All fields below are optional; an omitted field means "don't check".
    "requirePresence":          true,     // fail if the BPMN carries no score for this rulesetId
    "minScorePercent":          100,      // fail if scorePercent < this
    "maxErrors":                0,        // fail if rawErrorFindings > this
    "maxWarnings":              0,        // fail if rawWarningFindings > this
    "requireComplianceStatus":  "valid",  // fail if complianceStatus != this
    "schemaVersion":            1         // fail if schemaVersion != this (pin to a specific linter schema)
  }
]
```

**Per-environment, not per-mode.** The gate config is an env var, so it naturally
varies per deployment the same way `EVIL_AUTH_DISABLED` does. A typical setup:

- **Development** — lenient threshold on the development ruleset:

  ```bash
  EVIL_LINTER_GATE='[{"rulesetId":"bpmn-development","minScorePercent":80,"maxErrors":0}]'
  ```

- **Production** — strict threshold on the production ruleset:

  ```bash
  EVIL_LINTER_GATE='[{"rulesetId":"bpmn-production-ready","requirePresence":true,"minScorePercent":100,"maxErrors":0,"maxWarnings":0,"requireComplianceStatus":"valid"}]'
  ```

Do **not** combine both in the same config unless they test orthogonal concerns —
a production-ready ruleset is typically a strict superset of a development ruleset,
so requiring both simultaneously would make the lenient one redundant.

**When multiple rulesets make sense.** The array form exists for rulesets that check
different, independent aspects of a BPMN. For example, an organization might enforce
both modeling quality and a naming convention:

```jsonc
[
  { "rulesetId": "bpmn-production-ready", "minScorePercent": 100, "maxErrors": 0 },
  { "rulesetId": "company-naming-convention", "requirePresence": true, "requireComplianceStatus": "valid" }
]
```

When multiple entries are present, **all** must pass — there is no priority or
short-circuit logic.

**Rules are global** — they apply to every `POST /processes` (and, by default, every
Seeding-Directory file) regardless of `processModelId`. There are no per-model_id overrides
in v1 (../ImplementationPlan.md §16.4).

**Rulesets present in the BPMN but not named in the config are ignored** — they do
not influence the deploy decision and are neither logged nor persisted.

#### 14.5.2 Seeding-Directory behavior

By default the gate applies to Seeding-Directory auto-deploys as well. Behavior on
failure:

- Failing BPMN files are **skipped** (not deployed).
- Each skipped file is logged at severity `error` with the list of failed rules.
- Engine startup **continues** after a skipped file — a bad BPMN in the seed
  directory never halts boot.

The gate can be disabled for Seeding-Directory only by setting
`EVIL_LINTER_GATE_SKIP_SEEDING=true`. In that case the gate still applies to
`POST /processes`.

#### 14.5.3 Runtime behavior

- Gate evaluation is **deploy-time only** — both on `POST /processes` and on
  Seeding-Directory loads.
- **Resume**, **Retry**, and every operation on an already-deployed `process_version`
  is **unaffected** by later gate config changes. Once a version is deployed, it
  stays runnable until deleted ([api.md](./api.md) §10.1).
- A gate rejection on `POST /processes` returns `422 Unprocessable Entity`. Response body:

  ```jsonc
  {
    "error": "linter_gate_failed",
    "message": "BPMN does not satisfy configured linter-score gate",
    "failures": [
      {
        "rulesetId": "bpmn-production-ready",
        "reason": "score_below_minimum",
        "expected": { "minScorePercent": 100 },
        "actual":   { "scorePercent": 84.6, "rawErrorFindings": 1, "rawWarningFindings": 17 }
      },
      {
        "rulesetId": "bpmn-production-ready",
        "reason": "errors_exceed_maximum",
        "expected": { "maxErrors": 0 },
        "actual":   { "rawErrorFindings": 1 }
      }
    ]
  }
  ```

  One entry per failed rule; multiple failures for the same ruleset are reported as
  separate entries (reasons are enumerated: `ruleset_missing`, `score_below_minimum`,
  `errors_exceed_maximum`, `warnings_exceed_maximum`, `compliance_status_mismatch`,
  `schema_version_mismatch`).

- Gate rejections are emitted as structured JSON log lines (severity `warn` for
  HTTP, `error` for Seeding-Directory skips) including the rejected filename
  (seeding) or the deployer identity (API) plus the full failures array.

#### 14.5.4 Storage

Linter scores are **not** stored separately on the `process_versions` row. They
live inside `bpmn_xml` and can be re-parsed on demand if a caller wants to report
on them. This keeps the catalog lean and avoids duplicating data that already
lives in the source XML.

If reporting on linter scores becomes a first-class query need later, it can be
backed by a view / generated column over `bpmn_xml` without any schema migration
to existing rows.

#### 14.5.5 Non-goals for v1 (see ../ImplementationPlan.md §16.4)

- Per-`process_model_id` gate overrides
- Runtime API for changing gate thresholds (boot-only in v1)
- Engine-side ruleset evaluation — the engine never runs a linter
- `computedAtIso` staleness checks (max-age rejection)
- Persisting linter scores on the `process_versions` row

### 14.6 Database housekeeping & retention

High-volume operators running tens of thousands of PIs per day need an explicit retention story; low-volume operators need the engine to never delete anything they did not opt into. **Pass A** (PI-rooted trees) is an opt-in Mix task. **Pass B** (engine-wide audit tables with no PI affinity) is operator SQL. There is no `RetentionRunner` GenServer (RET-D1). A fresh installation never deletes anything until the operator sets at least one `EVIL_RETENTION_*_DAYS` env var and schedules the Mix task, or runs the SQL recipe.

#### 14.6.1 Configurable partitioning

Audit tables that grow in append-only fashion ship as `PARTITION BY RANGE` on their monotonically-growing timestamp column from v1 onwards ([data-model.md](./data-model.md) §4.3).

**Phase 1 ships:**

| Table | Partition column | Phase | Populates when |
|---|---|---|---|
| `process_instance_events` | `occurred_at` | 1 | Retained empty — built-in database sink removed |
| `data_object_writes` | `created_at` | 1 | Always |

**Shipped (partitioned on `published_at`):** `messages`, `pending_messages`, `signals`, `pending_signals`. There are no `escalations` or `compensations` tables.

**Partition interval** is controlled by `EVIL_PARTITION_INTERVAL` (default `quarterly`):

| Value | Partition boundaries |
|---|---|
| `monthly` | Calendar month (`2026_05`, `2026_06`, ...) |
| `quarterly` | Calendar quarter (`2026_q1`, `2026_q2`, ...) |
| `half_yearly` | Calendar half (`2026_h1`, `2026_h2`, ...) |
| `yearly` | Calendar year (`2026`, `2027`, ...) |
| `off` | No partitioning; tables are created as regular tables with a simple PK |

Composite primary keys `(id, <timestamp>)` are used when partitioning is on, because the partition key must be in the PK. When `off`, a simple `id` PK is used instead.

At engine boot, `mix evil.partitions.ensure` (run from the release pre-start hook) confirms that:

1. All partitions for the current period and `EVIL_PARTITION_AHEAD_MONTHS` (default `3`) future periods exist; missing ones are created.
2. When `EVIL_PARTITION_INTERVAL=off`, the task is a no-op.

The partition management logic lives in `EvilEngine.Persistence.Partitions` with a single declarative `@partitioned_tables` list. Adding a new partitioned table is a one-line change.

Boot-time `ensure_partitions` is **not** a `pg_partman` replacement. It only pre-creates upcoming partitions; it never `DETACH`/`DROP`s old ones. Operators with long-uptime nodes (or who need to drop aged partitions) should run `pg_partman` (or equivalent) alongside cron. See [database.md](../guides/operations/database.md).

`timer_start_schedules` is **operational and unpartitioned**. Cycle Timer Start rows are deleted on undeploy / `StartEventManager.unregister_timer_starts/1` (and by FK CASCADE from `process_versions`). Pass B SQL must not DELETE them. PI-scoped catch/boundary timers stay in FNI `type_properties` and Scheduler ETS. There is no `engine_timers` table.

#### 14.6.2 Pass A — Mix-scheduled PI tree purge

`mix evil.retention.purge` (and `EvilEngine.Persistence.Release.purge_retention/0` for release eval) hard-deletes aged terminal **root** process-instance trees. Schedule it with cron or systemd. The engine does not wake a GenServer.

- Unset `EVIL_RETENTION_*_DAYS` → the task is a no-op (prints that nothing is configured).
- Only **root** PIs (`parent_process_instance_id IS NULL`) are selection keys. Age column: `finished_at`. Raw SQL bypasses the Ash `deleted == false` filter so already-soft-deleted terminal roots still free disk.
- States with a days knob: `finished`, `error`, `fatal`, `aborted`, `escalated`, `compensated`, `cancelled`. Unset knob for a state → that state is never selected.
- If the whole tree is fully terminal, delete **every** descendant with the root (even if a child is younger than cutoff). If any descendant is `running` or `suspended`, skip the root.
- One transaction per root tree. Cascade order: `process_instance_events` → `gateway_pending_arrivals` → `data_object_writes` → `data_objects` → `flow_node_instances` → `process_instances`.
- Do not touch `messages` / `signals` / `pending_*` / `timer_start_schedules` / catalog rows.
- Batch size = `EVIL_RETENTION_BATCH_SIZE` (default 500) = max trees per Mix invocation.
- `--dry-run` counts eligible roots without deleting.
- `EVIL_RETENTION_RUN_INTERVAL` is **ignored**; cron owns the interval. The key remains in `runtime.exs` unused.

There are no `Event.RetentionPurged` / `Event.EngineAuditPurged` events.

**KEEP_AFTER_TRANSITION.** When `EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION=false` (or the signals twin), `mark_pending_delivered`, expire, and cancel **destroy** the pending row instead of updating state. Destroy still requires `state == 'pending'` so a lost claim cannot wipe another waiter. Default `true` keeps terminal-state rows as delivery-attempt audit until operator SQL ages them out.

#### 14.6.3 Pass B — operator SQL (not in-engine)

`EVIL_RETENTION_ENGINE_AUDIT_DAYS` is an unused operator convention for the SQL recipe in [database.md](../guides/operations/database.md). The engine never sweeps `messages` / `signals` / terminal `pending_*` rows. REST/CLI `purge` and `purge_audit_data` enforcement are deferred / not v1.

#### 14.6.4 Interaction matrix with other features

| Feature | Interaction |
|---|---|
| **DB event sink removed** | `process_instance_events` is no longer populated — the built-in database sink was removed. Pass A still deletes leftover rows for a purged PI. Pass B is operator SQL and is unaffected by event sinks. |
| **Studio engine-debugger views** | The **BPMN-flow view** reads always-on kernel tables. Pass A trims reach for aged terminal PIs. Pass B SQL (when operators run it) caps how far back the message/signal delivery panels reach. |
| **Resume** | Irrelevant — Pass A only touches terminal trees. A `running` PI is never selected. A `pending` pending-message or pending-signal is always preserved regardless of age. |
| **`data_object_writes` always-on** | Purged together with the parent PI tree. A Data Object write audit can live no longer than the PI whose writes it records. |
| **External sinks** | Retention does not affect data already shipped to external sinks. There are no purge bus events; operators who need a trail log Mix/cron output or wrap the SQL recipe. |
| **Monthly partitions** | Row `DELETE`s from Pass A land in the right partition automatically. Dropping old partitions is an operator `pg_partman` (or equivalent) job — boot-time `ensure_partitions` does not drop. `timer_start_schedules` is unpartitioned and not Pass B. |
| **`EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION=false`** | `pending_messages` is zero-retention for terminal-state rows — rows are destroyed on deliver/expire/cancel. Operator SQL over terminal pending rows then finds nothing under normal operation. |
| **`EVIL_PENDING_SIGNALS_KEEP_AFTER_TRANSITION=false`** | Identical semantics for `pending_signals`. Independent per-table. |
| **`EVIL_PENDING_ESCALATIONS_KEEP_AFTER_TRANSITION`** | **Not applicable.** Escalation D1 dropped the pending-escalation cache. |
| **Cross-PI broadcasts & unmatched publishes** | A `messages` row that fanned out to 5 PIs still occupies one row. Pass A does not delete it. Pass B SQL deletes by `published_at` alone. |
| **REST `DELETE /process-instances/{id}`** | Remains **soft-delete of one PI + its FNIs**. It does not walk children, does not hard-delete DOs/gateway rows, and still omits `cancelled`. Pass A is the hard-delete path. |

#### 14.6.5 Non-goals for v1 (see ../ImplementationPlan.md §16.4)

- `RetentionRunner` OTP child, REST/CLI `purge`, per-PI bus events, in-engine Pass B.
- Automatic archival to external storage (S3, GCS, cold-storage Postgres).
- Per-PI retention overrides (e.g. "keep this one PI forever") — retention is global by terminal state.
- Per-table engine-audit knobs inside the engine: one operator convention (`EVIL_RETENTION_ENGINE_AUDIT_DAYS`) plus SQL. Operators who need "keep messages for 1y, signals for 30d" vary the SQL cutoffs.
- Cascading engine-audit rows with PI purge: a `messages` row is not deleted when any of its recipient PIs is purged.
- Event-level retention (keep PI rows but drop old events): in v1 a PI's leftover `process_instance_events` live as long as the PI row does.
