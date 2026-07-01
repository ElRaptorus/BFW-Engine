---
name: architecture-docs
description: >-
  Write and extend architecture documentation in docs/architecture/.
  Use when creating a new architecture doc, restructuring an existing one,
  or adding a new subsystem section. Covers structure, formatting conventions,
  and style rules established across the existing documents.
---

# Architecture Documentation

Architecture docs live in `docs/architecture/`, one file per topic area, listed in `docs/architecture/index.md`. They are technical references for agents — not tutorials, not high-level overviews (those belong in `docs/Concept.md` and `docs/Architecture.md`).

For **when** to update docs, see the workspace rule `maintain-architecture-docs.mdc`.

## Document Structure

Every architecture doc follows this skeleton:

```markdown
# Topic Name

---

## Overview
(3-4 sentences: what the subsystem is, what problem it solves, key dependencies)

## Architecture
(Layer diagrams, module descriptions with #### sub-headings, tables for structured data)

## Public API / Contracts
(Behaviour callbacks, Ash Code Interface actions, or wire-protocol definitions)

## File Path Reference
(Table mapping modules to umbrella app paths)
```

Use `---` horizontal rules between major sections.

### Section Hierarchy

- `##` for top-level sections (Overview, Architecture, Contracts, File Path Reference)
- `###` for subsections within (Core Layer, Peripheral Layer, API Layer)
- `####` for individual modules, behaviours, or concepts within a subsection

Every `####` heading should start with a **Path:** line when documenting a specific module:

```markdown
#### PluginRegistry

**Path:** `apps/peripheral_plugins/lib/peripheral_plugins/registry.ex`

GenServer holding the canonical plugin map. Key responsibilities:

- **Registration**: accepts plugin metadata from both in-BEAM and gRPC loaders
- **Lookup**: capability-based queries used by Service Task dispatch and event fan-out
- **Quarantine**: marks plugins as unhealthy after repeated failures
```

## Formatting Rules

### Tables over bullet lists

When listing items with structured attributes (name + description, name + type + purpose), use a table:

```markdown
| Event | Purpose |
|-------|---------|
| `process_instance:started` | PI moved to `active` state |
| `flow_node_instance:completed` | FNI finished execution |
```

Reserve bullet lists for unstructured enumerations or short lists (< 5 items).

### Prose length

- **Module descriptions**: 3-6 lines max. Use bullet points for key responsibilities.
- **Component descriptions in tables**: One sentence per row.
- **Section intros**: 1-2 sentences before diving into sub-headings.
- **No "wall of text"**: If a paragraph exceeds ~5 lines, break it into bullets, a table, or sub-headings.

### Code examples

Include 1-3 Elixir snippets per document showing key API patterns (behaviour callbacks, Ash actions, function signatures). Keep snippets 5-15 lines. Example:

```markdown
#### EventSink Behaviour

Every sink implements:

\`\`\`elixir
@callback handle_event(event :: EngineEvent.t(), config :: map()) ::
            :ok | {:error, term()}
\`\`\`
```

### ASCII diagrams

Use ASCII box diagrams for layer/flow visualizations. Keep them concise:

```
┌─────────────────────────┐
│       API Layer          │
├─────────────────────────┤
│    Peripheral Layer      │
├─────────────────────────┤
│       Core Layer         │
└─────────────────────────┘
```

### File Path Reference

Every document ends with a table mapping modules to their file paths:

```markdown
## File Path Reference

| Module | Path |
|--------|------|
| PluginRegistry | `apps/peripheral_plugins/lib/peripheral_plugins/registry.ex` |
| GrpcBridge | `apps/peripheral_plugins/lib/peripheral_plugins/grpc_bridge.ex` |
```

## Content Guidelines

### What belongs in architecture docs

- File paths, type specifications, callback signatures
- Event flows and data models
- Relationships between modules and umbrella apps
- Supervision trees, GenServer interactions, process topology
- Key algorithms that affect the subsystem's design (e.g., escalation propagation, message correlation)

### What does NOT belong

- Step-by-step tutorials (use skills for that)
- High-level product concept (that's `docs/Concept.md`)
- System-level overview diagrams (that's `docs/Architecture.md`)
- Every internal helper function — only document what is architecturally significant
- Redundant explanations of the same concept in multiple sections

### Depth calibration

Give proportional depth to each concept. A core algorithm (message correlation) deserves a paragraph. A pass-through module deserves one table row. Signs of miscalibration:

- A one-line concept gets a full paragraph → trim to a table row
- A complex algorithm is buried in a bullet list → promote to its own `####` section
- Multiple sections explain the same supervision tree → consolidate into one and cross-reference

## Documentation Mapping Table

Use this table to determine **which file to update** based on what you changed or learned:

| What changed | Update |
|-------------|--------|
| Plugin system, loading model, SDK packages | `plugins.md` |
| Database schema, tables, indexes, partitions | `data-model.md` |
| EngineEventBus, EventSink behaviour, sinks | `event-system.md` |
| REST/GraphQL/WS endpoints | `api.md` |
| JWT auth, claims, PI visibility, lane rules | `authorization.md` |
| Message/signal/escalation correlation | `routing.md` |
| FEEL context, bindings, evaluation | `expressions.md` |
| /stats, /health, /info, logs, metrics | `observability.md` |
| Docker, docker-compose, zero-downtime deploy | `shipping.md` |
| Env vars, config priority, linter gate, retention | `configuration.md` |
| Test infrastructure, scenario matrix, CI pipeline | `testing.md` |
| JWT auth, transport, plugin trust, input validation, threat model | `security.md` |
| Recurring mistake or non-obvious constraint | `common-pitfalls.md` |
| Significant design decision | `ImplementationPlan.md` section 0 |

If the change does not fit any existing file, create a new one (see below).

## Adding a New Document

1. Create `docs/architecture/<topic>.md` following the skeleton above
2. Add a one-line entry to `docs/architecture/index.md` under **Topics**
3. Format the index entry as: `- **[topic.md](topic.md)** — Brief description of contents`

## Reference: Established Documents

Study these as style references before writing:

- `docs/architecture/plugins.md` — Good example of behaviour tables, lifecycle phases, ASCII flow diagram, and gRPC protocol details
- `docs/architecture/authorization.md` — Good example of claim dictionary tables, decision rationale, and cross-references to ImplementationPlan.md decisions
- `docs/architecture/data-model.md` — Good example of schema tables, partitioning rationale, and cross-reference to Schema.md
- `docs/architecture/event-system.md` — Good example of concise document with layered architecture and sink behaviour definition
- `docs/architecture/testing.md` — Good example of scenario matrix, assertion framework, and exhaustive integration test specification
- `docs/architecture/security.md` — Good example of threat model table, per-surface security controls, and explicit non-goals with workarounds
