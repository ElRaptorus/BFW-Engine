# Error Boundary Events

Error Boundary Events catch errors thrown by an activity (such as a Call Activity) and route the process along an alternative path instead of causing a fatal failure. They are the BPMN mechanism for structured error handling within a process.

## How It Works

1. An Error Boundary Event is attached to a host activity (e.g., a Call Activity)
2. When the host activity produces an error, the engine checks if any attached boundary event matches the error
3. If a match is found, the host activity's FNI is interrupted and the error token flows along the boundary event's outgoing sequence flows
4. If no match is found, the error propagates normally (typically causing the PI to go `fatal`)

## Matching Rules

Error Boundary Events match using **AND logic** on two optional fields:

| Boundary Specifies | Matching Rule |
|-------------------|---------------|
| `errorCode` only | Runtime error must carry the same `error_code` |
| `errorMessage` only | Runtime error must carry the same `error_message` |
| Both `errorCode` and `errorMessage` | **Both** must match |
| Neither (catch-all) | Matches any error |

When multiple boundary events are attached, the engine evaluates them in document order and uses the **first match**.

## BPMN Example

```xml
<bpmn:callActivity id="CA_1" name="Process Payment" calledElement="PaymentProcess">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Success</bpmn:outgoing>
</bpmn:callActivity>

<!-- Catch a specific error code -->
<bpmn:boundaryEvent id="Boundary_PaymentFailed" attachedToRef="CA_1">
  <bpmn:errorEventDefinition errorRef="Error_PaymentFailed" />
  <bpmn:outgoing>Flow_ToErrorHandler</bpmn:outgoing>
</bpmn:boundaryEvent>

<!-- Catch-all boundary (no error code or message) -->
<bpmn:boundaryEvent id="Boundary_CatchAll" attachedToRef="CA_1">
  <bpmn:errorEventDefinition />
  <bpmn:outgoing>Flow_ToGenericHandler</bpmn:outgoing>
</bpmn:boundaryEvent>

<bpmn:error id="Error_PaymentFailed" name="Payment Failed" errorCode="PAYMENT_DECLINED" />
```

In this example:
- If the child PI fails with `error_code: "PAYMENT_DECLINED"`, the `Boundary_PaymentFailed` event catches it
- If the child PI fails with any other error, the `Boundary_CatchAll` event catches it
- The process continues along the boundary's outgoing flows instead of going fatal

## Supported Host Activities

Error Boundary Events work on all activity types:

| Host Activity | Error Source |
|--------------|-------------|
| Service Task | Handler dispatch failure, contract violation, plugin error |
| User Task | Assignee FEEL resolution failure, payload contract violation |
| Script Task | Script execution failure, FEEL evaluation error |
| Business Rule Task | Unknown implementation, DMN evaluation error |
| Call Activity | Child PI transitions to `fatal` (engine failure), child PI reaches an [Error End Event](error-end-events.md) (`error` state), broken `calledElement` reference, input/output mapping failure |
| Manual Task | Contract violation |
| Send Task | Message send failure |
| Receive Task | Correlation failure |

## Error Token

When a boundary event fires, the error information is forwarded as the token payload along the boundary's outgoing flows. The error token contains:

| Field | Description |
|-------|-------------|
| `error_code` | The error code from the child (e.g., `"CHILD_FATAL"`, `"CHILD_CRASH"`, or a handler-specific code) |
| `error_message` | A human-readable description of the error |

## Catch-All vs. Specific Boundaries

Use specific error codes when you need to handle different errors differently:

```xml
<!-- Specific: only catches payment declined -->
<bpmn:boundaryEvent id="B1" attachedToRef="CA_1">
  <bpmn:errorEventDefinition>
    <bpmn:error errorCode="PAYMENT_DECLINED" />
  </bpmn:errorEventDefinition>
</bpmn:boundaryEvent>

<!-- Catch-all: catches anything the specific boundary missed -->
<bpmn:boundaryEvent id="B2" attachedToRef="CA_1">
  <bpmn:errorEventDefinition />
</bpmn:boundaryEvent>
```

The engine evaluates boundaries in order — place specific boundaries before catch-all boundaries so they get priority.

## Error End Events as Error Source

The most common error source for boundary events is the [Error End Event](error-end-events.md). When a child process (via Call Activity) reaches an Error End Event, the parent's boundary events can catch the error:

```xml
<!-- Child process throws a modeled error -->
<bpmn:endEvent id="End_Error" name="Payment Failed">
  <bpmn:errorEventDefinition>
    <bpmn:extensionElements>
      <evil:errorCode>PAYMENT_DECLINED</evil:errorCode>
    </bpmn:extensionElements>
  </bpmn:errorEventDefinition>
</bpmn:endEvent>

<!-- Parent process catches it via boundary -->
<bpmn:boundaryEvent id="Boundary_1" attachedToRef="CA_1">
  <bpmn:errorEventDefinition>
    <bpmn:extensionElements>
      <evil:errorCode>PAYMENT_DECLINED</evil:errorCode>
    </bpmn:extensionElements>
  </bpmn:errorEventDefinition>
  <bpmn:outgoing>Flow_ToFallback</bpmn:outgoing>
</bpmn:boundaryEvent>
```

The error code matching works identically whether the error comes from an Error End Event or from an engine failure — see the matching rules above.

## What Happens Without a Boundary

If an activity produces an error and no matching Error Boundary Event is attached:

- **Engine failure** (handler crash, unsupported element): the PI transitions to `fatal`
- **BPMN error** (Error End Event in child): the PI also transitions to `fatal` — an uncaught modeled error is treated as fatal in the parent

## Related

- [Error End Events](error-end-events.md) -- throwing modeled BPMN errors from within a process
- [Timer Events](timer-events.md) -- timer-triggered boundary events (subscription model)
- [Call Activities](call-activities.md) -- child PI errors caught by error boundaries
- [Error Handling](error-handling.md) -- general error states and fatal transitions
- [FEEL Expressions](expressions.md) -- expression evaluation errors that can trigger boundaries
