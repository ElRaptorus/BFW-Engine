# Message Events

Message Events enable asynchronous communication between process instances and with external systems. A published message is routed by `(message_name, correlation_value)` to every matching subscription, or — when no subscriber is waiting — may start new process instances via Message Start Events.

## Overview

Messages are named payloads declared at the BPMN definitions level and referenced from event definitions or tasks via `messageRef`. When a message is published (from a throw event, Send Task, or the REST API), the engine:

1. Writes an audit row to the `messages` table
2. Looks up active subscriptions registered for that `(name, correlation_value)`
3. Delivers the payload to each matching catch-side waiter
4. If no subscription matched, checks for deployed Message Start Events with the same name
5. If still unmatched, holds the message in `pending_messages` until TTL expires or a late subscriber registers

This model supports order-tracking workflows, payment confirmations, hand-offs between processes, and external system integration without tight coupling.

## Message Types

| BPMN Element | Position | Role |
|--------------|----------|------|
| Message Start Event | Start | Creates a new PI when a message arrives and no active catch subscription consumed it |
| Message End Event | End | Publishes a message and terminates the PI branch |
| Intermediate Message Catch Event | Intermediate | Waits for a matching message, then continues |
| Intermediate Message Throw Event | Intermediate | Publishes a message and immediately continues |
| Message Boundary Event (interrupting) | Boundary | Waits for a message; on arrival, interrupts the host activity |
| Message Boundary Event (non-interrupting) | Boundary | Waits for a message; on arrival, spawns a parallel branch while the host continues |
| Send Task | Activity | Publishes a message (throw-side semantics) |
| Receive Task | Activity | Waits for a matching message (catch-side semantics) |

Every message type requires a global `<bpmn:message>` definition and a `messageRef` pointing to it.

### BPMN example (catch and throw)

```xml
<bpmn:message id="Message_payment" name="payment-received" />

<bpmn:process id="order-process" isExecutable="true">
  <bpmn:extensionElements>
    <evil:version>1.0.0</evil:version>
    <evil:correlationKey>token.orderId</evil:correlationKey>
  </bpmn:extensionElements>

  <!-- Catch: waits for an external payment confirmation -->
  <bpmn:intermediateCatchEvent id="Catch_payment" name="Wait for Payment">
    <bpmn:messageEventDefinition messageRef="Message_payment" />
    <bpmn:incoming>Flow_In</bpmn:incoming>
    <bpmn:outgoing>Flow_Out</bpmn:outgoing>
  </bpmn:intermediateCatchEvent>

  <!-- Throw: notifies downstream that payment was requested -->
  <bpmn:intermediateThrowEvent id="Throw_request" name="Request Payment">
    <bpmn:messageEventDefinition messageRef="Message_payment">
      <bpmn:extensionElements>
        <evil:correlationRetrievalExpression>token.orderId</evil:correlationRetrievalExpression>
      </bpmn:extensionElements>
    </bpmn:messageEventDefinition>
    <bpmn:incoming>Flow_Before</bpmn:incoming>
    <bpmn:outgoing>Flow_After</bpmn:outgoing>
  </bpmn:intermediateThrowEvent>
</bpmn:process>
```

## Correlation

Messages are matched on both name and correlation value. The engine uses two complementary extensions:

### `evil:correlationKey` (process-level, catch-side)

Declared on the process `<bpmn:extensionElements>`. Evaluated when a catch-side element (Intermediate Catch, Boundary, Receive Task) registers its subscription, using the current PI state (token, Data Objects, identity).

```xml
<evil:correlationKey>token.orderId</evil:correlationKey>
```

If omitted, the subscription matches messages with no correlation value (`:none`).

For Message Start Events, `evil:correlationKey` is evaluated against the **incoming message payload** at PI creation time (no PI state exists yet). The result seeds the new PI's correlation context.

### `evil:correlationRetrievalExpression` (throw-side)

Declared inside a `<bpmn:messageEventDefinition>` on throw-side elements (Intermediate Throw, Message End Event, Send Task). Evaluated against the outgoing token before publish; the result is stamped onto the message as `correlation_value`.

```xml
<bpmn:messageEventDefinition messageRef="Message_payment">
  <bpmn:extensionElements>
    <evil:correlationRetrievalExpression>token.orderId</evil:correlationRetrievalExpression>
  </bpmn:extensionElements>
</bpmn:messageEventDefinition>
```

Catch-side events do **not** use this extension.

### Matching rule

A published message `(name, correlation_value)` delivers to every subscription where `message_name = name` **and** `expected_correlation_value = correlation_value`. Multiple subscribers with the same key all receive a copy (broadcast-within-key semantics).

## Pending Messages

When a message is published but no subscription or Message Start Event matches, the engine inserts a row into `pending_messages` with a configurable TTL (default `PT60S` via `EVIL_MESSAGE_PENDING_TTL`).

