# Error End Events

An Error End Event allows process modelers to signal a modeled BPMN error. Unlike a normal End Event (which completes the process successfully) or a Terminate End Event (which completes immediately and interrupts siblings), an Error End Event signals that something went wrong in a controlled, intentional way.

## When to Use Error End Events

Use an Error End Event when your process reaches a state that represents a **business-level error** — not a technical failure, but a legitimate outcome that the calling process should handle:

- A payment was declined
- A validation check failed
- An approval was rejected
- A required resource was unavailable

The key distinction: Error End Events represent **expected** error outcomes that the process designer anticipated. Engine failures (handler crashes, unsupported elements) produce `fatal` states instead.

## How It Works

When an Error End Event fires:

1. The Error End Event FNI transitions to **`error`** state (not `finished`)
2. All remaining active/waiting sibling FNIs are transitioned to **`error`** (reason `process_error`) — they are not `:interrupted`
3. The PI transitions to **`error`** state
4. If the PI has a parent (started via a Call Activity), the error propagates upward for [boundary matching](error-boundary-events.md)

## BPMN Syntax

### Inline Error Code

The simplest form specifies the error code directly on the event definition:

```xml
<bpmn:endEvent id="End_Error" name="Payment Failed">
  <bpmn:errorEventDefinition>
    <bpmn:extensionElements>
      <evil:errorCode>PAYMENT_DECLINED</evil:errorCode>
      <evil:errorMessage>The payment provider declined the transaction</evil:errorMessage>
    </bpmn:extensionElements>
  </bpmn:errorEventDefinition>
</bpmn:endEvent>
```

### Global Error Reference

You can define errors globally and reference them via `errorRef`:

```xml
<!-- Global error definition -->
<bpmn:error id="Error_Payment" name="Payment Error" errorCode="PAYMENT_DECLINED" />

<!-- Error End Event referencing it -->
<bpmn:endEvent id="End_Error" name="Payment Failed">
  <bpmn:errorEventDefinition errorRef="Error_Payment" />
</bpmn:endEvent>
```

### Catch-All Error (No Code)

An Error End Event without an error code throws an untyped error. This is matched by catch-all [Error Boundary Events](error-boundary-events.md) (boundaries that also have no error code filter):

```xml
<bpmn:endEvent id="End_Error" name="Something Went Wrong">
  <bpmn:errorEventDefinition />
</bpmn:endEvent>
```

## Error Code Resolution Priority

When both inline and global error codes are available, the engine resolves them with this priority:

| Priority | Source | Example |
|----------|--------|---------|
| 1 (highest) | Inline `evil:errorCode` on the event definition | `<evil:errorCode>INLINE_CODE</evil:errorCode>` |
| 2 | Global `<bpmn:error errorCode="...">` via `errorRef` | `<bpmn:error id="Err1" errorCode="GLOBAL_CODE" />` |
| 3 (lowest) | No code — catch-all | `<bpmn:errorEventDefinition />` |

If inline `evil:errorCode` is set, it **overrides** the global definition's code. This allows reusing a global error definition while customizing the code per throw site.

## FNI States After an Error End Event

When an Error End Event fires in a process with concurrent branches (e.g., via non-interrupting boundary events or future parallel gateways), the resulting FNI states tell the full story:

| FNI | State | Meaning |
|-----|-------|---------|
| Error End Event | `error` | This element threw the error |
| Active/waiting siblings | `error` | Collateral — stopped by the error |
| Previously completed FNIs | `finished` | Completed before the error occurred |

## Error Propagation to Parent Processes

### With Matching Boundary Event

When a child process (started via a Call Activity) reaches an Error End Event, the parent can catch the error using an [Error Boundary Event](error-boundary-events.md):

```xml
<!-- Parent process -->
<bpmn:callActivity id="CA_1" name="Process Payment" calledElement="PaymentProcess">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Success</bpmn:outgoing>
</bpmn:callActivity>

<bpmn:boundaryEvent id="Boundary_1" attachedToRef="CA_1">
  <bpmn:errorEventDefinition>
    <bpmn:extensionElements>
      <evil:errorCode>PAYMENT_DECLINED</evil:errorCode>
    </bpmn:extensionElements>
  </bpmn:errorEventDefinition>
  <bpmn:outgoing>Flow_ToFallback</bpmn:outgoing>
</bpmn:boundaryEvent>
```

When the child's Error End Event has `error_code: "PAYMENT_DECLINED"`:
- The child PI transitions to `error`
- The parent's Call Activity FNI is `interrupted`
- The parent follows the boundary's outgoing path (`Flow_ToFallback`)
- The parent PI continues normally and can still `finish` successfully

### Without Matching Boundary Event

