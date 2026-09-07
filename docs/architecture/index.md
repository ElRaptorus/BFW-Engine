# ThomasTheDaemonEngine Architecture (Detail)

This folder is the technical reference for the engine: one file per
subsystem. It complements the high-level picture in
[`Architecture.md`](../Architecture.md). Everyday usage lives in
[`docs/guides/`](../guides/getting-started/overview.md).

Each file covers one architectural aspect. Keep the relevant file
up to date when a code change touches its scope.

## Topics

- **[authorization.md](authorization.md)** — JWT identity mapping, claim dictionary, lane-as-claim, PI/FNI visibility rules, per-action authorization, plugin identity, execution-time detachment, WebSocket lane filtering
- **[plugins.md](plugins.md)** — Plugin categories, in-BEAM loading model, lifecycle, engine_facade, quarantine, SDK packages. Sidecar host is not shipped.
- **[data-model.md](data-model.md)** — Postgres schema: catalog tables, execution-state tables, audit/communication tables, LZ4 compression, partitioning
- **[event-system.md](event-system.md)** — EngineEventBus, EventSink behaviour, three built-in sinks (console, telemetry, websocket), plugin sinks, in-process PubSub topics, fan-out semantics
- **[api.md](api.md)** — REST (commands), GraphQL (query-only: persistence-backed + Process Model graph), WebSocket, OpenAPI/SDL, API-vs-Core boundary
- **[routing.md](routing.md)** — Message correlation, signal broadcast, escalation scope-chain propagation, pending events with TTL, resume behavior
- **[expressions.md](expressions.md)** — FEEL expression engine: context shape, library selection, subset spec, engine-added bindings, evaluation call sites
- **[observability.md](observability.md)** — Event sinks as observability output, structured JSON logs, `/stats`, `/metrics`, `/health`
- **[shipping.md](shipping.md)** — Docker, docker-compose, zero-downtime deploy options
- **[configuration.md](configuration.md)** — Configuration sources, env vars, linter-score deploy gate, database housekeeping and retention
- **[testing.md](testing.md)** — Test infrastructure, BPMN execution scenario matrix, assertion framework, conformance corpus, crash-resume variants, CI
- **[security.md](security.md)** — Threat model, JWT authentication, authorization summary, input validation, plugin trust model, secrets management
- **[execution.md](execution.md)** — PI/FNI runtime, handler dispatch, compensation, supervision tree, persistence adapter, Start Event resolution, FinalToken derivation
- **[dmn.md](dmn.md)** — DMN model, parser, validator, evaluator, Decision Services, evaluation trace, persistence catalog, REST API
- **[sdk-client.md](sdk-client.md)** — TypeScript SDK and client packages: structure, dependency direction, error mapping, authentication, integration tests
- **[timers.md](timers.md)** — `core_timers`: Scheduler, ISO 8601 parser, StartEventManager, persistence, configuration, telemetry
- **[persistence.md](persistence.md)** — Dual connection pool (read/write), repo routing, CoDel queue tuning, PersistenceRetry, pool telemetry
- **[common-pitfalls.md](common-pitfalls.md)** — Recurring constraints a person could hit again (not CI/test novels)

## Companion documents

| Document | Purpose |
|---|---|
| [`Architecture.md`](../Architecture.md) | High-level overview + layer-by-layer reading guide |
| [`guides/getting-started/overview.md`](../guides/getting-started/overview.md) | User-facing entry point |
| [`Glossary.md`](../Glossary.md) | Terms used in this project |
| [`Schema.md`](../Schema.md) | Database ER diagram + per-table narrative |
| [`post-v1-ideas.md`](../post-v1-ideas.md) | Actionable work deferred past v1 (clustering first) |

## User Handbook

The `docs/guides/handbook/` directory contains per-topic user guides with
worked examples. Topics that pair with architecture files:

- **Compensation** (`docs/guides/handbook/compensation.md`)
- **Event Subprocesses** (`docs/guides/handbook/event-subprocesses.md`)
- **Retry** (`docs/guides/handbook/retry.md`)
