# Standard Loops

Standard Loops repeat an activity while a condition remains true — polling a status endpoint until a job finishes, retrying a validation until it passes, or running a healthcheck on an interval. Unlike [Multi-Instance](multi-instance.md) (which iterates over a collection), Standard Loops are condition-driven with no predefined iteration count.

## How It Works

1. You annotate any BPMN activity with `<bpmn:standardLoopCharacteristics>`
2. The `testBefore` attribute controls the loop model: `true` for while-do, `false` (default) for do-while
3. Each loop pass creates a lightweight **iteration FNI** within the same process instance
4. After each pass, the engine evaluates the `<bpmn:loopCondition>` FEEL expression
5. When the condition becomes `false` or `loopMaximum` is reached, the loop finishes

## While-Do (`testBefore="true"`)

The condition is checked **before** the first iteration. If `false` from the start, the activity completes immediately with zero iterations.

```xml
<bpmn:scriptTask id="Poll_1" name="Poll Status" scriptFormat="feel">
  <bpmn:script>{ status: "checking", counter: (loop.completed + 1) }</bpmn:script>
  <bpmn:standardLoopCharacteristics testBefore="true" loopMaximum="10">
    <bpmn:loopCondition>token.status != "done"</bpmn:loopCondition>
  </bpmn:standardLoopCharacteristics>
</bpmn:scriptTask>
```

This script task checks whether `token.status` is `"done"` before every iteration. If the incoming token already has `status = "done"`, the loop completes immediately — no iterations run. Otherwise it loops up to 10 times, each pass producing a new `counter` value.

## Do-While (`testBefore="false"`, the default)

The first iteration always runs. The condition is checked **after** each iteration.

```xml
<bpmn:userTask id="Review_1" name="Review Document">
  <bpmn:extensionElements>
    <bfw:assignees>identity.groups</bfw:assignees>
    <bfw:formFields>{"fields":[{"name":"approved","type":"boolean"}]}</bfw:formFields>
  </bpmn:extensionElements>
  <bpmn:standardLoopCharacteristics testBefore="false" loopMaximum="5">
    <bpmn:loopCondition>token.approved != true</bpmn:loopCondition>
  </bpmn:standardLoopCharacteristics>
</bpmn:userTask>
```

The reviewer sees the form at least once. After each submission, the engine checks whether `token.approved` is `true`. If not, the task is presented again — up to 5 times total. This is the natural fit for "retry until accepted" workflows.

## Loop Condition

`<bpmn:loopCondition>` is a FEEL expression evaluated against the current process context (including `loop.*` bindings). The loop continues while the expression evaluates to `true`.

A `loopCondition` is required for Standard Loops — the validator rejects loops without one.

## Loop Maximum

The `loopMaximum` XML attribute (integer) caps the number of iterations. This is a safety guard against infinite loops:

```xml
<bpmn:standardLoopCharacteristics testBefore="true" loopMaximum="100">
  <bpmn:loopCondition>token.retryNeeded = true</bpmn:loopCondition>
</bpmn:standardLoopCharacteristics>
```

The validator warns (but does not error) when `loopMaximum` is absent — an uncapped loop with a flawed condition could run indefinitely.

## Loop Interval

`bfw:loopInterval` adds an ISO 8601 duration delay between iterations. This is the recommended pattern for **polling** and **healthcheck** scenarios:

```xml
<bpmn:scriptTask id="Health_1" name="Healthcheck" scriptFormat="feel">
  <bpmn:script>{ healthy: false }</bpmn:script>
  <bpmn:standardLoopCharacteristics testBefore="true" loopMaximum="60">
    <bpmn:loopCondition>token.healthy != true</bpmn:loopCondition>
    <bpmn:extensionElements>
      <bfw:loopInterval>PT5S</bfw:loopInterval>
    </bpmn:extensionElements>
  </bpmn:standardLoopCharacteristics>
</bpmn:scriptTask>
```

This polls every 5 seconds, up to 60 times (5 minutes total), until `token.healthy` becomes `true`.

Without `bfw:loopInterval`, iterations run back-to-back with no delay. For CPU-bound logic (pure computation, FEEL evaluation) this is fine. For I/O-bound patterns (HTTP polling, external system checks), always set an interval to avoid hammering the target.

## Token Evolution

Each iteration's output becomes the next iteration's input token. This allows progressive state building:

- Iteration 0: receives the original process token, produces `{ counter: 1 }`
- Iteration 1: receives `{ counter: 1 }`, produces `{ counter: 2 }`
- And so on...

The final output token (the one that flows along the outgoing sequence flow) is the last iteration's result.

## FEEL `loop.*` Context

Every iteration receives a `loop` binding in its FEEL context:

| Binding | Type | Description |
|---------|------|-------------|
| `loop.index` | integer | 0-based iteration count |
| `loop.total` | nil | Always `nil` for Standard Loops (iteration count is unknown upfront) |
| `loop.completed` | integer | Number of iterations finished so far |
| `loop.results` | list | Results from prior iterations |
| `loop.item` | nil | Always `nil` for Standard Loops (no collection) |

Example — a script task that builds a running counter using `loop.completed`:

```xml
<bpmn:scriptTask id="Counter_1" name="Count" scriptFormat="feel">
  <bpmn:script>{ counter: loop.completed + 1 }</bpmn:script>
  <bpmn:standardLoopCharacteristics testBefore="false" loopMaximum="5">
    <bpmn:loopCondition>loop.completed &lt; 5</bpmn:loopCondition>
  </bpmn:standardLoopCharacteristics>
</bpmn:scriptTask>
```

> **Note:** Inside XML, `<` in FEEL expressions must be escaped as `&lt;`. This is standard XML escaping and applies to all condition expressions.

## Zero Iterations (While-Do)

When `testBefore="true"` and the condition is `false` from the start, the loop completes immediately with the input token unchanged. No iteration FNIs are created.

This is useful for conditional work: "poll only if the status isn't already final."

## When to Use Standard Loop vs Sequential MI

| Scenario | Use |
|----------|-----|
| Process a list of items | Sequential MI (collection-driven) |
| Poll until a condition is met | Standard Loop (condition-driven) |
| Retry until success | Standard Loop with `loopMaximum` |
| Fixed N iterations | Sequential MI with a generated collection (`for i in 1..n return i`) |
| Rate-limited batch processing | Sequential MI with `bfw:loopInterval` |

The key distinction: if you have a **collection** to iterate, use Multi-Instance. If you have a **condition** to satisfy, use Standard Loop.

## Error Handling

Errors in a Standard Loop iteration behave like errors in any activity:

- The loop stops on the first fatal iteration
- Error boundaries on the loop activity catch the error
- The process instance can be retried (the entire loop re-runs from scratch)

If your loop wraps a Service Task that may fail intermittently, consider placing an error boundary on the loop activity to handle failures gracefully rather than letting the process instance go fatal.

## Retry

When a process instance containing a Standard Loop is retried:

- The entire loop re-runs from the beginning (iteration 0)
- You cannot retry at an individual loop iteration — the checkpoint must target the loop shell activity or a node upstream of it

This matches the engine's general retry model: loop iterations are internal to the shell activity and not individually addressable.

## See Also

- [Multi-Instance Activities](multi-instance.md) — for collection-driven iteration
- [Expressions](expressions.md) — FEEL expression reference
- [Service Tasks](service-tasks.md) — async tasks commonly used with Standard Loops for polling
