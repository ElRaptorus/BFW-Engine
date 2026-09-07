---
name: thorough-review
description: >-
  Comprehensive review checklist for ThomasTheDaemonEngine. Covers build
  verification, static analysis, tests, architecture docs freshness, code
  quality spot checks, and documentation integrity. Use when the user asks
  for a "thorough review", "final review", "full review", "verify everything",
  or any similar request to validate the project state.
---

# Thorough Review

When the user requests a thorough review, execute every section below **in order**. Check off each item as you go and report the results at the end.

## 0. Ensure Test Database (MANDATORY prerequisite)

**Before anything else**, follow the `ensure-test-db` skill to verify that the
PostgreSQL Docker container (`evil-engine-postgres-test`) is running and
accepting connections. The quality gate includes integration tests and coverage
collection — both require a live database.

**It is NOT acceptable to skip this step and report "PostgreSQL is not running"
as a reason for incomplete verification.**

## 1. Quality Gate

```bash
mix quality
```

This single command runs the full pipeline defined in the root `mix.exs`: compile (warnings-as-errors), Credo, Dialyzer, Sobelow, unit tests with coverage, integration tests, and conformance tests. The canonical definition lives in `mix.exs` — **do not duplicate the individual steps here**; always run `mix quality` so the skill stays in sync with any future changes to the pipeline.

Must exit 0. If any step fails, report the failing step, the error output, and stop.

### Coverage checks

After the quality gate passes, verify coverage in the output:

- [ ] No per-app threshold failures
- [ ] Global aggregate meets the `minimum_coverage` in `coveralls.json`
- [ ] No newly added module shows 0 % coverage
- [ ] If coverage is below threshold, identify uncovered modules and recommend tests

## 2. Architecture Documentation

- [ ] All new or modified subsystems are reflected in the **one** appropriate file under `docs/architecture/`
- [ ] `docs/architecture/index.md` lists all topic files (no missing entries)
- [ ] `docs/architecture/common-pitfalls.md` updated **only** if a competent person could hit the constraint again (not CI/test incident reports)
- [ ] `docs/decisions.md` updated **only** if a significant A-vs-B choice was made
- [ ] No architecture doc describes code that no longer exists
- [ ] Do **not** append `docs/poc/ImplementationPlan.md` or `docs/poc/ImplementationPhases.md` (archival)
- [ ] `AGENTS.md` updated **only** if `evil:*` elements, supported BPMN types, validator rules, FEEL bindings, or umbrella apps changed
- [ ] `apps/api_web/priv/openapi/spec.yaml` matches the actual REST API surface: every route in the router has a corresponding path entry, and no stale operations reference removed endpoints. Compare `spec.yaml` paths against the routes in `apps/api_web/lib/evil_engine_web/http/router.ex`

## 3. Code Quality Spot Check

Reference rule: `.cursor/rules/elixir-conventions.mdc` — read it before starting this section.

### Structural conventions

- [ ] **Dependency direction**: Core apps do not import from Peripheral or API apps. Peripheral apps do not import from API apps.
- [ ] **Ash conventions**: Resources follow `actions`, `attributes`, `relationships`, `code_interface` block order. Code interface actions match the resource's action names.
- [ ] **Module structure order**: `@moduledoc`, `@behaviour`, `use`/`import`/`alias`, module attributes, public functions, private functions.

### Design principles (elixir-conventions §Design Principles)

- [ ] **KISS**: No premature abstractions — behaviours/protocols only when there are 2+ implementations today.
- [ ] **DRY**: No duplicated logic across modules. Shared constants extracted to module attributes.
- [ ] **No magic values**: No unexplained literal strings or numbers. Constants extracted to `@module_attribute`. (Exceptions: `0`, `1`, `""`, `[]`, `%{}`, `nil`, `true`, `false`.)
- [ ] **Early exit**: No deeply nested `if`/`case`/`cond`. Multi-step error handling uses `with` chains. Guard clauses preferred over conditional bodies.
- [ ] **Named functions over long branches**: No `case`/`cond` branches exceeding ~5 lines inline — extract to named private functions.
- [ ] **Single responsibility**: No God Modules (>10 public functions, or `@moduledoc` needs "and" to describe purpose).

### Naming & documentation

- [ ] **No abbreviations**: Identifiers use full descriptive names (`process_instance`, not `pi`; `flow_node_instance`, not `fni`).
- [ ] **`@moduledoc` present**: Every module has a `@moduledoc` explaining its purpose.
- [ ] **`@doc` on public, never on private**: Every public function has a `@doc` string. No `@doc` on private functions.
- [ ] **No narrating comments**: No comments that describe *what* the code does (`# Return the result`). Comments only explain *why*.

