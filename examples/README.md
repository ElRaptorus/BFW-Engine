# ThomasTheDaemonEngine — Examples

Ready-to-use examples covering plugin development, the TypeScript Client, and the TypeScript SDK.

## Quick Navigation

### Elixir Plugin Examples (`plugins/`)

Copy-paste starters for building in-BEAM plugins. Each contains `lib/`, `test/`, optional `bpmn/` fixtures, and a `README.md`. No `mix.exs` — integrate into your own OTP app.

#### Auth Providers

| Example | Description |
|---------|-------------|
| [`auth_providers/ldap`](plugins/auth_providers/ldap/) | LDAP-based `AuthProvider` with identity mapping |
| [`auth_providers/companygraph`](plugins/auth_providers/companygraph/) | REST API-based `AuthProvider` stub |

#### Service Task Handlers

All Service Task handlers follow the async-only contract: `handle_enter/3` returns `{:async, flow_node_instance_id}` and the handler completes later via `finish_async` / `fail_async`.

| Example | Description |
|---------|-------------|
| [`service_task_handlers/echo`](plugins/service_task_handlers/echo/) | Minimal "hello world" — echoes input as output |
| [`service_task_handlers/http_enrichment`](plugins/service_task_handlers/http_enrichment/) | Calls an external HTTP API to enrich the payload |
| [`service_task_handlers/redis_cache`](plugins/service_task_handlers/redis_cache/) | Reads/writes Redis (stubbed) |
| [`service_task_handlers/async_webhook_callback`](plugins/service_task_handlers/async_webhook_callback/) | Parks the FNI, completes via HTTP callback |
| [`service_task_handlers/async_rabbitmq_roundtrip`](plugins/service_task_handlers/async_rabbitmq_roundtrip/) | Request-reply pattern with RabbitMQ (stubbed) |

#### Event Sinks

| Example | Description |
|---------|-------------|
| [`event_sinks/datadog_metrics`](plugins/event_sinks/datadog_metrics/) | Batched metric push to DataDog HTTP API (stubbed) |
| [`event_sinks/webhook_forwarder`](plugins/event_sinks/webhook_forwarder/) | Forwards events as JSON webhook POSTs |
| [`event_sinks/structured_logger`](plugins/event_sinks/structured_logger/) | Structured JSON log lines to stdout or file |

#### Named Scripts

| Example | Description |
|---------|-------------|
| [`named_scripts/custom_validators`](plugins/named_scripts/custom_validators/) | Multiple validation/transformation scripts in one plugin |
| [`named_scripts/local_script_runner`](plugins/named_scripts/local_script_runner/) | Execute local script files from the host filesystem (⚠️ security notes) |

#### Lifecycle & API Access

| Example | Description |
|---------|-------------|
| [`lifecycle_and_api/lifecycle_aware`](plugins/lifecycle_and_api/lifecycle_aware/) | Demonstrates `on_load`/`on_ready`, config reading, engine identity |
| [`lifecycle_and_api/api_consumer`](plugins/lifecycle_and_api/api_consumer/) | Uses the `EngineFacade` to deploy, start, query, and finish user tasks |
| [`lifecycle_and_api/github_bpmn_deployer`](plugins/lifecycle_and_api/github_bpmn_deployer/) | Fetches `.bpmn` files from a GitHub repo and auto-deploys them at engine startup |

#### Combined / Advanced

| Example | Description |
|---------|-------------|
| [`combined/rabbitmq_to_engine`](plugins/combined/rabbitmq_to_engine/) | RabbitMQ subscriber → process start → custom event publishing |
| [`combined/metrics_pipeline`](plugins/combined/metrics_pipeline/) | Event sink + service task handler sharing state via ETS |
| [`combined/incident_reporter`](plugins/combined/incident_reporter/) | Incident reporting EventSink + bus-driven RetryConsumer for PI retry. Standalone Mix project with pluggable `MessageBus.Adapter` |

#### Business Rules (DMN observation & analysis)

Plugins that observe Business Rule Task execution via events and analyze results via the facade. BRT execution is exclusively handled by the engine's built-in `"feel"` and `"dmn"` modes — plugins never replace the execution path.

