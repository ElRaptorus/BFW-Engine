---
name: understand-codebase
description: >-
  Onboards agents to the Bifrost Forge World Engine codebase structure, architecture,
  and key patterns. Use when exploring the project for the first time, when asked
  to understand how something works, or before making architectural changes.
---

# Understanding the Bifrost Forge World Engine Codebase

## Step 0: Project Overview

Bifrost Forge World Engine (or simply "the Engine") is a fully qualified BPMN 2.0 Workflow Engine built with Elixir/OTP, Ash Framework, Phoenix, and PostgreSQL 18+. It is one OTP application (`:bfw_engine`) whose DDD subsystems are compile-time boundaries (the `boundary` library).

| Directory | What's here |
|-----------|------------|
| `lib/bfw_engine/<subsystem>/` | One boundary per subsystem: types, execution, events, timers, expressions, bpmn, dmn, persistence, telemetry, plugins, plugin contracts, api, auth |
| `lib/bfw_engine_web/` | REST, GraphQL, WebSocket, admin |
| `lib/mix/tasks/` | `bfw.*` Mix tasks |
| `native/feel_nif/` | Rust FEEL NIF crate |
| `test/unit/<subsystem>/`, `test/integration/`, `test/conformance/`, `test/load/` | Unit, integration, conformance, and load tests; harness in `test/support/` and `test/unit/*/support/`, fixtures in `test/fixtures/` (layout: `docs/architecture/testing.md` §Test layout) |
| `host/` | Release project (`mix release` delegates here) |
| `docs/` | Project documentation (architecture, implementation plan, phases, glossary, schema) |
| `docs/architecture/` | Detailed single-topic architecture references |

## Step 1: Read the Architecture Index

Start with `docs/architecture/index.md`. It lists ~10 topic files, each a standalone technical reference covering one architectural aspect. These are the primary knowledge base for agents.

## Step 2: Drill Into Relevant Topics

Based on your task, read the specific architecture doc:

| Task | Read |
|------|------|
| Plugin system, loading model, plugin contracts | `docs/architecture/plugins.md` |
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

## Step 3: Key Subsystems by Domain Layer

### Core

The engine's domain logic. Core boundaries never import from API or Peripheral boundaries.

| Boundary | Purpose |
|-----|---------|
| `BfwEngine.Types` | Behaviour-free structs, shared types, the contract layer |
| `BfwEngine.Execution` | PI/FNI runtime, resume logic, payload cap enforcement |
| `BfwEngine.Events` | EngineEventBus, pending event sweeper |
| `BfwEngine.Timers` | ISO 8601 timer scheduler |
| `BfwEngine.Expressions` | FEEL expression evaluator |
| `BfwEngine.BPMN` | XML parser, ModelCache, linter gate |
| `BfwEngine.DMN` | DMN parser and evaluator |
| `BfwEngine.Plugin`, `BfwEngine.EngineFacade` | Internal plugin contracts |

### Peripheral

Infrastructure adapters. May import Core, never imported by Core.

| Boundary | Purpose |
|-----|---------|
| `BfwEngine.Persistence` | Ash + AshPostgres resources. Mix `bfw.retention.purge` hard-deletes aged terminal PI trees |
| `BfwEngine.Telemetry` | `:telemetry` counters, /stats data |

### Plugins (`lib/bfw_engine/plugins`)

In-BEAM plugin host. May depend on Core and on `BfwEngine.Api`.

| Boundary | Purpose |
|-----|---------|
| `BfwEngine.Plugins` | Plugin registry, in-BEAM loader |

### API

Wire adapters. Thin translation layer between external protocols and `BfwEngine.Api`.

| Boundary | Purpose |
|-----|---------|
| `BfwEngine.Auth` | JWT validation, claim extraction |
| `BfwEngine.Api` | `BfwEngine.Api` service-layer facade — no Phoenix dep |
| `BfwEngineWeb` | REST + GraphQL + WebSocket + Admin |

## Step 4: Core Patterns

The 4 patterns agents encounter most:

### 1. Ash Code Interface as Single Service Layer

`BfwEngine.Api` is the convergence point for all consumers. Every wire adapter (REST, GraphQL, WebSocket) and every in-BEAM plugin calls `BfwEngine.Api.*` actions. No consumer bypasses this layer to call Core directly.

### 2. Dependency Direction

Dependency direction: Core never depends on Peripheral, Plugins, or API. Peripheral depends on Core. Plugins (`BfwEngine.Plugins`) depend on Core and `BfwEngine.Api`. API depends on Core and Peripheral; `BfwEngineWeb` also depends on `BfwEngine.Plugins`. Each boundary root module declares its `deps`; `mix compile` fails on an undeclared edge (table: `docs/Architecture.md` §Subsystem Boundaries).

### 3. EngineEventBus Fan-Out

All engine state changes emit events through the EngineEventBus. Consumers (WebSocket channels, audit logger, telemetry, plugin sinks) subscribe via the EventSink behaviour. The bus is the single source of truth for observability and external integrations.

### 4. Hybrid Plugin Model

v1 loads **in-BEAM OTP-app plugins only**. Downstream consumers (Service Task dispatch, EngineEventBus fan-out) query the registry by capability. Non-Elixir work uses the HTTP Service Task, the public API, or an in-BEAM plugin that execs a local interpreter.
