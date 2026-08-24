# ThomasTheDaemonEngine Architecture (Detail)

This folder contains detailed architecture documentation for ThomasTheDaemonEngine. It complements the high-level diagram in [`Architecture.md`](../Architecture.md) and the decision log in [`ImplementationPlan.md`](../ImplementationPlan.md) §0 with concrete, single-topic reference documents.

Each file covers one architectural aspect. Documentation grows as design decisions are made and refined. Agents are expected to keep the relevant file up-to-date whenever a code change or design decision touches its scope.

## Topics

- **[authorization.md](authorization.md)**: JWT identity mapping, claim dictionary, lane-as-claim, PI/FNI visibility rules, per-action authorization, plugin identity, execution-time detachment, WebSocket lane filtering
- **[plugins.md](plugins.md)**: Plugin categories (behaviours), v1 in-BEAM loading model (gRPC sidecar deferred, PLUG-D1), lifecycle phases, engine_facade, failure isolation, SDK packages
- **[data-model.md](data-model.md)** — Postgres schema: catalog tables, execution-state tables, audit/communication tables, shipped vs specified tables, LZ4 compression, partitioning rationale
- **[event-system.md](event-system.md)**: EngineEventBus, EventSink behaviour, three built-in sinks (console, telemetry, websocket), plugin sinks, in-process PubSub topics, fan-out semantics
- **[api.md](api.md)** — REST surface (commands), GraphQL surface (query-only: persistence-backed + Process Model graph), WebSocket (Phoenix Channels), OpenAPI/SDL, API-vs-Core boundary rule
- **[routing.md](routing.md)**: Message correlation, signal broadcast, escalation scope-chain propagation, pending events with TTL, resume behavior
- **[expressions.md](expressions.md)** — FEEL expression engine: context shape, library selection, subset spec, engine-added bindings, evaluation call sites
- **[observability.md](observability.md)**: Event sinks as observability output, structured JSON logs, /stats endpoint, historical analysis, admin HTML
- **[shipping.md](shipping.md)** — Docker, docker-compose, zero-downtime deploy options (blue/green, hot-code-upgrade)
- **[configuration.md](configuration.md)** — Configuration sources, env vars table (~50 entries), linter-score deploy gate, database housekeeping and retention
- **[testing.md](testing.md)** — Test infrastructure, BPMN execution scenario matrix (S1–S15c), assertion framework, conformance corpus, crash-resume variants, CI enforcement
- **[security.md](security.md)** — Threat model, JWT authentication, authorization summary, input validation, plugin trust model, secrets management, known gaps
- **[execution.md](execution.md)** — PI/FNI runtime: gen_statem lifecycle, handler-owned FNI lifecycle via `FniLifecycle`, modular decomposition (Helpers, BoundaryOrchestrator, CompensationOrchestrator, Resumption), handler dispatch, sequence flow resolution, compensation (registry, resolver, orchestrator, LIFO dispatch), supervision tree, persistence adapter, encounter-time validation, Start Event resolution and FinalToken result derivation
- **[dmn.md](dmn.md)** — DMN model, parser, validator, evaluator (7 hit policies, literal expressions, all 10 boxed expression types), Decision Services, evaluation trace, persistence catalog, REST API
- **[sdk-client.md](sdk-client.md)** — TypeScript SDK and client packages: package structure, dependency direction, error mapping pipeline, authentication, integration test architecture, CI/CD
- **[timers.md](timers.md)** — `core_timers` subsystem: Scheduler (ETS layout, tick mechanism, cycle re-arm, PID monitoring), ISO 8601 parser, StartEventManager (cycle schedule lifecycle), persistence behaviour, configuration, telemetry events
- **[persistence.md](persistence.md)**: Dual connection pool architecture (read/write separation), repo routing, CoDel queue tuning, PersistenceRetry coverage, pool telemetry, replica readiness
- **[common-pitfalls.md](common-pitfalls.md)** — Recurring mistakes, gotchas, and non-obvious constraints discovered during engine development

## Companion documents

| Document | Purpose |
|---|---|
| [`Architecture.md`](../Architecture.md) | High-level Mermaid diagram + layer-by-layer reading guide |
| [`ImplementationPlan.md`](../ImplementationPlan.md) | Decision log (§0), runtime specs (§3/§5/§6/§7), BPMN element coverage (§7) |
| [`ImplementationPhases.md`](../ImplementationPhases.md) | Per-phase task lists and exit criteria |
| [`Glossary.md`](../Glossary.md) | Every term used in this project |
| [`Schema.md`](../Schema.md) | Database ER diagram + per-table narrative |

## User Handbook

The `docs/guides/handbook/` directory contains per-topic user guides with worked examples and best practices. Key topics relevant to architecture:

- **Compensation** (`docs/guides/handbook/compensation.md`) — Compensation modeling (Saga pattern, LIFO, ESP handlers, trigger-vs-mechanism)
- **Event Subprocesses** (`docs/guides/handbook/event-subprocesses.md`) — Event Subprocess modeling and trigger semantics
- **Retry / Restart** (`docs/guides/handbook/retry-restart.md`) — PI retry, checkpoint reset, version migration