| Event | Behaviour |
|-------|-----------|
| Publish with no match | Row inserted with `state='pending'`, `expires_at = now + TTL` |
| Late subscription register | Pending rows for the same `(name, correlation_value)` inside TTL are delivered immediately |
| TTL expires | Sweeper transitions row to `state='expired'` |

This closes the race where a message arrives milliseconds before a catch event enters its waiting state, or during engine resume before subscriptions are re-registered.

## REST API

Publish a message from outside the engine:

```
POST /messages/{message_name}/trigger
```

**Request body:**

```json
{
  "payload": { "orderId": "ORD-42", "status": "paid" },
  "correlation": "ORD-42"
}
```

`correlation` is optional. When omitted, the message is published with no correlation value.

**Response (200):**

```json
{
  "messageId": "550e8400-e29b-41d4-a716-446655440000",
  "messageName": "payment-received",
  "correlationValue": "ORD-42",
  "deliveries": 1,
  "startedProcessInstanceIds": [],
  "pending": false
}
```

**Authorization:** requires JWT claim `trigger_message: "all"`. Absent or `"none"` returns 403.

**Resume guard:** returns 503 with `Retry-After: 5` while the engine is resuming and message subscriptions are not yet ready.

## Plugin Facade

Plugins publish messages through the facade namespace:

```elixir
{:ok, result} = facade.messages.publish.("payment-received", "ORD-42", %{"status" => "paid"})
```

Arguments: `(message_name, correlation_value, payload)`. The plugin's identity is recorded in the message origin metadata.

## Data Pipeline

Message handlers participate in the shared data pipeline extensions:

| Extension | Side | Purpose |
|-----------|------|---------|
| `evil:inputMapping` | Throw | Maps token fields into the outgoing message payload before publish |
| `evil:outputMapping` | Catch | Maps the received message payload into the process token on delivery |
| `evil:payloadContract` | Throw | JSON Schema validated against the outgoing message payload; violation is fatal to the FNI |
| `evil:resultContract` | Catch | JSON Schema validated against the incoming message payload; violation is fatal to the FNI |

Contracts are direction-aware: throw-side events use `payloadContract`, catch-side events use `resultContract`. Contracts are placed at the **flow-node's** `<extensionElements>` level, not inside `<messageEventDefinition>`.

### Throw-side input mapping example

```xml
<bpmn:intermediateThrowEvent id="Throw_1">
  <bpmn:extensionElements>
    <evil:payloadContract>{"type":"object","required":["orderId","amount"]}</evil:payloadContract>
  </bpmn:extensionElements>
  <bpmn:messageEventDefinition messageRef="Message_payment">
    <bpmn:extensionElements>
      <evil:correlationRetrievalExpression>token.orderId</evil:correlationRetrievalExpression>
      <evil:inputMapping source="token.orderId" target="orderId" />
      <evil:inputMapping source="token.amount" target="amount" />
    </bpmn:extensionElements>
  </bpmn:messageEventDefinition>
</bpmn:intermediateThrowEvent>
```

### Catch-side output mapping example

```xml
<bpmn:intermediateCatchEvent id="Catch_1">
  <bpmn:extensionElements>
    <evil:resultContract>{"type":"object","required":["status"]}</evil:resultContract>
  </bpmn:extensionElements>
  <bpmn:messageEventDefinition messageRef="Message_payment">
    <bpmn:extensionElements>
      <evil:outputMapping source="event.status" target="paymentStatus" />
    </bpmn:extensionElements>
  </bpmn:messageEventDefinition>
</bpmn:intermediateCatchEvent>
```

## Best Practices

- **Use correlation for targeted delivery** — stamp throw-side messages with `evil:correlationRetrievalExpression` and declare `evil:correlationKey` on the receiving process so only the intended PI gets the message.
- **Use Data Objects for long-lived state** — messages carry transient event payloads; durable process state belongs in Data Objects accessed via `dataObjects.*` in FEEL expressions.
- **Catch-wins-over-start** — if an active catch subscription matches, Message Start Events for the same name are **not** triggered. Design your processes knowing that a waiting catch consumes the message.
- **Declare global message definitions** — every `messageRef` must point to a `<bpmn:message>` at the definitions level with a stable `name` attribute (this is the routing key).
- **Handle the pending window** — external publishers should retry or use correlation + late-register semantics if the subscriber may not be ready yet; the default 60-second TTL covers typical resume and deploy races.

## Related

- [Timer Events](timer-events.md) — time-based event correlation
- [Link Events](link-events.md) — intra-process jumps
- [Call Activities](call-activities.md) — cross-process invocation
- [Data Objects](data-objects.md) — durable state alongside message payloads
- [FEEL Expressions](expressions.md) — correlation and mapping expressions
- [Monitoring](monitoring.md) — `MessagePublished` and `MessageArrived` engine events
