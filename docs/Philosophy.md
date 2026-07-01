# Philosophy

## The Engine Is Not the Product

The engine is infrastructure. It executes BPMN 2.0 workflows — faithfully,
fast, and without opinion on who is watching.

A workflow engine has no users in the traditional sense. It has consumers:
frontends, services, IoT devices, CLI tools, other engines. The moment an
engine assumes a specific frontend, it begins to calcify around that
assumption. Every API decision, every event shape, every error message
becomes coupled to one consumer's expectations.

## Frontend-Agnostic

ThomasTheDaemonEngine is built frontend-agnostic by design. Other applications, like a BPMN modeller, are first-class consumers, but not privileged ones. The REST surface, the GraphQL schema, the WebSocket event stream, and the plugin contract are all designed
so that a team could build an entirely different frontend — or no frontend
at all — and lose nothing.

This means: no UI-specific fields on API responses, no "convenience" endpoints
that only make sense for one particular client, no event payloads shaped to
fit a React component tree. The engine speaks BPMN, not Studio.

## Domain-Driven Boundaries

The codebase is split along domain boundaries, not technical layers.

A traditional layered architecture — `controllers/`, `services/`, `models/` —
puts all persistence in one place, all business logic in another. This makes
it trivially easy to create hidden couplings: the timer service imports the
message service, the message service imports the execution service, and soon
everything depends on everything.

Instead, each domain owns its own vertical slice: types, logic, persistence
adapter, API surface. The BPMN parser knows nothing about persistence. The
execution runtime knows nothing about HTTP. The plugin registry knows nothing
about GraphQL. They communicate through well-defined contracts — behaviours,
events, configuration — never by importing each other's internals.

The dependency direction is strict and inward:

```
API → Peripheral → Core
```

Core domains never import from API or Peripheral. This is not a suggestion.
Dialyzer and the compilation order enforce it structurally.

## Performance Through Simplicity

The engine does not use an external task queue, a separate message broker,
or a distributed cache. Each process instance is a `gen_statem` process on
the BEAM. Flow node execution is a function call. Event dispatch is a
GenServer cast. Model lookup is an ETS read.

This is not premature optimisation — it is the absence of premature
abstraction. A workflow engine's hot path is: look up the model, evaluate a
condition, advance a token, persist state. Every layer of indirection added
to that path — an HTTP call to an external service, a serialisation round-trip
through a message queue, a distributed lock acquisition — adds latency and
failure modes that the engine must then work around.

By keeping the hot path in-process and in-memory, the engine can focus its
complexity budget on the things that actually matter: correct BPMN semantics,
crash isolation, and observable state transitions.

When the single-node ceiling is eventually reached, clustering is a separate
phase (Phase 6) with its own design — not a premature architectural tax
imposed on every request from day one.

## Encounter-Time Validation, Not Pre-Flight Linting

The engine does not reject a BPMN model because it contains an anti-pattern.
That is the Studio linter's job, and it can be opted-in at deploy time.

At runtime, the engine validates locally: when a flow node completes, the
engine checks whether the outgoing sequence flows are unambiguous. If a
non-gateway task has multiple outgoing flows (an implicit split), the FNI
transitions to `fatal` at that moment — not before. If a task has zero
outgoing flows (a dead end), the same thing happens.

This means a user can deploy and run a partially complete BPMN diagram
during development. The anti-pattern only causes an error when it is
actually encountered. This is the pragmatic middle ground between "reject
everything the linter dislikes" and "silently do something undefined".

## Data Contracts, Not Smart Objects

BPMN models are data. Tokens are data. Event payloads are data. Plugin
capabilities are data.

The engine represents these as plain structs — `%EvilEngine.BPMN.Model.Process{}`,
`%EvilEngine.Execution.Token{}`, `%EvilEngine.Types.Event.FlowNodeInstanceStarted{}`. They
have no methods, no inheritance hierarchies, no mutable state. They are
validated at the boundary (parsing, API ingestion, plugin registration) and
trusted thereafter.

This makes them trivially serializable, trivially testable, and trivially
inspectable. A token payload is a map. An event is a struct. A BPMN model
is a tree of structs. There is no hidden state, no lazy loading, no proxy
objects that might behave differently depending on context.

