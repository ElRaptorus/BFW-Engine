---
name: understand-codebase
description: >-
  Onboards agents to the ThomasTheDaemonEngine codebase structure, architecture,
  and key patterns. Use when exploring the project for the first time, when asked
  to understand how something works, or before making architectural changes.
---

# Understanding the ThomasTheDaemonEngine Codebase

## Step 0: Project Overview

ThomasTheDaemonEngine (or simply "the Engine") is a fully qualified BPMN 2.0 Workflow Engine built with Elixir/OTP, Ash Framework, Phoenix, and PostgreSQL 16+. It is structured as an Elixir umbrella project following DDD domain boundaries.

| Directory | What's here |
|-----------|------------|
| `apps/core_*` | Core domain apps: types, execution, events, timers, expressions, BPMN parsing |
| `apps/peripheral_*` | Peripheral domain apps: persistence, telemetry, plugins |
| `apps/api_*` | API domain apps: auth, HTTP, GraphQL, WebSocket, admin |
| `docs/` | Project documentation (architecture, implementation plan, phases, glossary, schema) |
| `docs/architecture/` | Detailed single-topic architecture references |

## Step 1: Read the Architecture Index

Start with `docs/architecture/index.md`. It lists ~10 topic files, each a standalone technical reference covering one architectural aspect. These are the primary knowledge base for agents.

## Step 2: Drill Into Relevant Topics

Based on your task, read the specific architecture doc:

| Task | Read |
|------|------|
| Plugin system, loading model, SDK | `docs/architecture/plugins.md` |
| Database schema, tables, partitioning | `docs/architecture/data-model.md` |
| EngineEventBus, event sinks | `docs/architecture/event-system.md` |
| REST/GraphQL/WebSocket endpoints | `docs/architecture/api.md` |
| JWT auth, claims, lane rules, PI visibility | `docs/architecture/authorization.md` |
| Message/signal/escalation correlation | `docs/architecture/routing.md` |
| FEEL expressions, context bindings | `docs/architecture/expressions.md` |
| Logging, metrics, /stats endpoint | `docs/architecture/observability.md` |
| Docker, docker-compose, zero-downtime deploy | `docs/architecture/shipping.md` |
| Env vars, config priority, linter gate, retention | `docs/architecture/configuration.md` |
| Test infrastructure, scenario matrix, CI pipeline | `docs/architecture/testing.md` |
| JWT auth, transport, plugin trust, threat model | `docs/architecture/security.md` |
| Known gotchas | `docs/architecture/common-pitfalls.md` |
| BPMN element coverage | `AGENTS.md` and `docs/architecture/execution.md` |
| Terminology | `docs/Glossary.md` |
| Database ER diagram | `docs/Schema.md` |

## Step 3: Key Apps by Domain Layer

### Core (`apps/core_*`)

The engine's domain logic. Core apps never import from API or Peripheral apps.

| App | Purpose |
|-----|---------|
| `core_types` | Behaviour-free structs, shared types, the contract layer |
| `core_execution` | PI/FNI runtime, resume logic, payload cap enforcement |
| `core_events` | EngineEventBus, pending event sweeper |
| `core_timers` | ISO 8601 timer scheduler |
| `core_expressions` | FEEL expression evaluator |
| `core_bpmn` | XML parser, ModelCache, linter gate |

### Peripheral (`apps/peripheral_*`)

Infrastructure adapters. May import Core, never imported by Core.

| App | Purpose |
|-----|---------|
| `peripheral_persistence` | Ash + AshPostgres resources. Mix `evil.retention.purge` hard-deletes aged terminal PI trees |
| `peripheral_telemetry` | `:telemetry` counters, /stats data |
| `peripheral_plugins` | Plugin registry, in-BEAM loader |

### API (`apps/api_*`)

Wire adapters. Thin translation layer between external protocols and `EvilEngine.Api`.

| App | Purpose |
|-----|---------|
| `api_auth` | JWT validation, claim extraction |
| `api_facade` | `EvilEngine.Api` service-layer facade — no Phoenix dep |
| `api_web` | REST + GraphQL + WebSocket + Admin (merged from api_http/api_graphql/api_websocket/api_admin) |

## Step 4: Core Patterns

The 4 patterns agents encounter most:

### 1. Ash Code Interface as Single Service Layer

`EvilEngine.Api` is the convergence point for all consumers. Every wire adapter (REST, GraphQL, WebSocket) and every in-BEAM plugin calls `EvilEngine.Api.*` actions. No consumer bypasses this layer to call Core directly.

### 2. Dependency Direction

Strict unidirectional dependency: Core → Peripheral → API. Core apps define behaviours and structs. Peripheral apps implement persistence and infrastructure. API apps translate wire protocols. Violations of this direction are build errors.

### 3. EngineEventBus Fan-Out

All engine state changes emit events through the EngineEventBus. Consumers (WebSocket channels, audit logger, telemetry, plugin sinks) subscribe via the EventSink behaviour. The bus is the single source of truth for observability and external integrations.

### 4. Hybrid Plugin Model

v1 loads **in-BEAM OTP-app plugins only**. Downstream consumers (Service Task dispatch, EngineEventBus fan-out) query the registry by capability. Non-Elixir work uses the HTTP Service Task, the public API, or an in-BEAM plugin that execs a local interpreter.
