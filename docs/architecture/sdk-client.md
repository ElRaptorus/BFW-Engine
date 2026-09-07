# SDK & Client Packages

The engine ships two TypeScript npm packages in a pnpm monorepo at `packages/js/`. They provide the public-facing contract and transport layer for JavaScript/TypeScript consumers.

## Package Overview

| Package | npm name | Directory | Runtime deps | Purpose |
|---------|----------|-----------|-------------|---------|
| SDK | `@elraptorus/daemonengine_sdk` | `packages/js/sdk/` | `fast-xml-parser` | Types, errors, events, BPMN parser, DMN parser |
| Client | `@elraptorus/daemonengine_client` | `packages/js/client/` | `@elraptorus/daemonengine_sdk`, `phoenix` | HTTP, GraphQL, WebSocket transport |

## Dependency Direction

```
@elraptorus/daemonengine_client  -->  @elraptorus/daemonengine_sdk
```

The SDK never imports from the client. All contracts (types, error classes, event interfaces, plugin interfaces, GraphQL query option types) live in the SDK. The client is a pure consumer.

## Workspace dependencies

The pnpm workspace root is `packages/js/`. Example packages under `examples/client-js/` and `examples/sdk-js/` are workspace members (they are not published). Shared toolchain versions live in the `catalog:` map in `packages/js/pnpm-workspace.yaml` (`typescript`, `vitest`, `tsx`, `@types/node`, ESLint packages, `prettier`). Members reference them with `"catalog:"` so examples cannot drift onto an older Vitest/Vite line.

TypeScript stays on **6.0.x**. `typescript@7` is on npm `latest`, but `typescript-eslint@8.69.0` peers `typescript: >=4.8.4 <6.1.0`. Do not bump until typescript-eslint widens that range.

The catalog pins **Vitest 5** (`^5.0.0`). Requires Node.js `>=22.12.0` (packages declare `>=24.20.0`) and Vite `>=6.4.0` as a transitive peer. Vitest 5 removed `describe.sequential` / `test.sequential`; client integration suites that must not run concurrently use `describe('…', { concurrent: false }, …)`. Unlike the Studio, SDK/client configs do **not** enable `sequence.shuffle` — tests keep declaration order. `client/vitest.config.ts` keeps `fileParallelism: false`. Artifact output lives under `.vitest/` (gitignored).

`pnpm-lock.yaml` `catalogs.default` must resolve a version that satisfies each catalog specifier. `pnpm ci` (frozen lockfile) fails with `ERR_PNPM_OUTDATED_LOCKFILE` when they disagree. After a catalog bump, run `pnpm update -r <package>` so every importer and the catalog snapshot move together.

TypeScript 6 does not auto-include `@types/*`. Packages that `tsc` Node builtins (`node:fs`, `import.meta.dirname`) set `"types": ["node"]` in their own `tsconfig.json`. That must not go on `packages/js/tsconfig.base.json` — the published SDK/client must not pick up Node globals.

Runtime package versions (not catalogued): SDK `fast-xml-parser` `^5.11.1`; client `phoenix` `^1.8.13`; client test-only `jose` `^6.2.10`.

## SDK Structure (`packages/js/sdk/src/`)

