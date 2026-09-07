# Thomas the Khornate Daemon Engine

<div align="center">
  <img src="./assets/ThomasTheDaemonEngine.png" alt="" width="400">
</div>

> **The Heresy Train has no Brakes.**

## What is this Heresy?

A BPMN 2.0 workflow engine written in Elixir / OTP and oceans of sacrificial blood and skulls dedicated to Khorne.

Used to run awesome stuff created with the [Forge World Studio](https://github.com/ElRaptorus/BFW-Studio)

- **BPMN & DMN Spec Coverage**: see [Supported Elements](./docs/SupportedElements.md)
- **User Manual & API Reference**: see [Documentation](#documentation) below.
- **Philosophy**: see [docs/Philosophy.md](./docs/Philosophy.md).
- **Architecture**: see [docs/Architecture.md](./docs/Architecture.md).
- **Configuration**: see [docs/architecture/configuration.md](./docs/architecture/configuration.md).
- **Load benchmarks**: see [docs/benchmarks/](./docs/benchmarks/README.md).
- **Post v1 Ideas**: see [docs/post-v1-ideas](./docs/post-v1-ideas.md).

---

## Requirements

- Elixir 1.20.3 / OTP 29 (see `.tool-versions`)
- Erlang 29
- Rust 1.98+ (Required for FEEL evaluator)

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
