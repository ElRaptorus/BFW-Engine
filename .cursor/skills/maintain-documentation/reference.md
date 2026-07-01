# Maintaining Documentation — Detailed Reference

## Full Code-Change-to-Documentation Mapping

### Architecture docs (`docs/architecture/`)

| What Changed | Update |
|-------------|--------|
| Plugin system, loading model, SDK packages | `docs/architecture/plugins.md` |
| Database schema, tables, indexes, partitions | `docs/architecture/data-model.md` |
| EngineEventBus, EventSink behaviour, sinks | `docs/architecture/event-system.md` |
| REST/GraphQL/WS endpoints, API surface | `docs/architecture/api.md` |
| JWT auth, claims, PI visibility, lane rules | `docs/architecture/authorization.md` |
| Message/signal/escalation correlation | `docs/architecture/routing.md` |
| FEEL context, bindings, evaluation | `docs/architecture/expressions.md` |
| /stats, /health, /info, logs, metrics | `docs/architecture/observability.md` |
| Docker, docker-compose, zero-downtime deploy | `docs/architecture/shipping.md` |
| Env vars, config priority, linter gate, retention | `docs/architecture/configuration.md` |
| Test infrastructure, scenario matrix, CI pipeline | `docs/architecture/testing.md` |
| JWT auth, transport, plugin trust, threat model | `docs/architecture/security.md` |
| Recurring mistake or non-obvious constraint | `docs/architecture/common-pitfalls.md` |

### Project-level docs (`docs/`)

| What Changed | Update |
|-------------|--------|
| Significant design decision (approach chosen, pattern adopted) | `docs/ImplementationPlan.md` section 0 (decisions table) |
| New BPMN element handler implemented | `docs/ImplementationPlan.md` section 7 (element coverage table) |
| Phase task completed or exit criteria met | `docs/ImplementationPhases.md` |
| New term introduced or existing term redefined | `docs/Glossary.md` |
| Database table added, column changed, index added | `docs/Schema.md` (ER diagram) |
| New architecture topic created | `docs/architecture/index.md` |
| Umbrella app added or renamed | `docs/Architecture.md` (layer diagram) |

## Common Update Patterns

### Creating or modifying a `.bpmn` file

1. The file **must** contain a complete `<bpmndi:BPMNDiagram>` section with shapes and edges (see `.cursor/rules/bpmn-diagram-interchange.mdc` for layout conventions and element sizes)
2. If the file lacks DI, run `python3 scripts/bpmn_add_di.py <path>` to generate coordinates
3. Verify the `<bpmn:definitions>` element declares `xmlns:bpmndi`, `xmlns:dc`, and `xmlns:di`

### Adding a new BPMN element handler

1. Update the element coverage table in `docs/ImplementationPlan.md` section 7
2. If the handler involves a new routing pattern, update `docs/architecture/routing.md`
3. If the handler uses timer scheduling, update `docs/architecture/event-system.md`

### Adding a new API endpoint

1. Add the endpoint to the endpoint table in `docs/architecture/api.md`
2. If it requires new authorization rules, update `docs/architecture/authorization.md`
3. If it introduces a new GraphQL type, update the GraphQL section in `docs/architecture/api.md`

### Adding a new environment variable

1. Add the variable to the env vars table in `docs/architecture/configuration.md`
2. If it affects auth behavior, also update `docs/architecture/authorization.md`

### Adding a new plugin category (behaviour)

1. Add the behaviour to the categories table in `docs/architecture/plugins.md`
2. Update the Plugin Registry section if lookup logic changes
3. If the behaviour emits events, update `docs/architecture/event-system.md`

### Adding a new EventSink

1. Add the sink to the built-in sinks table in `docs/architecture/event-system.md`
2. If it affects observability, also update `docs/architecture/observability.md`

### Schema / migration changes

1. Update field tables in `docs/architecture/data-model.md`
2. Update the ER diagram in `docs/Schema.md`
3. If partitioning or retention changes, also update `docs/architecture/configuration.md`

### Adding a new umbrella app

1. Update the layer diagram in `docs/Architecture.md`
2. Add the app to the umbrella app table in the `project-context.mdc` rule
3. Add the app to the table in the `umbrella-navigation.mdc` rule
4. Update the "Key Apps by Domain Layer" tables in the `understand-codebase` skill

## Verification

After updating, check that:

- `docs/architecture/index.md` still accurately lists all topic files
- Links between docs are not broken (especially `../` relative paths from `docs/architecture/` to `docs/`)
- `docs/Architecture.md` mapping table covers the changed area
- Summary stubs in `docs/ImplementationPlan.md` still accurately describe the content now in architecture docs

## Completeness Check

Ask yourself:
- Would a new developer reading these docs get an accurate picture of the current engine?
- Are there any sections that now describe code that no longer exists?
- Are all new modules, behaviours, endpoints, or patterns documented?