| Directory | Contents |
|-----------|----------|
| `bpmn/` | `parseBpmn()` -- XML parser producing a typed `BpmnDefinitions` from BPMN 2.0 + `evil:*` extensions. Recursively parses embedded subprocess inner scopes (flow nodes, sequence flows, data objects, mappings, contracts) mirroring the Elixir `SaxHandler` pipeline. `SubProcessTypeData` extends `WithMappings & WithContracts`. |
| `dmn/` | `parseDmn()` -- XML parser producing a typed `DmnDefinitions` from DMN 1.5 CL3 models. CL1: decision tables, literal expressions, BKMs, DRG elements, ItemDefinitions, Imports. CL3 (Phase 6): all 10 boxed expression types (`DmnBoxedContext`, `DmnBoxedInvocation`, `DmnBoxedList`, `DmnRelation`, `DmnBoxedConditional`, `DmnBoxedFilter`, `DmnBoxedFor`, `DmnBoxedEvery`, `DmnBoxedSome`, `DmnFunctionDefinition`), `DmnDecisionService`, DMNDI (`DmnDI`, `DmnDiagram`, `DmnShape`, `DmnEdge`). `DmnDecision` uses a unified `expression: DmnExpressionBody` field (structural parity with the Elixir parser). DMNDI is parsed exclusively in the SDK (not engine-side) — the engine preserves raw XML for retrieval and the Studio renders DRD diagrams using the SDK parser. |
| `errors/` | 39 error subclasses extending `DaemonEngineError`. Each carries `statusCode`, `errorCode`, `message`, `rawBody`. Includes 9 DMN-specific errors (8 from Phase 4, plus `DecisionServiceNotFoundError` from Phase 6). |
| `events/` | `EngineEventEnvelope<T>` and 17 discriminated-union event interfaces for WebSocket delivery (includes `DecisionDefinitionDeployed/Undeployed`) |
| `graphql/` | Field, filter, include, sort, and pagination types for the typed GraphQL query builder. Covers BPMN and DMN resources. Filter types include `ilike` for substring matching on string fields. `ProcessVersionField`/`ProcessVersionFilter` and `DecisionVersionField`/`DecisionVersionFilter` support version-specific queries. `ProcessModelInclude`/`DecisionDefinitionInclude` enable nested `versions` relationship loading with field selection, filtering, and sorting. `SelectionField` / `buildFlowNodeSelection` / `buildProcessModelSelection` describe the polymorphic Model graph; empty `on` fragments are omitted so Absinthe does not reject `... on TaskNode { }`. |
| `plugin/` | Behaviour interfaces for plugin development (service task handlers, event sinks, auth providers, etc.) |
| `types/` | Resource types: `ProcessModel`, `ProcessVersion`, `ProcessInstance`, `FlowNodeInstance`, `DataObjectValue`, `DecisionDefinition`, `DecisionVersion`, `EvaluationResult`, `EvaluationTrace`, `DecisionTrace`, `BkmTrace`, `ImportTrace`, `CoercionTrace`, `StartResult`, `DeployResponse`, `DmnDeployResponse`, `StatsResponse`, enums (`DmnHitPolicy`). `ProcessModel` and `DecisionDefinition` include optional `versions?: ProcessVersion[]` / `versions?: DecisionVersion[]` for relationship includes. |

## Client Structure (`packages/js/client/src/`)

| Directory | Contents |
|-----------|----------|
| `http/` | `HttpTransport` -- shared fetch-based transport with JWT injection and error delegation |
| `errors/` | `mapResponseError()` -- maps engine JSON responses to SDK error subclasses (domain code first, then HTTP status fallback) |
| `identity/` | `JwtFactory` type and `resolveToken()` -- resolves static or async token factories |
| `rest/` | Sub-clients: `ProcessClient`, `ProcessInstanceClient`, `UserTaskClient`, `EngineClient`, `EventClient`, `DecisionClient` (includes `evaluateService()` for Decision Service endpoints), `AdHocSubprocessClient` (ad-hoc activity control) |
| `graphql/` | `GraphqlClient` -- typed query builder methods for all resources (`queryProcessModels`, `queryProcessVersions`, `queryProcessInstances`, `queryFlowNodeInstances`, `queryDecisionDefinitions`, `queryDecisionVersions`) plus Model-graph helpers (`getProcessInstanceWithModel`, `getProcessVersionWithModel`, `getFlowNodeInstanceWithModel`); `QueryBuilder` -- generates GraphQL strings from typed options with offset pagination fields (`limit`, `offset`, `hasNextPage`, `hasPreviousPage`, `pageNumber`, `lastPage`), `ilike` filter support, nested include arguments, and inline fragments. Empty `on` fragments are omitted (`... on TaskNode { }` is invalid GraphQL). |
| `ws/` | `NotificationClient` -- Phoenix Channel WebSocket client for real-time events |

## Main Client Class

