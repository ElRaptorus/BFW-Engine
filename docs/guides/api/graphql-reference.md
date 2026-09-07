# GraphQL API Reference

Endpoint: `POST /api/v1/graphql`

GraphQL is **strictly query-only**. All commands are REST (and the plugin facade). Real-time events use Phoenix Channels — see [WebSocket API](websocket.md).

GraphQL Playground: `/admin/graphiql` (devtools-only — disabled in prod unless `TDE_DEVTOOLS_ENABLED=true`; pre-loaded with example query tabs)

Authentication: same JWT as REST — see [Authentication](authentication.md).

## Queries

AshGraphql auto-generates queries for each Ash resource. Every list query supports filtering, sorting, and offset pagination.

| Query | Resource | Description |
|-------|----------|-------------|
| `processes` | `Process` | Deployed process catalog |
| `processVersions` | `ProcessVersion` | All process versions, with optional `bpmnXml` |
| `processInstances` | `ProcessInstance` | PI list with state, timestamps, `finalTokens` |
| `flowNodeInstances` | `FlowNodeInstance` | FNI list with state, tokens |
| `decisionDefinitions` | `DecisionDefinition` | Deployed DMN decision catalog |
| `decisionVersions` | `DecisionVersion` | All decision versions, with optional `dmnXml` |
| `dataObjectValues` | `DataObjectValue` | Data object current values |
| `dataObjectHistory` | `DataObjectHistoryEntry` | Data object write history |

Each list query also has a corresponding `get*` query for fetching a single record by ID (e.g. `getProcess(id: ID!)`, `getProcessInstance(id: ID!)`).

### Pagination

All list queries use **offset pagination** via `limit`/`offset` arguments. Each page response is a `PageOf<Resource>` type with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `results` | `[Resource!]` | Records in the current page |
| `count` | `Int` | Total matching rows across all pages (respects active filters) |
| `hasNextPage` | `Boolean` | True if more results exist beyond this page |
| `hasPreviousPage` | `Boolean` | True if offset > 0 |
| `pageNumber` | `Int` | 1-based current page number |
| `lastPage` | `Int` | Total number of pages |
| `limit` | `Int` | Page size applied |

```graphql
# Page 1
query {
  processInstances(limit: 25) {
    results { id state startedAt }
    count
    hasNextPage
    pageNumber
    lastPage
  }
}

# Page 3
query {
  processInstances(limit: 25, offset: 50) {
    results { id state startedAt }
    count
    hasNextPage
    hasPreviousPage
    pageNumber
    lastPage
  }
}
```

### Filtering

Filters are type-safe and composable. Each attribute generates a typed filter input (e.g. `ProcessInstanceFilterState` for the `state` string field, `ProcessInstanceFilterStartedAt` for datetime fields).

**`state` and `flowNodeType` are strings**, not GraphQL enums. Use lowercase quoted values that match persistence (`"running"`, `"waiting"`, `"user_task"`, `"end_event"`). `RUNNING` / `WAITING` / `USER_TASK` are not valid filter literals.

**Filter operators by type:**

| Attribute type | Available operators |
|----------------|---------------------|
| String | `eq`, `notEq`, `in`, `ilike`, `like`, `isNil` |
| Enum | `eq`, `notEq`, `in`, `isNil` |
| DateTime | `eq`, `notEq`, `lessThan`, `greaterThan`, `lessThanOrEqual`, `greaterThanOrEqual`, `isNil` |
| Boolean | `eq`, `isNil` |
| UUID / ID | `eq`, `notEq`, `in`, `isNil` |

The `ilike` operator performs **case-insensitive substring matching** (equivalent to SQL `ILIKE '%value%'`). Use it for free-text search fields like names and IDs:

```graphql
query {
  processes(filter: { name: { ilike: "order" } }) {
    results { id name enabled }
    count
  }
}
```

Multiple filter fields are combined with AND logic:

```graphql
query {
  processInstances(filter: {
    state: { eq: "running" },
    startedAt: { greaterThan: "2026-01-01T00:00:00Z" }
  }) {
    results { id state startedAt }
    count
  }
}
```

### Sorting

Sort by one or more fields using the `sort` argument. Each sort input has a `field` (enum) and `order` (`ASC` or `DESC`):

```graphql
query {
  processInstances(
    sort: [{ field: STARTED_AT, order: DESC }],
    limit: 25
  ) {
    results { id state startedAt }
    count
  }
}
```

### Relationship Includes

Some resources expose relationships that can be queried inline. For example, `processes` can include their `versions`:

```graphql
query {
  processes {
    results {
      id
      name
      enabled
      versions {
        id
        version
        deployedAt
      }
    }
    count
  }
}
```

Nested relationship queries support their own `filter` and `sort` arguments.

### Authorization

GraphQL queries enforce visibility via Ash policies. The caller's JWT identity is wired as the Ash actor:

- **Process Instances** — visible if the caller started the PI, or holds a lane claim matching at least one FNI within the PI (or FNIs without a lane), or has `zeeky_boogie_doog=true`
- **Flow Node Instances** — visibility cascades from the parent PI. If the PI is invisible, its FNIs are also invisible.

Invisible records are simply omitted from query results (no error).

### Final Tokens

`ProcessInstance.finalTokens` is a derived field:

- **`finished` PI** -- ordered list of End Event results
- **`running` or terminal-error PI** -- `null`

### Complete Example