If no boundary matches the error code (or no boundary event is attached at all), the uncaught error causes the **parent PI to go `fatal`**. An uncaught BPMN error is treated as a fatal condition in the parent.

### Standalone Process

When an Error End Event fires in a top-level process (no parent), the PI simply transitions to `error` state. The error information is available via REST and GraphQL for debugging and monitoring.

## REST and GraphQL

### PI State

PIs in `error` state appear with state `"error"` in all API responses:

```json
{
  "processInstanceId": "pi-123",
  "state": "error",
  "finishedAt": "2026-06-04T10:00:00Z"
}
```

### FNI State

The Error End Event FNI appears with state `"error"`:

```json
{
  "flowNodeInstanceId": "fni-456",
  "flowNodeId": "End_Error",
  "state": "error",
  "typeProperties": {
    "end_event_id": "End_Error",
    "end_event_name": "Payment Failed",
    "error_code": "PAYMENT_DECLINED",
    "error_message": "The payment provider declined the transaction"
  }
}
```

### WebSocket Events

Two events are emitted:

1. `FlowNodeInstanceFinished` with `terminalState: "error"` and `eventType: "error"`
2. `ProcessInstanceStateChanged` with `newState: "error"`

## Complete Example

A child process that validates an order and throws an error if validation fails:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                  xmlns:evil="https://evilengine.dev/schema/bpmn"
                  targetNamespace="https://evilengine.dev/schema/bpmn"
                  id="Definitions_1">

  <bpmn:error id="Err_Validation" name="Validation Error"
              errorCode="VALIDATION_FAILED" />

  <bpmn:process id="OrderValidation" name="Order Validation"
                isExecutable="true">
    <bpmn:extensionElements>
      <evil:version>1.0.0</evil:version>
    </bpmn:extensionElements>

    <bpmn:startEvent id="Start_1">
      <bpmn:outgoing>Flow_1</bpmn:outgoing>
    </bpmn:startEvent>

    <bpmn:exclusiveGateway id="GW_1" name="Valid?" default="Flow_Invalid">
      <bpmn:incoming>Flow_1</bpmn:incoming>
      <bpmn:outgoing>Flow_Valid</bpmn:outgoing>
      <bpmn:outgoing>Flow_Invalid</bpmn:outgoing>
    </bpmn:exclusiveGateway>

    <bpmn:endEvent id="End_Success" name="Validation Passed">
      <bpmn:incoming>Flow_Valid</bpmn:incoming>
    </bpmn:endEvent>

    <bpmn:endEvent id="End_Error" name="Validation Failed">
      <bpmn:errorEventDefinition errorRef="Err_Validation" />
      <bpmn:incoming>Flow_Invalid</bpmn:incoming>
    </bpmn:endEvent>

    <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="GW_1" />
    <bpmn:sequenceFlow id="Flow_Valid" sourceRef="GW_1" targetRef="End_Success">
      <bpmn:conditionExpression>token.isValid = true</bpmn:conditionExpression>
    </bpmn:sequenceFlow>
    <bpmn:sequenceFlow id="Flow_Invalid" sourceRef="GW_1"
                       targetRef="End_Error" />
  </bpmn:process>
</bpmn:definitions>
```

The parent process calls this via a Call Activity and catches the validation error:

```xml
<bpmn:callActivity id="CA_Validate" name="Validate Order"
                   calledElement="OrderValidation">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_Success</bpmn:outgoing>
</bpmn:callActivity>

<bpmn:boundaryEvent id="BE_ValidationFailed" attachedToRef="CA_Validate">
  <bpmn:errorEventDefinition>
    <bpmn:extensionElements>
      <evil:errorCode>VALIDATION_FAILED</evil:errorCode>
    </bpmn:extensionElements>
  </bpmn:errorEventDefinition>
  <bpmn:outgoing>Flow_ToManualReview</bpmn:outgoing>
</bpmn:boundaryEvent>
```

## Retrying Process Instances in Error State

PIs in `error` state are retryable, just like `fatal` or `aborted` PIs. Use the retry endpoint:

```
PUT /process-instances/{id}/retry
```

On retry, the Error End Event FNI (in `error` state) is reset to `active` and re-dispatched. Sibling FNIs that were set to `error` by the Error End Event are reset with the rest of the retryable `:error` FNIs.

Retry also supports **version migration**: deploy a corrected process version and pass the new `version` in the retry request body. The process restarts with the updated model. **Checkpoint reset** via `resetToFlowNodeInstanceId` is supported as well.

## Related

- [Error Boundary Events](error-boundary-events.md) -- catching errors thrown by Error End Events
- [Error Handling](error-handling.md) -- general error states (`fatal` vs `error`)
- [Call Activities](call-activities.md) -- parent/child error propagation
- [Retry](retry.md) -- recovering from fatal and error states