`DaemonEngineClient` (in `client/src/daemon-engine-client.ts`) wires all sub-clients with a shared `HttpTransport` and `JwtFactory`:

```typescript
const client = new DaemonEngineClient('http://localhost:4100', jwtFactory);
client.processes       // ProcessClient
client.processInstances // ProcessInstanceClient
client.userTasks       // UserTaskClient
client.engine          // EngineClient
client.events          // EventClient
client.decisions       // DecisionClient (DMN)
client.adHocSubprocesses // AdHocSubprocessClient
client.graphql         // GraphqlClient
client.notifications   // NotificationClient
client.dispose()       // disconnect WebSocket
```

The WebSocket URL is derived from the HTTP URL by replacing `http` with `ws` and appending `/socket`.

## Ad-hoc Sub-Process Client

`AdHocSubprocessClient` (`client/src/rest/adhoc-subprocess-client.ts`) wraps the four ad-hoc control endpoints. All methods take the ad-hoc shell's **child process instance ID** (not the parent/shell FNI ID):

| Method | Endpoint | Returns |
|--------|----------|---------|
| `getActivities(processInstanceId)` | `GET /adhoc-subprocesses/{id}/activities` | `AdHocActivity[]` |
| `activate(processInstanceId, activityId)` | `POST /adhoc-subprocesses/{id}/activities/{activityId}/activate` | `AdHocActivateResult` |
| `complete(processInstanceId)` | `POST /adhoc-subprocesses/{id}/complete` | `AdHocCompleteResult` |
| `getStatus(processInstanceId)` | `GET /adhoc-subprocesses/{id}/status` | `AdHocStatus` |

`AdHocActivity`, `AdHocActivateResult`, `AdHocCompleteResult`, and `AdHocStatus` are defined in `sdk/src/types/adhoc-subprocess.ts` and re-exported from `@elraptorus/daemonengine_sdk`. The same four types back the `EngineFacade` plugin methods (`getEnabledActivities`, `activateActivity`, `complete`, `getStatus` in `sdk/src/plugin/engine-facade.ts`) — REST and plugin callers share one contract. `activate()` and `complete()` are used for plugin-managed ad-hoc sub-processes (`implementation` set on the `bpmn:AdHocSubProcess`, AH-D-series); engine-managed mode (no `implementation`) drives the same underlying PI-level operations internally without requiring a caller to invoke this client.

Real-time ad-hoc events (`AdHocActivityActivated`, `AdHocSubProcessCompleted`) are delivered through `client.notifications` (the existing `NotificationClient` WebSocket channel), not through this REST sub-client — see `EvilEngine.Types.Event.AdHoc*` on the engine side and the "Engine Events" table in `AGENTS.md`.

## Error Mapping Pipeline

When the engine returns a non-2xx response, the `HttpTransport` calls `mapResponseError(status, body)`:

1. **Domain code match** (`body.error`): e.g. `"process_not_found"` -> `ProcessNotFoundError`, `"decision_definition_not_found"` -> `DecisionDefinitionNotFoundError`
2. **HTTP status fallback**: e.g. `401` -> `UnauthorizedError`, `403` -> `ForbiddenError`
3. **Catch-all**: base `DaemonEngineError` with raw body preserved

DMN-specific error codes mapped: `decision_definition_not_found`, `decision_definition_disabled`, `dmn_evaluation_error`, `decision_version_not_found`, `dmn_parse_error`, `decision_version_exists`, `dmn_cycle_error`, `bkm_not_found`, `service_not_found`.

The GraphQL client has an additional path: HTTP 200 responses with `errors[]` in the body are mapped through the same `mapResponseError` using the error's `extensions.code` field.

## GraphQL Pagination and Response Conventions

All list queries use **offset pagination** (`limit`/`offset` arguments). The engine responds with a `PageOf<Resource>` type containing `results`, `count`, `hasNextPage`, `hasPreviousPage`, `pageNumber`, `lastPage`, and `limit`. The `GraphqlClient` maps these server-provided fields directly to `OffsetPageInfo` in the SDK.

