# Multi-Instance Activities

Multi-Instance lets you run the same activity once per element in a collection — processing a list of order items, reviewing multiple documents, calling an API per record. The engine supports both parallel (all at once) and sequential (one after another) execution.

## How It Works

1. You annotate any BPMN activity (task, call activity, subprocess) with `<bpmn:multiInstanceLoopCharacteristics>`
2. At runtime, the engine evaluates the `evil:inputCollection` FEEL expression to get the collection
3. For each element in the collection, the engine creates a lightweight **iteration FNI** (flow node instance) within the same process instance
4. Each iteration runs the underlying activity handler independently
5. When all iterations complete (or the completion/break condition is met), the shell aggregates results

## Parallel vs Sequential

### Parallel Multi-Instance

All iterations start simultaneously. Use when iterations are independent and you want maximum throughput.

```xml
<bpmn:serviceTask id="Task_charge" name="Charge Each Item" implementation="http">
  <bpmn:multiInstanceLoopCharacteristics isSequential="false">
    <bpmn:extensionElements>
      <evil:inputCollection>token.items</evil:inputCollection>
      <evil:outputCollection>chargeResults</evil:outputCollection>
      <evil:elementVariable>item</evil:elementVariable>
    </bpmn:extensionElements>
  </bpmn:multiInstanceLoopCharacteristics>
</bpmn:serviceTask>
```

### Sequential Multi-Instance

One iteration at a time — each starts only after the previous completes. Use for ordered processing or rate-limited APIs.

```xml
<bpmn:serviceTask id="Task_notify" name="Notify Each Recipient" implementation="http">
  <bpmn:multiInstanceLoopCharacteristics isSequential="true">
    <bpmn:extensionElements>
      <evil:inputCollection>token.recipients</evil:inputCollection>
      <evil:outputCollection>notificationResults</evil:outputCollection>
      <evil:elementVariable>recipient</evil:elementVariable>
      <evil:loopInterval>PT1S</evil:loopInterval>
    </bpmn:extensionElements>
  </bpmn:multiInstanceLoopCharacteristics>
</bpmn:serviceTask>
```

`evil:loopInterval` adds a delay (ISO 8601 duration) between iterations — useful for rate-limited APIs.

## Extension Elements Reference

| Extension Element | Purpose |
|-------------------|---------|
| `evil:inputCollection` | FEEL expression that evaluates to the list to iterate over |
| `evil:outputCollection` | Variable name for the aggregated results list |
| `evil:elementVariable` | Name of the per-iteration variable (accessible as `loop.item`) |
| `evil:outputElementVariable` | Name of the key used to collect each iteration's output into the output collection |
| `evil:loopBreakCondition` | FEEL expression — loop stops when `true` |
| `evil:loopInterval` | ISO 8601 duration between sequential iterations |
| `evil:maxIterations` | Safety cap — sequential truncates; parallel fail-fast |
| `<bpmn:completionCondition>` | Standard BPMN FEEL expression — MI terminates early when `true` |

## Input Collection

The `evil:inputCollection` is a FEEL expression that must evaluate to a list. Examples:

- `token.items` — list from the process token
- `dataObjects.OrderList` — list from a Data Object
- `[1, 2, 3, 4, 5]` — literal list

If the input collection evaluates to an empty list, the MI completes immediately with an empty output collection. No iterations are created.

## Element Variable

`evil:elementVariable` (or `<bpmn:inputDataItem>`) names the variable for the current collection element. It is accessible as `loop.item` in FEEL expressions within the iteration.

```xml
<evil:inputCollection>token.orders</evil:inputCollection>
<evil:elementVariable>order</evil:elementVariable>
```

Inside the iteration, `loop.item` refers to the current `order` object.

## Output Collection

`evil:outputCollection` names the variable that collects all iteration results. After completion, the aggregated list is available in the output token under the specified name.

```xml
<evil:outputCollection>processedOrders</evil:outputCollection>
```

When all iterations finish, `token.processedOrders` contains a list with one entry per iteration, ordered by iteration index.

`evil:outputElementVariable` (or `<bpmn:outputDataItem>`) names the key used when aggregating each iteration's result into that collection. When set, the engine uses this variable name as the aggregation key.

## FEEL `loop.*` Context

Every iteration receives a `loop` binding in its FEEL context:

| Binding | Type | Description |
|---------|------|-------------|
| `loop.index` | integer | 0-based iteration position |
| `loop.total` | integer | Total number of iterations (collection length) |
| `loop.completed` | integer | How many iterations have finished so far |
| `loop.results` | list | Results from previously completed iterations |
| `loop.item` | any | Current collection element |

Example condition expression:

```
loop.completed >= loop.total / 2
```

