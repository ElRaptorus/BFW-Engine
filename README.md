# Thomas the Khornate Daemon Engine

> The Heresy Train has no Brakes. Choo Choo Motherfucker.

<div align="center">
  <img src="./assets/ThomasTheDaemonEngine.png" alt="" width="400">
</div>

> **Still an early Access Alpha Build. No guarantees.**

## What is this Heresy?

A BPMN 2.0 workflow engine written in Elixir / OTP and oceans of sacrificial blood dedicated to the Blood God Khorne.

Used to run awesome stuff created with the [Forge World Studio](https://github.com/ElRaptorus/BFW-Studio)

- **User Manual & API Reference**: see [Documentation](#documentation) below.
- **Philosophy**: see [docs/Philosophy.md](./docs/Philosophy.md).
- **Specification**: see [docs/ImplementationPlan.md](./docs/ImplementationPlan.md).
- **Roll-out plan**: see [docs/ImplementationPhases.md](./docs/ImplementationPhases.md).
- **Architecture**: see [docs/Architecture.md](./docs/Architecture.md).
- **Configuration**: see [docs/architecture/configuration.md](./docs/architecture/configuration.md).
- **Database schema**: see [docs/Schema.md](./docs/Schema.md).
- **Glossary**: see [docs/Glossary.md](./docs/Glossary.md).

> **Status**: **Phase 6 completed** BPMN Spec coverage achieved. Ready for full scale battle testing and hardening.

---

## Requirements

This project targets **Elixir 1.20.2 / OTP 29** and **Rust 1.97+** (both
pinned via `.tool-versions` for [asdf](https://asdf-vm.com/) /
[mise](https://mise.jdx.dev/)). Rust is required because the FEEL
expression evaluator is a Rust NIF built via Rustler at compile time.

```bash
asdf install
# or:
mise install
```

Postgres **16+** is required at runtime (JSONB + LZ4 compression, configurable
partitioning).

## Documentation

The project ships with a full user manual, API reference, plugin development
guide, and operations handbook — all generated as a searchable static HTML
site via ExDoc.

### Building the docs

```bash
MIX_ENV=dev mix docs
```

This produces the documentation under `manual/`. Open `manual/index.html` in a
browser, or serve it locally:

```bash
python3 -m http.server 8080 -d manual # requires python3 to be installed.
```

### Documentation structure


| Section                | Content                                                                                                                                                                                                                                              |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Getting Started**    | Overview, quickstart, core concepts                                                                                                                                                                                                                  |
| **User Handbook**      | Deploying processes, starting instances, user/service/manual/script/business rule tasks, exclusive gateways, parallel gateways, inclusive gateways, complex gateways, event-based gateways, call activities, embedded subprocesses, event subprocesses, error boundary events, error end events, timer events, message events, signal events, conditional events, escalation events, compensation, link events, data objects, DMN decisions, retry/restart, expressions, error handling, monitoring |
| **API Reference**      | REST endpoints, GraphQL schema, authentication, WebSocket channels                                                                                                                                                                                   |
| **Plugin Development** | Behaviours, engine facade, service task handlers, event sinks, built-in plugins                                                                                                                                                                      |
| **Operations Guide**   | Deployment, database admin, security, observability, troubleshooting                                                                                                                                                                                 |
| **Cheatsheets**        | Environment variables, API endpoints, plugin behaviours                                                                                                                                                                                              |


The docs include full-text search and are navigable by use case (e.g., "I
want to implement a Service Task handler" → Plugin Development → Service
Task Handler).

---

## BPMN 2.0 Element Support

The table below lists every BPMN 2.0 element the engine recognises, grouped
by category.
Each of these Elements has full Runtime support.

### Activities

| Element                | Notes                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| Task (Untyped)         | Pass-through                                                                                 |
| User Task              | Defines User Forms, Actions and Assignees. Waits for User Input                              |
| Manual Task            | Either pass-through, or optional `requires confirmation` to wait for manual user continuation|
| Service Task           | Plugin-driven Service dispatch; built-in HTTP default handler; always `asynchronous`         |
| Script Task            | Inline FEEL evaluation or plugin dispatch. Always `synchronous`                              |
| Business Rule Task     | Either simple FEEL Expression, or full `DMN` execution                                       |
| Send Task              | Publishes messages for 1:1 and deterministic 1:n communication                               |
| Receive Task           | Receives messages, with optional process-level correlation                                   |
| Call Activity          | Executes a target process and waits for the result                                           |
| Sub Process (Embedded) | Inline-Subprocess. Semantically similar to Call Activity, but restricted to one untyped Start Event. Re-uses the parent's lanes. |


### Gateways

| Element             | Notes                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------------- |
| Exclusive Gateway   | Split evaluates FEEL conditions with optional default path, Join is pass-through         |
| Event-Based Gateway | First Catch Event to trigger wins, all others get interrupted.                           |
| Parallel Gateway    | Split activates all outgoing paths, Join waits for ALL incoming tokens before continuing |
| Inclusive Gateway   | Split activates all outgoing paths with a matching condition; Join waits for all incoming paths, with dead-path awareness. |
| Complex Gateway     | Like Inclusive Gateways, but Splits disallow unconditional flows; Joins fire once, when condition is fulfilled and kills all remaining incoming paths. |


### Start Events

| Element     | Notes                                                                   |
| ----------- | ----------------------------------------------------------------------- |
| Untyped     | Normal Entry Point for a BPMN Process Instance                          |
| Timer       | Automated Process Start via Cyclic, Date or Duration Timers             |
| Message     | Automated Process Start, when a Message is received. Correlation-aware; only triggers if no Message Catch Event in the same process listens for the same message with the same correlation. |
| Signal      | Automated Process Start, when a Signal is received                      |

#### Start Events - Event Subprocess only

| Element     | Notes                                      |
| ----------- | ------------------------------------------ |
| Conditional | Triggers when a FEEL condition is met.     |
| Error       | Triggers when an Error is caught.          |
| Escalation  | Triggers when an Escalation is caught.     |
| Compensation| Triggers when a Compensation is caught.    |

**Note:** Event Subprocesses can use _all_ Typed Start Events, but _not_ The Untyped Start Event. The exact opposite of Embedded Subprocesses.


### End Events

| Element      | Notes                                                                  |
| ------------ | ---------------------------------------------------------------------- |
| Untyped      | Finishes a single process path normally                                |
| Terminate    | Terminates all remaining parallel Paths                                |
| Message      | Publishes message and finishes the process path                        |
| Signal       | Publishes signal and finishes the process path                         |
| Error        | Terminates all remaining paths and throws an `Error`. The error propagates to the parent process and can be caught by an `Error Boundary Event`. |
| Escalation   | Finishes a single process path and triggers an `Escalation`. The escalation propagates to the parent process and can be caught by an `Escalation Boundary Event`. |
| Compensation | Triggers compensation for completed activities in the current scope, then finishes the PI with `Compensated` state |
| Cancel       | `Transaction` only. Cancels a Transactional Subprocess.                |


### Intermediate Catch Events

| Element      | Notes                                                      |
| ------------ | ---------------------------------------------------------- |
| Untyped      | Pass-through                                               |
| Link         | Landing pad for Link Throw with the same name              |
| Timer        | Duration and Date Timers, FEEL Expression Support          |
| Message      | Receives messages, with optional process-level correlation |
| Signal       | Receives signal broadcasts from any source                 |
| Conditional  | FEEL-based condition                                       |


### Intermediate Throw Events

| Element      | Notes                                                                       |
| ------------ | --------------------------------------------------------------------------- |
| Link         | Resolves matching Link Catch by name within the same process                |
| Message      | Publishes messages for 1:1 and deterministic 1:n communication              |
| Signal       | Publishes signals for non-deterministic broadcasts                          |
| Escalation   | Propagates escalation to the parent without terminating the current process; PI continues normally after the throw |
| Compensation | Triggers compensation on a specific finished activity, or ALL finished activities. Waits for handlers to complete, then continues normally. |


### Boundary Events

| Element      | Notes                                                                           |
| ------------ | ------------------------------------------------------------------------------- |
| Error        | Matches by error code and/or message; alternative catch-all mode                |
| Timer        | Interrupting and Non-Interrupting; Cyclic, Date and Duration Timer Support      |
| Message      | Interrupting + non-interrupting                                                 |
| Signal       | Interrupting + non-interrupting                                                 |
| Conditional  | Interrupting + non-interrupting; FEEL condition, fires only once                |
| Escalation   | Interrupting + non-interrupting; For Call Activity and Embedded Subprocess only |
| Compensation | Passive marker; registers the host activity for compensation upon completion    |
| Cancel       | Catches Cancellations from a `Cancel End Event`. Transaction Subprocesses only  |


### Data & Flows

| Element                     | Notes                                                                              |
| --------------------------- | ---------------------------------------------------------------------------------- |
| Sequence Flow               | Connects 2 Flow Nodes                                                              |
| Conditional Flow            | FEEL-based condition, used by forking Exclusive- and Inclusive Gateways            |
| Data Associations           | Input or Output Variants. Links Flow Nodes to a Data Object and vice versa         |
| Data Object                 | DOA-driven writes, value contracts, FEEL reads, full write history for audit trail |
| Data Object Reference       | Visual Data Object representation                                                  |
| Association                 | Links compensation boundary events to their handler activities                     |


### Other

| Element          | Notes                                                                          |
| -----------------| ------------------------------------------------------------------------------ |
| Event Subprocess | Interrupting + Non-Interrupting, triggered by single typed Start Event         |
| Transaction      | `All or nothing` style Subprocess. Always succeeds or fails as a whole. Can use `Cancel` Events for premature cancelling and rolling back a transaction, using automatically triggered compensation. |
| Multi-Instance   | Includes Standard Loop, Sequential and Parallel MI                             |
| Ad Hoc Subprocess| An unstructured Activity "Menu", where users can pick the tasks to execute.    |

---

## DMN 1.5 Support

The engine includes a full DMN 1.5 Conformance Level 3 (CL3) decision
engine in the `core_dmn` umbrella app. DMN models are deployed independently
or alongside BPMN diagrams and evaluated via Business Rule Tasks or the
REST API.

### Decision Elements


| Element                  | Notes                                                          |
| ------------------------ | -------------------------------------------------------------- |
| Decision                 | DRG-aware evaluation; `evil:decisionElementId` selects root in multi-decision models        |
| Input Data               | Typed inputs declared in the model; bound from the BPMN token or REST payload               |
| Business Knowledge Model | Encapsulated logic with formal parameters; invoked via `knowledgeRequirement` references    |
| Decision Service         | Evaluate a published subset of decisions; REST `POST /decisions/:id/services/:sid/evaluate` |
| Knowledge Source         | Parsed and stored in the AST; no runtime behaviour (documentation-only per DMN spec)        |
| Item Definition          | Parsed; type coercion tracked in evaluation trace                                           |
| Import                   | Cross-model imports with max-depth circuit breaker (`:max_import_depth`, default 10)        |


### Expressions


| Expression Type     | Notes                                                                  |
| ------------------- | ---------------------------------------------------------------------- |
| Decision Table      | All 7 hit policies; input/output entries are FEEL expressions          |
| Literal Expression  | Single FEEL expression; precompiled at deploy time                     |
| Context             | Ordered key-value entries; entries can reference earlier siblings      |
| Invocation          | Calls a BKM's encapsulated logic with explicit parameter bindings      |
| List                | Ordered collection of sub-expressions                                  |
| Relation            | Tabular data (named columns, expression rows)                          |
| Function Definition | FEEL-kind supported; Java/PMML kinds parsed but rejected at evaluation |
| Conditional         | `if` / `then` / `else` boxed expression                                |
| Filter              | `in` / `match` list filtering                                          |
| For                 | Iteration with `iterator` / `in` / `return`                            |
| Every               | Universal quantifier (`every x in list satisfies ...`)                 |
| Some                | Existential quantifier (`some x in list satisfies ...`)                |


### Hit Policies


| Policy       | Notes                                               |
| ------------ | --------------------------------------------------- |
| UNIQUE (U)   | Exactly one rule matches; error on multiple matches |
| FIRST (F)    | First matching rule in declaration order            |
| PRIORITY (P) | Highest-priority matching rule by output values     |
| ANY (A)      | All matches must agree on the same output           |
| COLLECT (C)  | Aggregation: list, sum, min, max, count             |
| RULE ORDER   | All matching rules, in declaration order            |
| OUTPUT ORDER | All matching rules, sorted by output priority       |


### Diagram Interchange


| Feature | Notes                                                         |
| ------- | ------------------------------------------------------------- |
| DMNDI   | Parsed and preserved in model AST; round-trips through deploy |


### Integration


| Feature                  | Notes |
| ------------------------ |------ |
| Business Rule Task (DMN) | `implementation="dmn"` + `evil:decisionRef` + optional `evil:decisionElementId`                |
| REST Deploy              | `POST /decisions` — batch deploy DMN XML sources                                               |
| REST Evaluate            | `POST /decisions/:id/evaluate` — ad-hoc evaluation outside of BPMN                             |
| REST Decision Services   | `POST /decisions/:id/services/:sid/evaluate`                                                   |
| Plugin Observation       | `FlowNodeInstanceFinished` events carry `type_properties` with full DMN trace for event sinks  |
| Plugin Facade            | `facade.decisions.*` — deploy, evaluate, list, get, enable/disable, get_xml, evaluate_service  |
| Execution Trace          | Structured `EvaluationTrace` with per-decision timing, BKM traces, import traces, coercion log |
| TypeScript SDK/Client    | Full CL3 type definitions in `@elraptorus/daemonengine_sdk`; evaluate/deploy in `@elraptorus/daemonengine_client`    |


---

## Umbrella layout

Each DDD subsystem is a separate OTP application under `apps/`, per
`[ImplementationPlan.md §2](./docs/ImplementationPlan.md#2-high-level-architecture-ddd-domains)`:

```
apps/
├── core_types/              # Shared, behaviour-free structs
├── core_execution/          # PI/FNI runtime
├── core_expressions/        # FEEL evaluator, identity resolver
├── core_bpmn/               # XML parser, AST, ModelCache, linter gate
├── core_dmn/                # DMN 1.5 CL3 decision engine
├── core_timers/             # Timer scheduler (ETS + tick + cycle re-arm), ISO 8601 parser, StartEventManager
├── core_events/             # EngineEventBus + built-in sinks
├── api_facade/              # EvilEngine.Api service-layer facade
├── api_web/                 # REST + GraphQL + WebSocket + Admin
├── api_auth/                # JWT validator (HS256 / RS256 / ES256 / JWKS)
├── peripheral_persistence/  # Ash + AshPostgres + RetentionRunner
├── peripheral_telemetry/    # :telemetry counters backing /stats
├── peripheral_plugins/      # Plugin registry + in-BEAM loader (gRPC sidecar deferred, PLUG-D1)
└── engine_sdk/              # Public behaviours for plugin authors
```

Dependency direction is strictly inward: `API → Core → Peripheral`. `engine_sdk`
re-exports only — it never owns types. See the invariants block in `§2`.

## Getting started

```bash
# 1. Install deps
mix deps.get

# 2. Compile (every app)
mix compile

# 3. Format / lint
mix format --check-formatted
mix credo --strict
mix sobelow

# 4. Dialyzer (first run builds PLT, which takes a few minutes)
mix dialyzer

# 5. Security audit
mix deps.audit

# 6. Tests
mix test
mix coveralls           # coverage
```

## Running locally (docker-compose)

The dev compose stack is engine + postgres only
(`[ImplementationPlan.md §14.2](./docs/ImplementationPlan.md#142-docker-compose-local-dev)`).
No OTel, no Prometheus, no tracing sidecars in v1.

```bash
docker compose up --build
```

- Engine (HTTP, GraphQL, WebSocket): [http://localhost:4000](http://localhost:4000)
- Postgres: `localhost:5432` (db: `evil_engine_dev`, user/pw: `evil_engine`)

## Migration workflow

Migrations are **generated from Ash resource changes**, not hand-written —
see `[ImplementationPlan.md §1](./docs/ImplementationPlan.md#1-tech-stack-final)`
and the `peripheral_persistence` app.

### Generate migrations from resource diffs

```bash
mix ash_postgres.generate_migrations --name <short_description>
```

This inspects every Ash resource registered under the `EvilEngine.Persistence.Api`
domain, compares it to the last snapshot in `apps/peripheral_persistence/priv/resource_snapshots/`,
and emits (a) an Ecto migration under `apps/peripheral_persistence/priv/repo/migrations/`
and (b) the updated snapshot. **Review both in the same PR.**

### Apply migrations

```bash
# dev / test
mix ash_postgres.migrate

# prod (inside the release image)
bin/evil_engine eval "EvilEngine.Persistence.Release.migrate()"
```

### Rollback

```bash
mix ash_postgres.rollback
```

### Partition pre-creation

Monthly partitions for `process_instance_events`, `data_object_writes`,
`messages`, `pending_messages`, `signals`, `pending_signals`, `escalations`,
`pending_escalations`, and `compensations` are pre-created by the boot hook:

```bash
mix evil.partitions.ensure          # dev / test
bin/evil_engine eval "EvilEngine.Persistence.Release.ensure_partitions()"  # prod
```

The `EVIL_PARTITION_AHEAD_MONTHS` env var (default `3`) controls how far
ahead partitions are created.

### Reset (dev only)

```bash
mix ecto.reset      # drops, creates, migrates, seeds
```

## Release build

```bash
MIX_ENV=prod mix release
_build/prod/rel/evil_engine/bin/evil_engine start
```

The Docker image produced by `docker/Dockerfile` runs the same release under
`debian:12-slim`.

## Quality gates

Every change must pass all quality gates before it is considered complete.
The root `mix.exs` provides aliases that run the full pipeline in one command.

### Static analysis tools


| Tool               | Command                            | What it checks                                                                                                                                                                                         |
| ------------------ | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Compiler**       | `mix compile --warnings-as-errors` | Type errors, undefined functions, unused variables, missing modules. Warnings are promoted to errors.                                                                                                  |
| **Credo**          | `mix credo --strict`               | Code consistency, naming conventions, documentation, cyclomatic complexity, dead code, anti-patterns. Strict mode enables all optional checks.                                                         |
| **Dialyzer**       | `mix dialyzer`                     | Static type analysis via success typing. Catches type mismatches, unreachable code, incorrect specs, and contract violations across module boundaries. First run builds the PLT (takes a few minutes). |
| **Sobelow**        | `mix sobelow`                      | Phoenix-specific security scanner. Checks for SQL injection, XSS, directory traversal, insecure configuration, hardcoded secrets, unsafe deserialization, and missing browser security headers.        |
| **mix deps.audit** | `mix deps.audit`                   | Scans dependencies for known security vulnerabilities (CVEs) via Hex advisory database.                                                                                                                |


### Test suite


| Layer                 | Command                | Coverage                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Unit tests**        | `mix test`             | 900+ tests across all umbrella apps. Covers types, BPMN parser/validator, FEEL expressions, DMN parser/evaluator (all 7 hit policies, CL3 expressions), PI/FNI state machine, parallel/inclusive/EBG gateway handlers, conditional event re-evaluation, escalation resolver, timer scheduler/ISO8601/StartEventManager, event bus, plugin registry, auth, persistence, telemetry, HTTP controllers, GraphQL.                                                                                                                                                                                                                                                                                                                                                                                               |
| **Integration tests** | `mix test.integration` | 600+ full-stack tests with DB. Deploy via HTTP, start PIs, complete user/service/script/BRT tasks, verify persistence, payload cap, finalTokens, resume-on-startup, Call Activity lifecycle, Embedded Subprocess lifecycle, Parallel/Inclusive/EBG gateway flows, Conditional events, Escalation cross-PI propagation (S15–S15c), Compensation events (COMP-1–COMP-10: basic throw/end, LIFO ordering, targeted, no-targets, error/escalation-driven, ESP precedence, unfinished activities), Data Object DOA writes, PI retry/restart, auth provider plugins.                                                                                                                                                                                                                                                                                                                                                                       |
| **Conformance tests** | `mix test.conformance` | 170+ tests driven by 171 YAML specs (C01–C220) covering linear flows, user/manual/service/script tasks, business rule tasks (FEEL + DMN + contract violation), data objects (DOA + value contracts + checkpoint rollback), multi-start disambiguation, runtime validation (implicit split, dead end), payload cap rejection, resume-after-restart, exclusive gateway routing (conditions, default, ambiguous, no-match), call activity (basic, error boundary, no-boundary fatal, result mapping, XOR-to-CA), link events (basic pair, multi-pair, orphan throw), PI retry (fatal-replay, aborted-replay, version-migration accept/reject, tree/checkpoint/DO scenarios), auth provider plugins, 22 DMN-only specs (CL1–CL3), 12 timer event specs (catch/boundary/start with duration/date/cycle/FEEL), 9 message event specs (catch/throw/start/end/boundary/send-receive/mappings/contract), 8 embedded subprocess specs (C140–C146), 4 escalation specs (C95–C98), 6 parallel gateway specs (C160–C164), 6 EBG specs (C150–C154), 12 inclusive gateway specs (C200–C210), 15 event subprocess specs (C170–C182), and 10 compensation specs (C211–C220: basic throw/end, LIFO, targeted, no-targets, error/escalation-driven, ESP precedence, unfinished activity). |
| **Load tests**        | `mix test.load`        | 15 benchmarks in two suites: **Resume** (L1–L8) — resume 100–10,000 PIs across varying process types and FNI counts, plus seeding throughput at 1K/5K/10K batch sizes. **Execution** (E1–E7) — full API-driven lifecycle: deploy via HTTP, start 100–10,000 PIs through the API across 5 fixture types (linear, chained tasks, sync/async service tasks, user tasks), with auto-finishing of user tasks via an EngineEventBus sink.                                                                                                                                                                                                                                                                                                                                                                       |
| **Coverage**          | `mix coveralls.html`   | HTML coverage report under `cover/`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |


### One-command quality gate

```bash
mix quality
```

Runs compile → Credo → Dialyzer → Sobelow → unit tests (with coverage) → integration tests → conformance tests (171 YAML specs including 22 DMN, 15 event subprocess, 12 inclusive gateway, 10 compensation, 8 embedded subprocess, 6 parallel gateway, 6 EBG, 4 escalation specs) in sequence. Fails on first error.

### CI pipeline

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs all of the above plus `mix format --check-formatted` and `mix deps.audit`.

---

## Running the test suite across the umbrella

```bash
mix test.all           # every app's tests
mix test apps/core_bpmn   # one app
mix coveralls.html     # HTML coverage report under cover/
```

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs:


| Step           | Command                                 |
| -------------- | --------------------------------------- |
| Format         | `mix format --check-formatted`          |
| Credo          | `mix credo --strict`                    |
| Dialyzer       | `mix dialyzer`                          |
| Tests          | `mix coveralls.github`                  |
| Security audit | `mix deps.audit` + `mix sobelow --exit` |


## License

TBD. See the root repo for licensing terms once finalised.