All GraphQL response keys from the engine use **camelCase** (Absinthe `LanguageConventions` adapter). The `GraphqlClient` maps `count` → `OffsetPageInfo.totalCount` and passes all other offset page metadata fields through directly.

Inline fragments with an empty selection set are invalid GraphQL. `buildFlowNodeSelection` omits `TaskNode` / `ParallelGatewayNode` / `EventBasedGatewayNode` from `on` (those types have no extra fields), and `query-builder.ts` skips any remaining empty `... on Type { }` fragment.

The `FacadeGraphql` interface in the SDK mirrors all `GraphqlClient` methods for plugin developers: `queryProcessModels`, `queryProcessVersions`, `queryProcessInstances`, `queryFlowNodeInstances`, `queryDecisionDefinitions`, `queryDecisionVersions`.

## Authentication

The client injects `Authorization: Bearer <token>` on every request (except `skipAuth` routes like `/health`, `/info`, `/metrics`). The `JwtFactory` is called fresh for each request, enabling automatic token rotation.

## Integration Tests

Integration tests live in `client/test/integration/` and require a live engine (with auth enabled). Key design decisions:

- **JWT minting**: Test-only `jose` devDependency mints HS256 tokens with configurable claims. Never reaches npm (excluded via `"files": ["dist"]`, `.npmignore`, and `devDependencies`).
- **Claim-scoped client factories**: 10+ factory functions (`createAdminClient`, `createReadOnlyClient`, `createLaneClient`, etc.) produce clients with specific claim sets for granular authorization testing.
- **Race-condition-safe user task sync**: `waitForUserTask()` subscribes to the PI's WebSocket channel and waits for the `UserTaskCreated` event, which is only emitted after the FNI is persisted in `waiting` state.
- **BPMN fixtures**: 9 fixtures in `client/test/integration/fixtures/` cover passthrough, user tasks, service tasks, lanes, contracts, call activities, and data objects.
- **DMN integration tests**: `decision-lifecycle.test.ts` covers deploy, catalog CRUD, enable/disable, delete, undeploy, auth rejection, parse errors, and version conflicts. `decision-evaluation.test.ts` covers ad-hoc evaluation, unmatched details, error paths, and Decision Service evaluation via `evaluateService()`. Both require a running engine.
- **Ordered suites**: Lifecycle and claim/security files that share engine state across `it()`s opt out of concurrency with `{ concurrent: false }` (Vitest 5 replacement for `describe.sequential`). Do not add `sequence.shuffle` to those configs.

## DMN evaluation trace types (Phase 7)

Defined in `packages/js/sdk/src/types/dmn-evaluate.ts` and re-exported from `packages/js/sdk/src/index.ts`. REST evaluate responses run `EvaluationResult.to_json_map/1` through `Wire.camelize_keys/1`, so trace fields arrive as camelCase (for example `bkmTraces`, `importTraces`, `inputCoercions`).

| Type | Purpose |
|------|---------|
| `EvaluationResult` | Top-level evaluate response; includes `definitionsId`, `definitionsNamespace`, `decisionVersionId` enrichment fields |
| `DmnServiceEvaluationResult` | Decision Service evaluate response; `serviceId`, `serviceName`, `outputs`, `trace`, `evaluatedAt`, `durationMicroseconds` |
| `EvaluationTrace` | Root trace container: `decisions`, `inputCoercions` |
| `DecisionTrace` | Per-decision trace; includes `bkmTraces`, `importTraces`, `warnings` |
| `BkmTrace` | Recursive BKM invocation trace: `bkmId`, `bkmName`, `formalParameters`, `result`, `durationMicroseconds`, `dependentBkmTraces` |
| `ImportTrace` | Cross-model import trace: `namespace`, `decisionId`, `sourceDefinitionsId`, `evaluationTrace` (full nested trace), `result`, `durationMicroseconds` |
| `CoercionTrace` | Input coercion visibility: `inputName`, `originalValue`, `coercedValue`, `targetType`, `coerced` |

`DmnServiceEvaluationResult` is defined in `packages/js/sdk/src/dmn/model.ts` and exported from the DMN parser model types group. It is returned by `DecisionClient.evaluateService()`.