## Completion Condition

BPMN's `<bpmn:completionCondition>` is a FEEL expression evaluated after each iteration. When it evaluates to `true`, the MI terminates early — remaining iterations are interrupted.

```xml
<bpmn:multiInstanceLoopCharacteristics isSequential="false">
  <bpmn:completionCondition>loop.completed >= 3</bpmn:completionCondition>
  <bpmn:extensionElements>
    <evil:inputCollection>token.candidates</evil:inputCollection>
  </bpmn:extensionElements>
</bpmn:multiInstanceLoopCharacteristics>
```

This is useful for "first N wins" patterns — start parallel work, stop as soon as enough results are collected.

## Break Condition

`evil:loopBreakCondition` is an engine extension that works similarly to completion condition — a FEEL expression evaluated after each iteration. When `true`, the loop stops.

```xml
<evil:loopBreakCondition>loop.results[loop.completed].status = "failed"</evil:loopBreakCondition>
```

## Max Iterations

`evil:maxIterations` is a safety cap. Behavior differs by MI mode:

| Mode | When the collection is larger than the cap |
|------|---------------------------------------------|
| Sequential | Truncation — items beyond the limit are skipped |
| Parallel | Fail-fast — the shell fatals with `collection_exceeds_max_iterations` |

```xml
<evil:maxIterations>50</evil:maxIterations>
```

Parallel MI fails fast so a misconfigured collection cannot spawn an unbounded number of concurrent iteration FNIs.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Parallel iteration fails (fatal) | Remaining iterations continue to completion. The shell reports the failure after all iterations finish. |
| Sequential iteration fails | The loop stops immediately. The shell reports the failure. |
| Error boundary on the MI activity | Catches errors from iteration failures, same as on any activity |
| Timer/Message boundary on the MI activity | Attaches to the MI shell and works normally — interrupting boundaries cancel all iterations |

## Retry

Retrying a process instance with a failed MI re-runs the **entire MI from scratch** (all iterations). You cannot retry at an individual iteration — the retry target must be the MI shell activity or a node upstream of it. If a retry checkpoint points at an iteration FNI, the engine rejects it with error code `retry_checkpoint_is_mi_iteration`.

## Activity Types

MI works on any activity type:

### User Task MI

Each iteration creates a separate user task that must be completed individually. Parallel MI user tasks appear as independent items in the task list.

### Service Task MI

Each iteration dispatches an async service task (e.g. HTTP call). Parallel MI is ideal for batch API calls.

### Call Activity MI

Each iteration spawns a child process instance. The iteration FNI awaits the child's completion before the iteration is considered done.

### Subprocess MI

Each iteration runs the embedded subprocess's inner flow independently.

### Script Task / Business Rule Task MI

Each iteration evaluates the script or business rule with its own `loop.*` context.

## Nested MI

You can nest MI — for example, a sequential MI on a call activity where the child process contains a parallel MI task. Each level operates independently within its own scope. The inner MI's `loop.*` bindings are scoped to the inner level and do not interfere with the outer MI.

## Events

The engine emits lifecycle events for MI activities:

| Event | When | Key Fields |
|-------|------|------------|
| `MultiInstanceStarted` | MI shell begins execution | `flowNodeInstanceId`, `flowNodeType`, `loopType` (`parallel_mi` or `sequential_mi`), `totalIterations` |
| `MultiInstanceCompleted` | MI shell finishes | Same + `completedIterations`, `earlyBreak` |
| `FlowNodeInstanceStarted` | Each iteration starts | Includes `multiInstanceId` and `iterationIndex` |
| `FlowNodeInstanceFinished` | Each iteration finishes | Includes `multiInstanceId` and `iterationIndex` |

`earlyBreak` is `true` when the loop terminated before exhausting all iterations (via `completionCondition`, `loopBreakCondition`, or `maxIterations`).

## `loopCardinality` Is Not Supported

The engine does not support BPMN's `<loopCardinality>` element. Iteration count is always determined by the input collection length (optionally capped by `evil:maxIterations`). This is a deliberate design decision — collection-driven iteration is more explicit and debuggable.

## Related

- [Standard Loops](standard-loops.md) — for condition-based looping (while-do / do-while)
- [FEEL Expressions](expressions.md) — expression evaluation and the `loop.*` context
- [Error Handling](error-handling.md) — boundary events and error propagation
- [Service Tasks](service-tasks.md) — async service task handlers used with MI
- [Call Activities](call-activities.md) — child process invocation per iteration
- [Embedded Subprocesses](embedded-subprocesses.md) — subprocess execution per iteration
- [Retry](retry.md) — retry behavior for failed MI activities
- [Monitoring](monitoring.md) — observing MI lifecycle events
