# Thomas the Khornate Daemon Engine

<div align="center">
  <img src="./assets/ThomasTheDaemonEngine.png" alt="" width="400">
</div>

> **The Heresy Train has no Brakes.**

## What is this Heresy?

A BPMN 2.0 workflow engine written in Elixir / OTP and oceans of sacrificial blood and skulls dedicated to Khorne.

Used to run awesome stuff created with the [Forge World Studio](https://github.com/ElRaptorus/BFW-Studio)

- **User Manual & API Reference**: see [Documentation](#documentation) below.
- **Philosophy**: see [docs/Philosophy.md](./docs/Philosophy.md).
- **Architecture**: see [docs/Architecture.md](./docs/Architecture.md).
- **Configuration**: see [docs/architecture/configuration.md](./docs/architecture/configuration.md).
- **Load benchmarks**: see [docs/benchmarks/](./docs/benchmarks/README.md).

---

## Requirements

- Blood
- Skulls
- Elixir 1.20.3 / OTP 29 (see `.tool-versions`)
- Erlang 29
- Blood
- Rust 1.98+ (Required for FEEL evaluator)
- Skulls

`asdf` is recommended, but not strictly necessary.

## Getting started

```bash
# Prerequisite: Install Elixir, Erlang and Rust
asdf install

# 1. Install and compile deps
mix deps.get
mix deps.compile

# 2. Compile (every app)
mix compile
```

## Running locally (docker-compose)

The dev compose stack contains an Engine and a Postgres DB.
Prometheus scrape is `GET /metrics` (on by default via `TDE_METRICS_ENABLED`). OpenTelemetry does not ship yet.

```bash
docker compose up --build
```

- Engine (HTTP, GraphQL, WebSocket): [http://localhost:4000](http://localhost:4000)
- Postgres: `localhost:5432` (db: `evil_engine_dev`, user/pw: `evil_engine`)

## Documentation

The project ships with a full user manual, API reference, plugin development
guide, and operations handbook — all generated as a searchable static HTML
site via ExDoc.

### Building the docs

```bash
MIX_ENV=dev mix docs
```

This produces the documentation under `manual/`. Open `manual/index.html` in a
browser, or serve it locally with a http server of your choice.

### Documentation structure

| Section                | Content                                                                         |
| ---------------------- | ------------------------------------------------------------------------------- |
| **Getting Started**    | Overview, quickstart, core concepts                                             |
| **User Handbook**      | Everything you need to know about the Engine, written from a users perspective. |
| **API Reference**      | REST endpoints, GraphQL schema, authentication, WebSocket channels              |
| **Plugin Development** | Behaviours, engine facade, service task handlers, event sinks, built-in plugins |
| **Operations Guide**   | Deployment, database admin, security, observability, troubleshooting            |
| **Load benchmarks**    | Curated reports of a few load tests ([docs/benchmarks/](./docs/benchmarks/README.md)) |
| **Cheatsheets**        | Environment variables, API endpoints, plugin behaviours                         |

The docs include full-text search and are navigable by use case (e.g., "I
want to implement a Service Task handler" → Plugin Development → Service
Task Handler).

---

## BPMN 2.0 Element Support

The table below lists every BPMN 2.0 element the engine recognises, grouped
by category.
Each of these Elements has full Runtime support.

### Activities

| Element                | Notes                                                                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Task (Untyped)         | Pass-through                                                                                                                     |
| User Task              | Defines User Forms, Actions and Assignees. Waits for User Input                                                                  |
| Manual Task            | Either pass-through, or optional `requires confirmation` to wait for manual user continuation                                    |
| Service Task           | Plugin-driven Service dispatch; built-in HTTP default handler; always `asynchronous`                                             |
| Script Task            | Inline FEEL evaluation or plugin dispatch. Always `synchronous`                                                                  |
| Business Rule Task     | Either simple FEEL Expression, or full `DMN` execution                                                                           |
| Send Task              | Publishes messages for 1:1 and deterministic 1:n communication                                                                   |
| Receive Task           | Receives messages, with optional process-level correlation                                                                       |
| Call Activity          | Executes a target process and waits for the result                                                                               |
| Sub Process (Embedded) | Inline-Subprocess. Semantically similar to Call Activity, but restricted to one untyped Start Event. Re-uses the parent's lanes. |
| Multi-Instance         | Includes Standard Loop, Sequential and Parallel MI                                                                               |

### Subprocesses

| Element           | Notes                                                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Event Subprocess  | Interrupting + Non-Interrupting, triggered by a single typed Start Event                                                                                                              |
| Transaction       | `All or nothing` style Subprocess. Always succeeds or fails as a whole. Can use `Cancel` Events for premature cancelling and rolling back the subprocess and triggering compensation. |
| Ad Hoc Subprocess | An unstructured Activity "Menu", where users can pick the tasks to execute.                                                                                                           |

### Gateways

| Element             | Notes                                                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Exclusive Gateway   | Split evaluates FEEL conditions with optional default path, Join is pass-through                                                                       |
| Event-Based Gateway | First Catch Event to trigger wins, all others get interrupted.                                                                                         |
| Parallel Gateway    | Split activates all outgoing paths, Join waits for ALL incoming tokens before continuing                                                               |
| Inclusive Gateway   | Split activates all outgoing paths with a matching condition; Join waits for all incoming paths, with dead-path awareness.                             |
| Complex Gateway     | Like Inclusive Gateways, but Splits disallow unconditional flows; Joins fire once, when condition is fulfilled and kills all remaining incoming paths. |

### Start Events

| Element | Notes                                                                                                                                                                                       |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Untyped | Normal Entry Point for a BPMN Process Instance                                                                                                                                              |
| Timer   | Automated Process Start via Cyclic, Date or Duration Timers                                                                                                                                 |
| Message | Automated Process Start, when a Message is received. Correlation-aware; only triggers if no Message Catch Event in the same process listens for the same message with the same correlation. |
| Signal  | Automated Process Start, when a Signal is received                                                                                                                                          |

#### Start Events - Event Subprocess only

| Element      | Notes                                   |
| ------------ | --------------------------------------- |
| Conditional  | Triggers when a FEEL condition is met.  |
| Error        | Triggers when an Error is caught.       |
| Escalation   | Triggers when an Escalation is caught.  |
| Compensation | Triggers when a Compensation is caught. |

**Note:** Event Subprocesses can use _all_ Typed Start Events, but _not_ The Untyped Start Event. The exact opposite of Embedded Subprocesses.

### End Events

| Element      | Notes                                                                                                                                                             |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Untyped      | Finishes a single process path normally                                                                                                                           |
| Terminate    | Terminates all remaining parallel Paths                                                                                                                           |
| Message      | Publishes message and finishes the process path                                                                                                                   |
| Signal       | Publishes signal and finishes the process path                                                                                                                    |
| Error        | Terminates all remaining paths and throws an `Error`. The error propagates to the parent process and can be caught by an `Error Boundary Event`.                  |
| Escalation   | Finishes a single process path and triggers an `Escalation`. The escalation propagates to the parent process and can be caught by an `Escalation Boundary Event`. |
| Compensation | Triggers compensation for completed activities in the current scope, then finishes the PI with `Compensated` state                                                |
| Cancel       | `Transaction` only. Cancels a Transactional Subprocess.                                                                                                           |

### Intermediate Catch Events

| Element     | Notes                                                      |
| ----------- | ---------------------------------------------------------- |
| Untyped     | Pass-through                                               |
| Link        | Landing pad for Link Throw with the same name              |
| Timer       | Duration and Date Timers, FEEL Expression Support          |
| Message     | Receives messages, with optional process-level correlation |
| Signal      | Receives signal broadcasts from any source                 |
| Conditional | FEEL-based condition                                       |

### Intermediate Throw Events

| Element      | Notes                                                                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Link         | Resolves matching Link Catch by name within the same process                                                                                |
| Message      | Publishes messages for 1:1 and deterministic 1:n communication                                                                              |
| Signal       | Publishes signals for non-deterministic broadcasts                                                                                          |
| Escalation   | Propagates escalation to the parent without terminating the current process; PI continues normally after the throw                          |
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

| Element               | Notes                                                                              |
| --------------------- | ---------------------------------------------------------------------------------- |
| Sequence Flow         | Connects 2 Flow Nodes                                                              |
| Conditional Flow      | FEEL-based condition, used by forking Exclusive- and Inclusive Gateways            |
| Data Associations     | Input or Output Variants. Links Flow Nodes to a Data Object and vice versa         |
| Data Object           | DOA-driven writes, value contracts, FEEL reads, full write history for audit trail |
| Data Object Reference | Visual Data Object representation                                                  |
| Association           | Links compensation boundary events to their handler activities                     |

---

## DMN 1.5 Support

The engine includes a full DMN 1.5 Conformance Level 3 (CL3) decision
engine in the `core_dmn` umbrella app. DMN models are deployed independently
or alongside BPMN diagrams and evaluated via Business Rule Tasks or the
REST API.

### Decision Elements

| Element                  | Notes                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------- |
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

| Feature                  | Notes                                                                                                             |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| Business Rule Task (DMN) | `implementation="dmn"` + `evil:decisionRef` + optional `evil:decisionElementId`                                   |
| REST Deploy              | `POST /decisions` — batch deploy DMN XML sources                                                                  |
| REST Evaluate            | `POST /decisions/:id/evaluate` — ad-hoc evaluation outside of BPMN                                                |
| REST Decision Services   | `POST /decisions/:id/services/:sid/evaluate`                                                                      |
| Plugin Observation       | `FlowNodeInstanceFinished` events carry `type_properties` with full DMN trace for event sinks                     |
| Plugin Facade            | `facade.decisions.*` — deploy, evaluate, list, get, enable/disable, get_xml, evaluate_service                     |
| Execution Trace          | Structured `EvaluationTrace` with per-decision timing, BKM traces, import traces, coercion log                    |
| TypeScript SDK/Client    | Full CL3 type definitions in `@elraptorus/daemonengine_sdk`; evaluate/deploy in `@elraptorus/daemonengine_client` |

---

## Want to contribute something?

Cool.
Just follow these simple guiding principles, when opening PRs:

- Best way would be to fork the repo, do your stuff and then create a PR pointing back here.
- Run `mix quality` **BEFORE** commiting anything. Saves us all a lot of time and nerves
- The CI must be green. **No exceptions.**
- Your PR must be detailed enough to see, why you made the change, what need it fulfilles and why the Engine needed this (TL;DR: Why should I merge this?)

### Quality Tools

When you want to verify a change, use these commands to ensure the integrity of a branch:

```bash
# If you installed or updated something, make sure it is actually safe.
mix deps.audit

# Compile
mix compile

# Format and lint
mix format --check-formatted
mix credo --strict
mix sobelow

# Dialyzer (first run builds PLT, which takes a few minutes)
mix dialyzer

# Run Tests
mix test.all              # every app's tests
mix test apps/core_bpmn   # one app (here: "core_bpmn")
mix coveralls.html        # HTML coverage report under cover/
```

> **Note:** The entire quality gate can be run with the combined command `mix quality`.

### Test suite

| Layer                 | Command                | Coverage                                                                                                                                                                                                                                                                                                                                                                                                            |
| --------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Unit tests**        | `mix test`             | 900+ tests across all umbrella apps. Covers types, BPMN parser/validator, FEEL expressions, DMN parser/evaluator, PI/FNI state machine, etc.                                                                               |
| **Integration tests** | `mix test.integration` | 600+ full-stack tests with DB. Each test runs the entire Toolchain, from HTTP API to Persistence Layer, as a normal end user would.  |
| **Conformance tests** | `mix test.conformance` | 170+ tests driven by YAML specs for each supported Element.                                                                          |
| **Load tests**        | `mix test.load`        | Standalone load tests (linear through mixed BPMN, DMN 10–500 rules). Full API lifecycle, 10–10,000 process instances. Durability (20k / 50k / 100k): `mix test.load.durability` (that file only). Hardening (LZ4 vs PGLZ, payload-cap chaos, resume-crash): `mix test.load.hardening`. `mix test.load.all` is default + durability + hardening (one JSON). Local / large-runner only; GitHub `load-bench` runs `mix test.load` only. |
| **Coverage**          | `mix coveralls.html`   | Creates a HTML coverage report under `cover/`       |

---

## License

MIT