### `DmnHitPolicy` enum extensions

`DmnHitPolicy` (`packages/js/sdk/src/types/enums.ts`) covers standard decision-table hit policies plus two non-table expression kinds reported in evaluation traces and results:

| Member | Wire value | When used |
|--------|------------|-----------|
| `Literal` | `LITERAL` | Decision value expression is a `<literalExpression>` |
| `BoxedExpression` | `BOXED_EXPRESSION` | Decision value expression is any CL3 boxed expression (`<context>`, `<invocation>`, `<for>`, etc.) |

Existing table hit-policy members (`Unique`, `First`, `Any`, `Collect`, `RuleOrder`, `OutputOrder`, `Priority`) are unchanged. The parser maps XML `hitPolicy` attributes to the table members; `Literal` and `BoxedExpression` are evaluator-assigned on the result/trace, not parsed from decision-table XML.

Note: the `DmnHitPolicy` enum uses **uppercase** wire values (e.g. `UNIQUE`), matching the parser/XML context. However, the Engine's REST evaluation responses emit **lowercase** strings (e.g. `unique`) via `Atom.to_string/1`. The `hitPolicy` field in `EvaluationResult` and `FlowNodeInstance.typeProperties` is a lowercase string, not a `DmnHitPolicy` enum member.

### FNI `typeProperties` casing convention

`FlowNodeInstance.typeProperties` is declared as `Record<string, unknown>` in the SDK. The outer field name is camelCased on REST/GraphQL (`typeProperties`), but **inner keys are opaque** — they pass through `Wire.camelize_keys/1` unchanged, remaining in **snake_case**.

This means the same trace structs appear in two shapes:

| Surface | Keys | Example |
|---------|------|---------|
| REST `/decisions/.../evaluate` response | camelCase | `importTraces`, `decisionId`, `sourceDefinitionsId` |
| FNI `typeProperties.trace` (from DB) | snake_case | `import_traces`, `decision_id`, `source_definitions_id` |

BRT DMN `typeProperties` fields (see `docs/architecture/dmn.md` §`type_properties` for full map): `mode`, `decision_ref`, `decision_version_id`, `definitions_id`, `definitions_namespace`, `version`, `hit_policy`, `matched_rules`, `trace`, `duration_us`.

## DMN Parser Conformance

The SDK DMN parser (`parseDmn`) has its own conformance test suite in `sdk/test/conformance/dmn-parser-conformance.test.ts`. Snapshot JSON files are generated from the Elixir `core_dmn` parser via `scripts/generate-dmn-parser-snapshots.exs`. This ensures the TypeScript and Elixir parsers produce structurally equivalent output for all DMN fixtures.

## CI/CD

`.github/workflows/packages-ci.yml` publishes `@elraptorus/daemonengine_sdk` and `@elraptorus/daemonengine_client` to GitHub Packages. Triggers: GitHub Release `published`, or `workflow_dispatch` (auto-increments the patch version from the registry). All jobs pin `actions/setup-node` to Node.js 24.20. First-party packages declare `engines.node` `>=24.20.0`.

Jobs, in order:

| Job | What it does |
|-----|----------------|
| **lint-build-unit** | `pnpm install --frozen-lockfile`, then lint / build / `test:unit` for the SDK and client packages only (`--filter @elraptorus/daemonengine_sdk --filter @elraptorus/daemonengine_client`) |
| **integration** (needs lint-build-unit) | Compiles a `MIX_ENV=prod` OTP release (Erlang/OTP 29.0.5, Elixir 1.20.3-otp-29, Rust 1.98.0 for the FEEL NIF), migrates Postgres, daemonizes the release on port 4100, runs `pnpm --filter @elraptorus/daemonengine_client run test:integration` |
| **publish** (needs integration) | Resolves version from the release tag or by incrementing the GitHub Packages `pnpm view` result, then `pnpm publish` of SDK then client (`workspace:*` is rewritten to the published SDK version) |

The integration job must install a Rust toolchain. `mix compile` of `core_expressions` builds the Rustler NIF; without `rustc` the release (and therefore publish) fails.
