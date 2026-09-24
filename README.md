# Bifrost Forge World Engine

> Toll the great Bell once! Pull the lever forward, to engage the Piston and Pump!\
> Toll the great Bell twice! With the push of the Button, fire the Engine and spark the Turbine into life!\
> Toll the great Bell Thrice! Sing praise to the God of all Machines!
>
> Ave Deus Mechanicus

## What is this?

A BPMN 2.0 workflow engine written in Elixir / OTP and sanctified oils and pistons from the holy [Forges of Mars](https://wh40k.lexicanum.com/wiki/Adeptus_Mechanicus).

> **Current Project Status: Beta. Feture complete, but not yet battle-tested.**

Used to run awesome stuff created with the [Forge World Studio](https://github.com/ElRaptorus/BFW-Studio)

- **User Manual & API Reference**: see [Documentation](#documentation) below.
- **BPMN & DMN Spec Coverage**: see [Supported Elements](./docs/SupportedElements.md)
- **Configuration**: see [docs/architecture/configuration.md](./docs/architecture/configuration.md).
- **Philosophy**: see [docs/Philosophy.md](./docs/Philosophy.md).
- **Architecture**: see [docs/Architecture.md](./docs/Architecture.md).
- **Load benchmarks**: see [docs/benchmarks/](./docs/benchmarks/README.md).

---

## Requirements

- Elixir 1.20 / OTP 29 (see `.tool-versions`)
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
Prometheus scrape is `GET /metrics` (on by default via `BFE_METRICS_ENABLED`).

```bash
docker compose up --build
```

- Engine (HTTP, GraphQL, WebSocket): [http://localhost:4000](http://localhost:4000)
- Postgres: `localhost:5432` (db: `bfw_engine_dev`, user/pw: `bfw_engine`)

## Documentation

The project ships with a full user manual, API reference, plugin development
guide, and operations handbook — all generated as a searchable static HTML
site via ExDoc.

### Building the docs

```bash
MIX_ENV=dev mix docs
```

This produces the documentation under `manual/`. Open `manual/index.html` directly, or serve it with an http server of your choice.

### Documentation structure

| Section                | Content                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------- |
| **Getting Started**    | Overview, quickstart, core concepts                                                   |
| **User Handbook**      | Everything you need to know about the Engine, written from a users perspective.       |
| **API Reference**      | REST endpoints, GraphQL schema, authentication, WebSocket channels                    |
| **Plugin Development** | Behaviours, engine facade, service task handlers, event sinks, built-in plugins       |
| **Operations Guide**   | Deployment, database admin, security, observability, troubleshooting                  |
| **Load benchmarks**    | Curated reports of a few load tests ([docs/benchmarks/](./docs/benchmarks/README.md)) |
| **Cheatsheets**        | Environment variables, API endpoints, plugin behaviours                               |

The docs include full-text search and are navigable by use case (e.g., "I
want to implement a Service Task handler" → Plugin Development → Service
Task Handler).

---

### Quality Tools

The following commands are used to ensure branch integrity:

```bash
# If you installed or updated something, make sure it is actually safe.
mix deps.audit

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

### Test coverage

| Layer                 | Command                | Coverage                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Unit tests**        | `mix test`             | 2,800+ tests across all umbrella apps. Covers types, BPMN parser/validator, FEEL expressions, DMN parser/evaluator, PI/FNI state machine, etc.                                                                                                                                                                                                                                                                                       |
| **Integration tests** | `mix test.integration` | 800+ full-stack tests with DB. Each test runs the entire Toolchain, from HTTP API to Persistence Layer, as a normal end user would.                                                                                                                                                                                                                                                                                                  |
| **Conformance tests** | `mix test.conformance` | 210+ tests driven by YAML specs for each supported Element.                                                                                                                                                                                                                                                                                                                                                                          |
| **Load tests**        | `mix test.load`        | Standalone load tests (linear through mixed BPMN, DMN 10–500 rules). Full API lifecycle, 10–10,000 process instances. Durability (20k / 50k / 100k): `mix test.load.durability` (that file only). Hardening (LZ4 vs PGLZ, payload-cap chaos, resume-crash): `mix test.load.hardening`. `mix test.load.all` is default + durability + hardening (one JSON). Local / large-runner only; GitHub `load-bench` runs `mix test.load` only. |
| **Coverage**          | `mix coveralls.html`   | Creates a HTML coverage report under `cover/`                                                                                                                                                                                                                                                                                                                                                                                        |

---

## License

MIT
