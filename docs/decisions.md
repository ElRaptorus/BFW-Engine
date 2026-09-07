# Technical Decision Log

Significant A-vs-B choices that still explain the architecture. Mechanics live in `docs/architecture/`; this file records **why** an option won.

Do not add bugfixes, CI incident reports, Cursor-rule meta, upgrade play-by-plays, or phase diaries. If a later decision replaces an earlier one, leave a one-line SUPERSEDED stub.

`docs/ImplementationPlan.md` and `docs/ImplementationPhases.md` are archival. New decisions go here, not there.

```
### YYYY-MM-DD — Short title

**Context**: 2–3 sentences.
**Options considered**:
- A) …
- B) …
**Decision**: …
**Rationale**: 2–4 sentences.
See [architecture/….md](architecture/….md).
```

---

## Decisions

### 2026-04-24 — Core never imports Peripheral or API

**Context**: Persistence, plugins, and HTTP all need to touch process instances. Putting Ash in Core would be convenient.

**Options considered**:
- A) Core calls Ash / Phoenix directly.
- B) Core defines behaviours (`Persistence`, dispatch); Peripheral/API implement them. `EvilEngine.Api` is the only command facade.

**Decision**: Option B.

**Rationale**: Dependency direction is the umbrella invariant. Tests run Core against `NoOp`. Every wire adapter and plugin converges on `EvilEngine.Api`. See [Architecture.md](Architecture.md) and [execution.md](architecture/execution.md).

---

### 2026-04-24 — Plugins are in-BEAM OTP apps; no gRPC sidecar host

**Context**: Non-Elixir Service Task workers were specified as OS-isolated sidecar processes with a gRPC plugin protocol.

**Options considered**:
- A) Ship `SidecarLoader` + per-language gRPC SDKs in v1.
- B) Load in-BEAM OTP apps only (`on_load` / `on_ready`). Non-Elixir work uses HTTP Service Task, the public API, or an in-BEAM plugin that execs a local interpreter.

**Decision**: Option B.

**Rationale**: Sidecar latency, handshake, and a five-language host were not justified for v1. HTTP and `python_script` / `node_script` cover the real cases. See [plugins.md](architecture/plugins.md).

---

### 2026-04-24 — Service Tasks are async-only

**Context**: Handlers could return `{:ok, %FlowNodeResult{}}` synchronously or park with `{:async, ref}`.

**Options considered**:
- A) Both shapes.
- B) `handle_enter/3` returns `{:async, flow_node_instance_id}` or `{:error, _}` only. Complete via `finish_async` / `fail_async`. Local compute uses Script Task.

**Decision**: Option B.

**Rationale**: One completion path (DOA, token, events). Resume rehydrates waiting FNIs without a second enter. See [plugins.md](architecture/plugins.md) and [execution.md](architecture/execution.md).

---

### 2026-04-24 — CamelCase structural keys; opaque payloads pass through

**Context**: REST, WebSocket, and GraphQL disagreed on key case. Recursively camelCasing tokens would "look consistent."

**Options considered**:
- A) CamelCase the entire JSON tree.
- B) CamelCase structural fields only. `payload`, tokens, `claims`, `errorInfo`, etc. keep author keys.

**Decision**: Option B.

**Rationale**: Process authors own token keys. GraphQL was already camelCase via AshGraphql. See [api.md](architecture/api.md).

---

### 2026-04-24 — GraphQL is query-only

**Context**: AshGraphql can expose mutations. One surface for start/abort/retry would reduce REST.

**Options considered**:
- A) GraphQL commands.
- B) REST (and the facade) for commands; GraphQL for reads including the Process Model graph.

**Decision**: Option B.

**Rationale**: Trigger-style commands stay HTTP/plugin. Absinthe stays a read model. See [api.md](architecture/api.md).

---

### 2026-04-24 — Abort is a tree-wide kill switch

**Context**: Aborting one child PI could mean "cancel this Call Activity" or "stop everything."

**Options considered**:
- A) Abort only the targeted PI.
- B) Abort the entire tree. Error boundaries do not catch abort.

**Decision**: Option B.

**Rationale**: Abort is the operator emergency stop, not a modelled business error. See [execution.md](architecture/execution.md) and the [retry handbook](guides/handbook/retry.md).

---

### 2026-04-24 — Compensation is explicit, not automatic on failure

**Context**: BPMN readers often expect fatal/error/abort to run compensation handlers.

**Options considered**:
- A) Auto-compensate on any non-success terminal.
- B) Dispatch only on Compensate Throw/End (and transaction cancel). Hazard does not compensate.

**Decision**: Option B.

**Rationale**: Matches BPMN 2.0 §13.4.6 for transactions. Model an Error Boundary → Compensate Throw if you want compensation on error. See the [compensation handbook](guides/handbook/compensation.md).

---

### 2026-04-24 — Event Subprocess runs as a child PI of its scope

**Context**: An ESP could be in-process FNIs or a nested process instance.

**Options considered**:
- A) Lightweight FNIs in the scope PI.
- B) Same child-PI machinery as embedded SubProcess (synthetic model, same version). Interrupting cancels sibling FNIs; the scope PI still finishes.

**Decision**: Option B.

**Rationale**: Isolation, resume, and boundaries already exist for child PIs. Killing the scope on interrupt would look like abort. See [execution.md](architecture/execution.md).

---

