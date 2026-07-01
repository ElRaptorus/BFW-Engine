# GraphQL API Reference

Endpoint: `POST /api/v1/graphql`

GraphQL Playground: `/admin/graphiql` (devtools-only — disabled in prod unless `EVIL_DEVTOOLS_ENABLED=true`; pre-loaded with example query tabs)

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

Filters are type-safe and composable. Each attribute generates a typed filter input (e.g. `ProcessInstanceFilterState` for enum fields, `ProcessInstanceFilterStartedAt` for datetime fields).

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
    state: { eq: RUNNING },
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
      state: { in: [RUNNING, WAITING] },
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

## Mutations

No GraphQL mutations are currently implemented. Process operations and user task interactions are available exclusively via the [REST API](rest-reference.md).

## Subscriptions

GraphQL subscriptions are not currently implemented. For real-time event streaming, use the [WebSocket API](websocket.md) (Phoenix Channels).

## Response Format

All response keys use **camelCase** (Absinthe `LanguageConventions` adapter). GraphQL query field names accept both camelCase and snake_case, but responses are always camelCase.

## Related

- [REST API Reference](rest-reference.md) -- process operations, user task actions
- [Authentication](authentication.md) -- JWT requirements
- [WebSocket API](websocket.md) -- real-time event streaming
