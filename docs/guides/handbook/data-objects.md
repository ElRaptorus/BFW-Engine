# Data Objects

Data Objects are named data containers scoped to a process instance. They provide a mechanism for flow nodes to share structured data beyond the token payload.

## Writing to Data Objects

Data Object writes are driven exclusively by `<bpmn:dataOutputAssociation>` elements on flow nodes. When a flow node completes successfully, the engine evaluates each DOA and writes the resulting value to the target Data Object.

### Default Write (Full Token)

When a DOA has no `<bpmn:transformation>` element, the flow node's entire output token is written:

```xml
<bpmn:serviceTask id="Task_1" name="Process Order">
  <bpmn:dataOutputAssociation id="DOA_1">
    <bpmn:targetRef>OrderDataRef</bpmn:targetRef>
  </bpmn:dataOutputAssociation>
</bpmn:serviceTask>
```

### FEEL Expression Write

Use `<bpmn:transformation>` to project a subset of the output token:

```xml
<bpmn:dataOutputAssociation id="DOA_2">
  <bpmn:targetRef>OrderDataRef</bpmn:targetRef>
  <bpmn:transformation>token.payment_result</bpmn:transformation>
</bpmn:dataOutputAssociation>
```

## Reading Data Objects

Data Objects are readable via FEEL expressions anywhere in the process using the `dataObjects` binding:

```
dataObjects.DO_OrderData.status
```

`<bpmn:dataInputAssociation>` elements are parsed and stored on the model for BPMN fidelity (Studio can render visual arrows), but at runtime the engine does NOT gate execution on DIA presence. Any FEEL expression can read any Data Object via `dataObjects.<id>.<property>`.

Reading an unset Data Object yields `null`.

## Value Contracts

Attach an `<bfw:valueContract>` JSON Schema to a `<bpmn:dataObject>` to validate every write:

```xml
<bpmn:dataObject id="DO_OrderData" name="OrderData">
  <bpmn:extensionElements>
    <bfw:valueContract>{"type":"object","required":["status","amount"]}</bfw:valueContract>
  </bpmn:extensionElements>
</bpmn:dataObject>
```

If the written value violates the schema, the write is rejected and the flow node instance transitions to `fatal`. No snapshot or audit row is produced for the failed write.

## In-Memory Cache

Each process instance maintains an in-memory cache of Data Object values (`data_object_cache`). FEEL reads go through this cache — they never hit the database. The cache is updated atomically with each successful DOA write.

On engine restart, the cache is rehydrated from the `data_objects` snapshot table.

## Storage Model

| Table | Purpose |
|-------|---------|
| `data_objects` | Current snapshot — one row per Data Object per PI, holding the latest value |
| `data_object_writes` | Append-only audit log of every write, recording who wrote what and when |

Both tables share the same unified column set: `id`, `process_instance_id`, `data_object_id`, `flow_node_instance_id`, `value`, `created_at`. Both tables are always populated (the audit trail is not optional).

## GraphQL Queries

```graphql
query {
  dataObjectValues(filter: {processInstanceId: {eq: "pi-uuid"}}) {
    results {
      id
      dataObjectId
      flowNodeInstanceId
      value
      createdAt
    }
  }

  dataObjectHistory(filter: {processInstanceId: {eq: "pi-uuid"}}) {
    results {
      dataObjectId
      flowNodeInstanceId
      value
      createdAt
    }
  }
}
```

Nested access via process instance:

```graphql
query {
  getProcessInstance(id: "pi-uuid") {
    dataObjectValues { dataObjectId value createdAt }
  }
}
```

## Events

Each successful write emits an `Event.DataObjectWritten` event via the EngineEventBus, containing the process instance ID, data object ID, write ID, previous value (computed from in-memory cache), value, and created_at timestamp.

## Error Handling

DOA failures are fatal to the flow node instance:

- **Value contract violation**: FNI → `fatal`, no write persisted
- **FEEL expression error**: FNI → `fatal`, no write persisted
- **PayloadCap exceeded**: FNI → `fatal`, no write persisted
- **DB write failure**: FNI → `fatal`, entire transaction rolled back

When a flow node has multiple DOAs, they are evaluated sequentially. If any evaluation fails, the FNI transitions to `fatal` immediately — no writes reach the database.

All Data Object writes and the FNI state transition to `finished` are persisted in a **single database transaction**. If the transaction fails for any reason (DB error, constraint violation), everything rolls back atomically — no partial writes remain. `DataObjectWritten` events are emitted only after a successful commit.

DOA failures are catchable by Error Boundary Events attached to the flow node.

## Retention

Data Objects and their write history are purged together with their parent PI when retention policies are active. There is no independent retention for Data Object data.

## Related

- [Error Handling](error-handling.md) — payload cap applies to Data Object values
- [Database Administration](../operations/database.md) — partitioning and retention