### 2026-04-24 — Message Catch/Boundary beats ESP Message Start beats standalone Start

**Context**: One message name can have a waiting catch, an ESP start, and a Message Start Event.

**Options considered**:
- A) Fan-out to every subscriber including ESP starts.
- B) Gated start: Catch/Boundary always wins; ESP start wins over creating a new PI.

**Decision**: Option B.

**Rationale**: A running instance that already waits for the message should consume it. Signals stay broadcast-all. See [routing.md](architecture/routing.md).

---

### 2026-04-24 — Signals carry no payload and no correlation

**Context**: A payload on signals would make them "messages with a different name."

**Options considered**:
- A) Optional payload + correlation.
- B) Broadcast by `signal_name` only.

**Decision**: Option B.

**Rationale**: Keep one correlated channel (messages) and one true broadcast. See [routing.md](architecture/routing.md).

---

### 2026-04-24 — No nested transactions in v1

**Context**: BPMN allows a transaction inside a transaction.

**Options considered**:
- A) Nested cancel/compensate semantics.
- B) Deploy-time reject (`:nested_transaction`).

**Decision**: Option B.

**Rationale**: Cancel + LIFO compensation is already subtle in one layer. See the [transactions handbook](guides/handbook/transactions.md).

---

### 2026-04-24 — Sequence-flow conditions only on split-gateway outgoings

**Context**: Modellers put `conditionExpression` on activity outgoing flows.

**Options considered**:
- A) Evaluate every condition at runtime.
- B) Honor conditions only on Exclusive / Inclusive / Complex **split** outgoings. Others ignored.

**Decision**: Option B.

**Rationale**: BPMN token flow from activities is unconditional. Studio lints the rest. See [expressions.md](architecture/expressions.md).

---

### 2026-04-24 — `loopCardinality` is not supported

**Context**: Standard BPMN allows a cardinality expression instead of a collection.

**Options considered**:
- A) Implement cardinality.
- B) Reject at deploy (`:loop_cardinality_not_supported`). Count = collection length (capped by `evil:maxIterations`).

**Decision**: Option B.

**Rationale**: Collection-driven MI matches the data pipeline. See the [multi-instance handbook](guides/handbook/multi-instance.md).

---

### 2026-05-01 — PI-tree retention is Mix-scheduled hard-delete, not a GenServer

**Context**: High-volume operators need disk back. A `RetentionRunner` OTP child and REST `purge` were specified.

**Options considered**:
- A) In-engine sweeper + REST/CLI purge + bus events.
- B) Opt-in `mix evil.retention.purge` (cron). Message/signal tables are operator SQL. No REST purge.

**Decision**: Option B.

**Rationale**: Default is never-delete. Cron owns the interval. Catalog rows stay on the soft-delete lifecycle. See [database.md](guides/operations/database.md).

---

### 2026-05-01 — Soft-delete is invisible at the data layer

**Context**: Ash can filter in policies. A secondary `:read` could include deleted rows for admin.

**Options considered**:
- A) Policy-only hide; admin read includes deleted.
- B) `base_filter` on primary `:read`. Public errors look like not-found. No "soft-delete" in SDK/API text.

**Decision**: Option B.

**Rationale**: `authorize?: false` must not leak deleted rows. See [common-pitfalls.md](architecture/common-pitfalls.md) and the `soft-delete-isolation` rule.

---

### 2026-06-01 — Resume only root process instances

**Context**: After crash, every `running` row could be started.

**Options considered**:
- A) Resume every PI row.
- B) Resume roots only; parents spawn children.

**Decision**: Option B.

**Rationale**: Child-without-parent is an orphan subprocess start. See [execution.md](architecture/execution.md).

---

### 2026-07-01 — Prometheus scrape is built-in; OpenTelemetry is not

**Context**: Observability could be plugins-only, or a full OTel SDK.

**Options considered**:
- A) No `/metrics` in core; plugin sink only.
- B) `GET /metrics` (default on) + `/stats`. OTel deferred.

**Decision**: Option B.

**Rationale**: Operators scrape without writing a plugin. Distributed tracing is a later product. See [observability.md](architecture/observability.md).

---

### 2026-08-01 — Engine-wide payload cap; JSONB default `lz4`

**Context**: Unbounded tokens blow memory and TOAST. Postgres default compression is PGLZ.

**Options considered**:
- A) Per-endpoint / per-process caps; PGLZ.
- B) One `TDE_TOKEN_MAX_BYTES` (default 64 KiB, floor 1 KiB). `TDE_JSONB_COMPRESSION=lz4` unless a measured regression says otherwise.

**Decision**: Option B.

**Rationale**: One gate at every user-supplied boundary. Load measurement on 2026-09-07 did not flunk LZ4 vs PGLZ. See [database.md](guides/operations/database.md).

---

### 2026-09-07 — ImplementationPlan and ImplementationPhases are archival

**Context**: Living docs were still extracted from, and required to append to, the original plan and phase checklist.

**Options considered**:
- A) Keep appending decisions to ImplementationPlan §0 and ticking ImplementationPhases.
- B) Architecture + handbook + `docs/decisions.md` are living. The two Implementation* files stay in the repo as archive.

**Decision**: Option B.

**Rationale**: The v1 surface they described has landed. Appending them duplicated architecture files and minted decision IDs no reader could use. See [architecture/index.md](architecture/index.md).