| Example | Difficulty | Pattern | Description |
|---------|------------|---------|-------------|
| [`business_rules/decision_kpi_calculator`](plugins/business_rules/decision_kpi_calculator/) | Simple | Event Sink | Real-time KPIs from BRT decision executions |
| [`business_rules/explain_decision`](plugins/business_rules/explain_decision/) | Simple | Named Script | Human-readable decision explanation from trace |
| [`business_rules/decision_trace_publisher`](plugins/business_rules/decision_trace_publisher/) | Intermediate | Event Sink | Publish BRT decision audit data to external systems |
| [`business_rules/decision_service_smoke_tester`](plugins/business_rules/decision_service_smoke_tester/) | Intermediate | Lifecycle & API | Auto-verify Decision Services on engine startup (CL3) |
| [`business_rules/decision_regression_tester`](plugins/business_rules/decision_regression_tester/) | Intermediate | Lifecycle & API | Compare DMN versions for regression detection |
| [`business_rules/dead_rule_detector`](plugins/business_rules/dead_rule_detector/) | Complex | Lifecycle & API | Analyze rule coverage across multiple PI executions |
| [`business_rules/drd_chain_orchestrator`](plugins/business_rules/drd_chain_orchestrator/) | Complex | Lifecycle & API | Multi-decision DRD with BKM reuse (CL3) |
| [`business_rules/boxed_expression_showcase`](plugins/business_rules/boxed_expression_showcase/) | Complex | Lifecycle & API | All CL3 boxed expression types in one model |

---

### TypeScript Client Examples (`client-js/`)

Standalone Node.js projects demonstrating the `@elraptorus/daemonengine_client` package. Each has `package.json`, `tsconfig.json`, `src/main.ts`, and a `test/` directory. **Requires a live engine** (`docker compose up`).

| Example | Description |
|---------|-------------|
| [`deploy-and-start`](client-js/deploy-and-start/) | Deploy a BPMN, start a process instance |
| [`process-lifecycle`](client-js/process-lifecycle/) | Full lifecycle: deploy → start → poll → abort → delete |
| [`user-task-workflow`](client-js/user-task-workflow/) | Start process, find waiting user task, finish it, verify completion |
| [`graphql-queries`](client-js/graphql-queries/) | Filtering, sorting, pagination, field selection, includes |
| [`error-handling`](client-js/error-handling/) | Typed error handling with `try/catch` for every error class |
| [`realtime-monitoring`](client-js/realtime-monitoring/) | WebSocket event subscription and real-time state tracking |
| [`batch-deploy`](client-js/batch-deploy/) | Multi-process deployment, version management, enable/disable |
| [`dmn-deploy-and-evaluate`](client-js/dmn-deploy-and-evaluate/) | Deploy a DMN decision table, evaluate with inputs, inspect result and trace |
| [`business-rule-task-trace`](client-js/business-rule-task-trace/) | Deploy DMN + BPMN, run process with BRT, query decision trace via GraphQL |

---

### TypeScript SDK Examples (`sdk-js/`)

Standalone Node.js projects demonstrating the `@elraptorus/daemonengine_sdk` package. **No running engine needed.**

| Example | Description |
|---------|-------------|
| [`parse-bpmn`](sdk-js/parse-bpmn/) | Parse BPMN XML and inspect the typed model AST |
| [`type-safe-payloads`](sdk-js/type-safe-payloads/) | Build type-safe request payloads with SDK types and enums |
| [`error-hierarchy`](sdk-js/error-hierarchy/) | Error class hierarchy, `instanceof` patterns, error properties |
| [`parse-dmn`](sdk-js/parse-dmn/) | Parse DMN XML and inspect the typed decision table model AST |

---

### JS Sidecar Plugin Examples (`sidecar-js/`)

Forward-looking Node.js sidecar plugins built against the `@elraptorus/daemonengine_sdk` gRPC interface. Unit-tested with a mocked SDK — live integration requires the gRPC sidecar bridge from BPMN Implementation Phase 5 (see `docs/ImplementationPhases.md`).

| Example | Difficulty | Pattern | Description |
|---------|------------|---------|-------------|
| [`decision-analytics`](sidecar-js/decision-analytics/) | Intermediate | gRPC Event Stream | Real-time decision analytics from NodeJS sidecar |
| [`decision-audit-reporter`](sidecar-js/decision-audit-reporter/) | Complex | gRPC Full Stack | Comprehensive post-execution audit with event + API queries |

---

## Getting Started

### Plugin examples

1. Browse the example that matches your use case
2. Copy the `lib/` files into your own OTP application
3. Set `:plugin_module` in your app's config
4. Add your app to `EVIL_PLUGINS_INBEAM`
5. See each example's README for detailed steps

### JS Client/SDK examples

```bash
cd examples/client-js/deploy-and-start   # or any example
pnpm install
pnpm start                                # requires a live engine for client-js examples
pnpm test                                 # run tests
```

For client-js examples, set `ENGINE_URL` and `ENGINE_TOKEN` environment variables.

## Further Reading

- [Plugin Architecture](../docs/architecture/plugins.md) — full plugin system documentation
- [Event System](../docs/architecture/event-system.md) — EngineEventBus and sink semantics
- [API Reference](../docs/architecture/api.md) — REST, GraphQL, and WebSocket contracts
- [Execution Architecture](../docs/architecture/execution.md) — service task handler lifecycle
- [DMN Architecture](../docs/architecture/dmn.md) — parser model, deployment, evaluation, and plugin integration
- [`@elraptorus/daemonengine_sdk`](../packages/js/sdk/) — TypeScript SDK including the forward-looking sidecar plugin interface
