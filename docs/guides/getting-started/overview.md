# Overview

Bifrost Forge World Engine is a BPMN 2.0 workflow engine built on Elixir/OTP, designed for embedding into larger platforms via REST, GraphQL, and WebSocket APIs. It extends standard BPMN with the `bfw:` XML namespace (`https://bifrostforge.world/schema/bpmn`) for features like version management, plugin dispatch, user task contracts, and correlation keys.

## Key Capabilities

- **BPMN Execution** -- process flows with Start Events, End Events, Tasks, User Tasks, Manual Tasks, Service Tasks, Script Tasks, Business Rule Tasks, Exclusive Gateways, Call Activities, Link Events, Error Boundary Events, and Data Objects (see the [element support table](#current-element-support) below)
- **DMN 1.5 CL3** -- full DMN decision engine with all 7 hit policies, all 10 boxed expression types, DRD chaining, BKM invocation, Decision Services, and cross-model imports
- **FEEL Expressions** -- DMN-spec expression language evaluated via a Rust NIF for high throughput
- **Plugin System** -- extensible via `@behaviour` modules. Live capabilities: Service Task handlers, Event Sinks, Named Scripts, Auth Providers, RestApiExtension.
- **REST + GraphQL APIs** -- trigger-style REST for all commands, AshGraphql for read-only queries and the Process Model graph
- **WebSocket** -- Phoenix Channels for real-time event streaming
- **PostgreSQL Persistence** -- Ash framework with partitioned audit tables. Opt-in PI-tree hard-delete via `mix bfw.retention.purge`; engine-audit cleanup is operator SQL.
- **JWT Authentication** -- HS256, RS256, ES256, and JWKS with claim-based authorization; pluggable Auth Provider for custom identity resolution
- **PI Retry** -- retry failed or aborted process instances with optional version migration and checkpoint reset.
- **Back-Pressure** -- three-layer overload protection: PI admission control, start rate limiting, and overload signaling

## Architecture at a Glance

The engine is one Elixir OTP application whose subsystems are organized into five layers:

| Layer | Subsystems | Purpose |
|-------|-------------|---------|
| **Wire** | `BfwEngineWeb` | REST + GraphQL + Channels + Swagger UI |
| **Plugin host** | `BfwEngine.Plugins` | Plugin registry and in-BEAM loader |
| **API** | `BfwEngine.Api`, `BfwEngine.Auth` | Service-layer facade, JWT |
| **Peripheral** | `BfwEngine.Persistence`, `BfwEngine.Telemetry` | Database, metrics |
| **Core** | `BfwEngine.Types`, `BfwEngine.Execution`, `BfwEngine.Expressions`, `BfwEngine.BPMN`, `BfwEngine.DMN`, `BfwEngine.Timers`, `BfwEngine.Events`, plus the plugin contracts `BfwEngine.Plugin` and `BfwEngine.EngineFacade` | Domain logic, runtime, FEEL evaluation, BPMN parsing, DMN evaluation, the behaviours plugins implement |

Dependencies flow strictly inward: each layer depends only on the layers below it, and Core depends on nothing outside Core. The compiler enforces these edges ([Architecture](../../Architecture.md)).

## Current Element Support

See the [Supported Elements](../../SupportedElements.md) catalogue for a full list of all supported BPMN and DMN elements.

## Where to Go Next

- [Quickstart](quickstart.md) -- set up the engine and run your first process
- [Core Concepts](concepts.md) -- BPMN primer, `bfw:` extensions, FEEL bindings
- [User Handbook](../handbook/deploying-processes.md) -- use-case-driven guides for everyday tasks
- [DMN Decisions](../handbook/dmn-decisions.md) -- deploy and evaluate DMN decision models
- [API Reference](../api/rest-reference.md) -- REST and GraphQL endpoint documentation
- [Plugin Development](../plugins/getting-started.md) -- build custom handlers and sinks
- [Operations Guide](../operations/deployment.md) -- deploy, configure, and monitor the engine