### Function style

- [ ] **Tagged tuple returns**: All public functions return `{:ok, value}` or `{:error, reason}` — no bare values or raises for expected failures. Consistent within each module.
- [ ] **`@impl true`**: Every behaviour callback implementation is annotated with `@impl true`.
- [ ] **No single-pipe**: `value |> function()` is written as `function(value)` instead.
- [ ] **`with` chains**: `with` is only used when there are 2+ clauses. Single-clause `with` is rewritten as `case`.
- [ ] **Multi-clause ordering**: Most specific pattern match first, catch-all last.

## 4. Documentation Cross-References

- [ ] `docs/architecture/index.md` topic list matches the actual files in the folder
- [ ] Links between architecture docs are not broken (grep for `](` patterns pointing to nonexistent files)
- [ ] `docs/decisions.md` links to the owning architecture file
- [ ] `docs/Glossary.md` "See also" table entries point to correct paths
- [ ] `docs/Architecture.md` mapping table references correct architecture docs

## 5. Engine SDK & Client Integrity (MANDATORY)

The TypeScript SDK (`packages/js/sdk/`) and Client (`packages/js/client/`) **MUST be kept in sync** with the Engine's state. This section is non-optional. Skipping it is a review failure.

### 5a. Build & test both packages

```bash
cd packages/js/sdk  && pnpm run build && pnpm exec vitest run test/unit
cd packages/js/client && pnpm run build && pnpm exec vitest run test/unit
cd packages/js/client && pnpm exec vitest run test/integration   # requires a live engine
```

All builds must succeed with zero TypeScript errors. All tests must pass (intentional `.skip`/`.todo` are acceptable only when explicitly approved by the user).

### 5b. Error code coverage

- [ ] Every `error` code the Engine can return (check `apps/api_web/` controllers, plugs, `error_response.ex`, and GraphQL `errors.ex`) has a matching `case` branch in the Client's `error-mapper.ts`
- [ ] The Client normalizes GraphQL error codes from `UPPER_SNAKE_CASE` to `lower_snake_case` before matching (the Engine upcases codes in `to_graphql_error/1`)
- [ ] Every SDK error class in `packages/js/sdk/src/errors/` is imported and used by the Client mapper
- [ ] New engine error codes added since the last review are represented by a dedicated SDK error class or explicitly mapped to a generic one

### 5c. Type alignment

- [ ] SDK types (`packages/js/sdk/src/types/`) reflect the JSON response shapes from every REST controller (`format_*/camelize_keys`) and GraphQL resource
- [ ] Fields the Engine sends but the SDK omits are flagged — either add them or document why they are intentionally excluded
- [ ] GraphQL field types (`ProcessModelField`, `ProcessInstanceField`, etc.) list every scalar field exposed by the corresponding Ash resource

### 5d. REST route coverage

- [ ] Every route in `apps/api_web/lib/evil_engine_web/http/router.ex` has a corresponding method in the Client's REST sub-clients
- [ ] Client methods that call routes not yet implemented in the Engine are documented as future/planned (not silently present)
- [ ] HTTP methods match (GET vs HEAD, POST vs PUT, etc.)

### 5e. SDK exports

- [ ] `packages/js/sdk/src/index.ts` re-exports all public types, error classes, enums, and utilities
- [ ] `packages/js/client/src/index.ts` re-exports all public client classes and utilities
- [ ] No internal-only types leak into the public barrel exports

## 6. BPMN File Integrity

- [ ] Every `.bpmn` file contains a `<bpmndi:BPMNDiagram>` section with shapes and edges
- [ ] All `<bpmn:definitions>` elements declare the `bpmndi`, `dc`, and `di` namespaces
- [ ] Every flow node has a corresponding `<bpmndi:BPMNShape>` entry
- [ ] Every sequence flow has a corresponding `<bpmndi:BPMNEdge>` entry

Quick scan:

```bash
# Files missing DI (should return zero results):
rg -L '<bpmndi:BPMNDiagram' --glob '*.bpmn' .
```

If any file lacks DI, run `python3 scripts/bpmn_add_di.py <path>` to add coordinates.

## 7. Report

After completing **all** sections above (including §5 — SDK & Client Integrity and §6 — BPMN File Integrity), provide a structured summary:

```
## Review Summary

### Passed
- [list of checks that passed]

### Issues Found
- [list of issues with severity: Critical / Important / Minor]

### Recommendations
- [list of suggested improvements, if any]
```