When something needs to _act_ on data — execute a flow node, evaluate a FEEL
expression, persist a state change — that responsibility belongs to a
dedicated module with a clear API, not to the data itself.

## No Assumptions, No Rstrictions

By design, the Engine and its Flow Node Handlers don't care _how_ you feed them the data they need.
They only care about that data being complete and correct.

The guiding principle is:

> I hand you the contract, you give me the data. How you do that, is entirely up to you.

By that principle, the Engine gives you everything you need, to control and interact with your processes and everything you need to create whatever auditability you require.
But _if_ and _how_ you implement any of it, will be entirely up to you.

- Service Tasks give you a Data Contract, but remain ignorant on how that data is delivered.
- User Tasks give you a Data Contract and a rough Form Input Definition, nut remain ignorant as to how you provide the User Input.
- The Event Sink provides you with all the data you need to create an Audit trail, but if and how you do that, is entirely up to you

## Plugins Over Features

Not every capability belongs in the engine's core. Nothing illustrates this as prominently as the Service Task.

There are a multitude of ways, by which a Service Task could be handled: Messagebus, HTTP, gRPC, or even the ungodly External Task Pattern, to name a few.

Including any of these by default, would violate the `no assumptions, no restrictions` philsophy, because the Engine would suddenly make demands on _how_ data should be provided. Instead, Service Task handling is fully delegated to plugins.

This is a deliberate architectural choice: the engine provides the dispatch
mechanism (the `ServiceTaskDispatch` behaviour and the plugin registry), and
plugins provide the implementation. The built-in HTTP Service Task handler is an example
and a default, not a blessed path. Consider it a freebee.

That said, even the HTTP Service Task handler is a **plugin** — it ships with the engine, but it
lives in in the Plugin Registry, **not the Core**. A team that wants to
replace it with their own HTTP client, or that needs a handler for RabbitMQ,
gRPC, or a proprietary message bus, can register their own handler under a
custom `implementation` key without touching engine code.

The same principle extends to Event Sinks. The engine publishes typed events
to the `EngineEventBus`. Where those events go — console, database,
telemetry counters, WebSocket, a custom analytics pipeline — is decided by
the sinks registered at boot time. The engine does not know and does not
care.

The plugin contract is designed around two constraints:

1. **Plugins must never reach into the engine's internals.** They interact
   exclusively through the `EngineFacade` — a struct injected at load time
   that exposes a curated set of capabilities. If a plugin needs something
   the facade doesn't offer, that's a signal to extend the facade, not to
   break encapsulation.

2. **Plugin failures must not compromise the engine.** A plugin that crashes
   during `on_load` is quarantined. A plugin whose Service Task handler
   panics causes exactly one FNI to fail — the PI may transition to `fatal`,
   but the engine itself keeps running. This is OTP's "let it crash"
   philosophy applied at the integration boundary.

## Let It Crash — But Know What Crashed

Elixir and OTP provide extraordinary fault isolation. A process crash is
contained, supervised, and restarted. But "let it crash" is not "let it
fail silently".

Every crash, every quarantine, every fatal FNI transition produces a typed
event on the `EngineEventBus`. These events carry structured metadata — the
process instance ID, the flow node ID, the error reason, the timestamp. They
reach every registered sink: the console logger, the telemetry counters, the
WebSocket stream, and (if enabled) the database audit log.

The philosophy is: **crash isolation for resilience, event emission for
observability.** The engine recovers automatically. The operator knows exactly
what happened and where.

## FEEL the Force

The engine uses FEEL (Friendly Enough Expression Language) as its sole
expression language. There is no embedded Elixir evaluation, no JavaScript
engine, no custom DSL.

FEEL is evaluated through a Rust NIF wrapping the `dsntk` crate. Expressions
are compiled at deploy time and evaluated at runtime against a fixed context
shape with exactly seven root bindings: `token`, `this`, `context`,
`dataObjects`, `process`, `processInstance`, `identity`. No more, no less.

This constraint is deliberate. A fixed context surface means every FEEL
expression is deterministic given its inputs. There are no ambient variables,
no global state, no side effects. An expression evaluated today produces the
same result as the same expression evaluated tomorrow, given the same context.
