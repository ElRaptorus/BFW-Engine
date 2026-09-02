# Overview

ThomasTheDaemonEngine is a BPMN 2.0 workflow engine built on Elixir/OTP, designed for embedding into larger platforms via REST, GraphQL, and WebSocket APIs. It extends standard BPMN with the `evil:` XML namespace (`https://evilengine.dev/schema/bpmn`) for features like version management, plugin dispatch, user task contracts, and correlation keys.

## Key Capabilities

- **BPMN Execution** -- process flows with Start Events, End Events, Tasks, User Tasks, Manual Tasks, Service Tasks, Script Tasks, Business Rule Tasks, Exclusive Gateways, Call Activities, Link Events, Error Boundary Events, and Data Objects (see the [element support table](#current-element-support) below)
- **DMN 1.5 CL3** -- full DMN decision engine with all 7 hit policies, all 10 boxed expression types, DRD chaining, BKM invocation, Decision Services, and cross-model imports
- **FEEL Expressions** -- DMN-spec expression language evaluated via a Rust NIF for high throughput
- **Plugin System** -- extensible via `@behaviour` modules. Live capabilities: Service Task handlers, Event Sinks, Named Scripts, Auth Providers, RestApiExtension. PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities do not exist.
- **REST + GraphQL APIs** -- trigger-style REST for all commands, AshGraphql for read-only queries and the Process Model graph
- **WebSocket** -- Phoenix Channels for real-time event streaming
- **PostgreSQL Persistence** -- Ash framework with partitioned audit tables. Opt-in PI-tree hard-delete via `mix evil.retention.purge`; engine-audit cleanup is operator SQL.
- **JWT Authentication** -- HS256, RS256, ES256, and JWKS with claim-based authorization; pluggable Auth Provider for custom identity resolution
- **PI Retry** -- retry failed or aborted process instances with optional version migration and checkpoint reset. There is no separate restart command.
- **Back-Pressure** -- three-layer overload protection: PI admission control, start rate limiting, and overload signaling

## Architecture at a Glance

The engine is an Elixir umbrella project with **14 OTP applications** organized into four layers:

| Layer | Applications | Purpose |
|-------|-------------|---------|
| **Core** | `core_types`, `core_execution`, `core_expressions`, `core_bpmn`, `core_dmn`, `core_timers`, `core_events` | Domain logic, runtime, FEEL evaluation, BPMN parsing, DMN evaluation |
| **Peripheral** | `peripheral_persistence`, `peripheral_telemetry`, `peripheral_plugins` | Database, metrics, plugin registry |
| **API** | `api_auth`, `api_facade`, `api_web` | JWT, service-layer facade, REST + GraphQL + Channels + Swagger UI |
| **SDK** | `engine_sdk` | Public behaviours and types for plugin authors |

Dependencies flow strictly inward: **Peripheral depends on Core; API depends on both; Core never depends on Peripheral.** The SDK re-exports types only.

## Current Element Support

The engine currently supports end-to-end execution of:

- **Activities**: Task, User Task, Manual Task, Service Task, Script Task, Business Rule Task, Call Activity, Send Task, Receive Task, Embedded SubProcess, Ad-hoc SubProcess, Transaction SubProcess
- **Gateways**: Exclusive Gateway, Parallel Gateway, Inclusive Gateway (OR-split with multi-truthy FEEL conditions + OR-join with dead-path elimination), Event-Based Gateway, Complex Gateway (opinionated SESE split/join)
- **Events**: Untyped Start/End/Intermediate Events, Link Throw/Catch Events, Error/Terminate End Events, Message Events (Start/Catch/Throw/Boundary), Signal Events (Start/Catch/Throw/Boundary), Timer Events (Start/Catch/Boundary with cycle/duration/date), Error Boundary Events (interrupting and non-interrupting), Escalation Events (Throw/End/Boundary), Conditional Events (Catch/Boundary), Compensation (Throw/End/Boundary/Start inside Event Subprocess), Cancel Events (inside Transaction)
- **Subprocess variants**: Embedded SubProcess, Event Subprocess (message/signal/timer/conditional/error/escalation/compensation starts), Ad-hoc SubProcess, Transaction
- **Loops**: Multi-Instance (parallel and sequential), Standard Loop (while-do / do-while)
- **Flows**: Sequence Flow (including default flows and conditional expressions)
- **Data**: Data Objects (DOA-driven writes, value contracts, FEEL reads, audit history)
- **DMN**: Decision Tables (all 7 hit policies), all 10 boxed expression types, DRD chaining, BKM, Decision Services

See the README for the full element support matrix.

## Where to Go Next

- [Quickstart](quickstart.md) -- set up the engine and run your first process
- [Core Concepts](concepts.md) -- BPMN primer, `evil:` extensions, FEEL bindings
- [User Handbook](../handbook/deploying-processes.md) -- use-case-driven guides for everyday tasks
- [DMN Decisions](../handbook/dmn-decisions.md) -- deploy and evaluate DMN decision models
- [API Reference](../api/rest-reference.md) -- REST and GraphQL endpoint documentation
- [Plugin Development](../plugins/getting-started.md) -- build custom handlers and sinks
- [Operations Guide](../operations/deployment.md) -- deploy, configure, and monitor the engine