```graphql
query FilteredInstances($offset: Int) {
  processInstances(
    filter: {
      state: { in: ["running", "fatal"] },
      startedAt: { greaterThan: "2026-06-01T00:00:00Z" }
    },
    sort: [{ field: STARTED_AT, order: DESC }],
    limit: 25,
    offset: $offset
  ) {
    results {
      id
      state
      startedAt
      processId
      businessKey
      finalTokens
    }
    count
    hasNextPage
    hasPreviousPage
    pageNumber
    lastPage
  }
}
```

## Process Model graph

Alongside the persistence resources above, the deployed BPMN process definition itself is queryable as a structured GraphQL graph — no client-side XML parsing required. Full type reference: [`architecture/api.md`](../../architecture/api.md) §10.2.2.

Two new fields tie into the existing resources:

| Field | On | Returns |
|-------|----|---------|
| `processModel` | `ProcessVersion` | The parsed process (`ProcessModel`) — `null` if `ModelCache.fetch/1` returns `:not_found` (source XML gone). Zero or multiple executable processes in the document is a GraphQL error, not null. |
| `flowNode` | `FlowNodeInstance` | The BPMN model node this instance ran (`FlowNode`) — `null` if the FNI's owning PI is invisible to the caller, or if the node id is not in the version's flat index |
| `processVersion` | `FlowNodeInstance` | The `ProcessVersion` this instance's process was deployed from |

`FlowNode` is a GraphQL **interface** with one concrete type per BPMN element kind (`UserTaskNode`, `ServiceTaskNode`, `CallActivityNode`, `SubProcessNode`, ...). Selecting element-specific fields requires an inline fragment:

```graphql
query DebuggerView($piId: ID!) {
  getProcessInstance(id: $piId) {
    id
    state
    processVersion {
      id
      bpmnXml                      # still fed to bpmn-js for the canvas
      processModel { id name correlationKey }
    }
    flowNodeInstances {
      id
      state
      flowNode {
        id
        name
        type
        ... on UserTaskNode    { formSchema resultContract }
        ... on ServiceTaskNode { implementation httpUrl httpMethod }
        ... on CallActivityNode { calledElement }
      }
    }
  }
}
```

`ProcessModel.flowNodes` returns the top-level tree (nested `SubProcessNode.flowNodes` recurses into embedded/event/ad-hoc/transaction subprocess scopes); `ProcessModel.allFlowNodes` returns every flow node across every scope as a flat list, each entry carrying `parentSubProcessId` — use this when you need to look up a node by ID without walking the tree yourself.

**Batching:** requesting `flowNode` for many `FlowNodeInstance`s that share one `ProcessVersion` (e.g. every FNI of a single process instance, the debugger's access pattern) issues exactly one lookup for that version, not one per FNI.

**TypeScript client.** `@elraptorus/daemonengine_client`'s `GraphqlClient` exposes dedicated methods that pre-build the field selection for you:

```typescript
const version = await client.graphql.getProcessVersionWithModel(versionId, { fields: ['id', 'version'] });
const fni = await client.graphql.getFlowNodeInstanceWithModel(fniId, { fields: ['id', 'state'] });
const instance = await client.graphql.getProcessInstanceWithModel(processInstanceId, { fields: ['id', 'state'] });
```

Building your own selection set for the `FlowNode` interface (rather than using the methods above) requires the `SelectionField` type from `@elraptorus/daemonengine_sdk`, which supports inline fragments via an `on` key:

```typescript
import type { SelectionField } from '@elraptorus/daemonengine_sdk';

const flowNodeSelection: SelectionField = {
  name: 'flowNode',
  fields: ['id', 'name', 'type'],
  on: {
    UserTaskNode: ['formSchema', 'resultContract'],
    ServiceTaskNode: ['implementation', 'httpUrl', 'httpMethod'],
  },
};
```

## Safety limits

| Env var | Default | Meaning |
|---------|---------|---------|
| `TDE_GRAPHQL_MAX_DEPTH` | `16` | Max field nesting. Sized for recursive `SubProcessNode.flowNodes`. |
| `TDE_GRAPHQL_MAX_COMPLEXITY` | `10000` | Max query complexity. Paginated lists score as `limit × child fields`. Sized for the Studio debugger `dataObjectValues(limit: 500)` snapshot (~6500). |
| `TDE_GRAPHQL_INTROSPECTION_DISABLED` | `false` | When `true`, `__schema` / `__type` are rejected. |

Exceeding depth or complexity returns a GraphQL error (`GraphqlDepthLimitError` / `GraphqlComplexityLimitError` in the TypeScript SDK). Limits are read at request time — no recompile required.

## Mutations

GraphQL is **query-only**. Process operations and user task interactions are available exclusively via the [REST API](rest-reference.md). There are no GraphQL mutations.

## Subscriptions

GraphQL has **no** subscriptions. For real-time event streaming, use the [WebSocket API](websocket.md) (Phoenix Channels).

## Response Format

All response keys use **camelCase** (Absinthe `LanguageConventions` adapter). GraphQL query field names accept both camelCase and snake_case, but responses are always camelCase.

## Related

- [REST API Reference](rest-reference.md) -- process operations, user task actions
- [Authentication](authentication.md) -- JWT requirements
- [WebSocket API](websocket.md) -- real-time event streaming
- [`architecture/api.md`](../../architecture/api.md) §10.2.2 -- full Process Model graph type reference and implementation invariants
