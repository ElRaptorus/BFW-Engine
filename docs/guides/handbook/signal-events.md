# Signal Events

Signal Events enable broadcast communication across process instances and with external systems. A published signal is delivered simultaneously to every matching subscriber — catch events, boundary events, and start events — without any payload or correlation.

## Overview

Signals are named broadcasts declared at the BPMN definitions level and referenced from event definitions via `signalRef`. When a signal is published (from a throw event, end event, or the REST API), the engine:

1. Writes an audit row to the `signals` table
2. Looks up all active subscriptions registered for that `signal_name`
3. Delivers `{:signal_arrived, signal_id}` to every matching catch-side waiter
4. Simultaneously starts new process instances from every deployed Signal Start Event matching the name
5. If no subscription matched **and** no start events fired, holds the signal in `pending_signals` until TTL expires or a late subscriber registers

This model supports cross-process synchronisation, event-driven architecture patterns, and external system triggers without tight coupling.

## Signals vs. Messages

Signals and messages are fundamentally different event types:

| Dimension | Signals | Messages |
|-----------|---------|----------|
| Routing | Name only (broadcast) | Name + correlation value (targeted) |
| Payload | None — token passes through unchanged | Arbitrary JSON payload |
| Delivery | All matching subscribers + all matching Start Events simultaneously | All subscribers for the key; Start Events only if no subscriber matched |
| Isolation | Never triggers a message event | Never triggers a signal event |

## Signal Types

| BPMN Element | Position | Role |
|--------------|----------|------|
| Signal Start Event | Start | Creates a new PI when a signal arrives |
| Signal End Event | End | Publishes a signal and terminates the PI branch |
| Intermediate Signal Catch Event | Intermediate | Waits for a matching signal, then continues |
| Intermediate Signal Throw Event | Intermediate | Publishes a signal and immediately continues |
| Signal Boundary Event (interrupting) | Boundary | Waits for a signal; on arrival, interrupts the host activity |
| Signal Boundary Event (non-interrupting) | Boundary | Waits for a signal; on arrival, spawns a parallel branch while the host continues. Re-subscribes after each fire (multi-fire). |

Every signal type requires a global `<bpmn:signal>` definition and a `signalRef` pointing to it.

### BPMN example (throw and catch)

```xml
<bpmn:signal id="Signal_order_shipped" name="order-shipped" />

<bpmn:process id="shipping-process" isExecutable="true">
  <bpmn:extensionElements>
    <bfw:version>1.0.0</bfw:version>
  </bpmn:extensionElements>

  <!-- Throw: notifies all listeners that the order was shipped -->
  <bpmn:intermediateThrowEvent id="Throw_shipped" name="Order Shipped">
    <bpmn:signalEventDefinition signalRef="Signal_order_shipped" />
    <bpmn:incoming>Flow_Before</bpmn:incoming>
    <bpmn:outgoing>Flow_After</bpmn:outgoing>
  </bpmn:intermediateThrowEvent>
</bpmn:process>

<bpmn:process id="notification-process" isExecutable="true">
  <bpmn:extensionElements>
    <bfw:version>1.0.0</bfw:version>
  </bpmn:extensionElements>

  <!-- Catch: waits for the order-shipped signal -->
  <bpmn:intermediateCatchEvent id="Catch_shipped" name="Wait for Shipping">
    <bpmn:signalEventDefinition signalRef="Signal_order_shipped" />
    <bpmn:incoming>Flow_In</bpmn:incoming>
    <bpmn:outgoing>Flow_Out</bpmn:outgoing>
  </bpmn:intermediateCatchEvent>
</bpmn:process>
```

## No Payload, No Correlation

Signals are deliberately minimal. They carry **no data** and use **no correlation**.

- **No payload**: The catch-side token is unchanged when a signal arrives. If your workflow needs to pass data between processes, use [Message Events](message-events.md) instead.
- **No correlation**: Signals match by `signal_name` only. Every active subscriber for that name receives the signal. There is no `bfw:correlationKey` or `bfw:correlationRetrievalExpression` for signals.

### Token manipulation via mappings

Although signals carry no payload, you may still use `bfw:inputMapping` and `bfw:outputMapping` on signal events. These map the **process token**, not a signal payload — they transform the token before it continues downstream, the same way mappings work on any other BPMN element.

```xml
<bpmn:intermediateCatchEvent id="Catch_1">
  <bpmn:signalEventDefinition signalRef="Signal_order_shipped" />
  <bpmn:extensionElements>
    <bfw:outputMapping source="true" target="shippingNotified" />
  </bpmn:extensionElements>
</bpmn:intermediateCatchEvent>
```

## Broadcast Semantics

When a signal fires, **all** of the following happen simultaneously:

1. **Every active Signal Catch Event** waiting for that signal name receives it and continues
2. **Every active Signal Boundary Event** waiting for that signal name fires
3. **Every deployed Signal Start Event** matching that signal name starts a new process instance

There is no catch-wins-over-start gating (unlike messages). A single signal broadcast can wake multiple catch events, trigger multiple boundary events, and start multiple new process instances — all in the same publish cycle.

## Pending Signals

When a signal is published but no subscription and no Signal Start Event matches, the engine inserts a row into `pending_signals` with a configurable TTL (default `PT60S` via `BFE_SIGNAL_PENDING_TTL`).

| Event | Behaviour |
|-------|-----------|
| Publish with no match | Row inserted with `state='pending'`, `expires_at = now + TTL` |
| Late subscription register | First pending row for the same `signal_name` inside TTL is delivered immediately (FIFO drain) |
| TTL expires | Sweeper transitions row to `state='expired'` |

The pending signal is consumed by the **first** subscriber that registers — subsequent subscribers do not receive it. This is a grace period for race conditions, not a replay mechanism.

## REST API

Publish a signal from outside the engine:

```
POST /signals/{signal_name}/trigger
```

**Request body:** empty or `{}`. Any unknown fields (including `payload`) are silently ignored — consistent with all other engine endpoints.

**Response (200):**

```json
{
  "signalId": "550e8400-e29b-41d4-a716-446655440000",
  "signalName": "order-shipped",
  "deliveries": [
    {
      "processInstanceId": "...",
      "flowNodeInstanceId": "..."
    }
  ],
  "startedProcessInstanceIds": ["..."],
  "pending": false
}
```

**Authorization:** requires JWT claim `trigger_signal: "all"`. Absent or `"none"` returns 403.

**Resume guard:** returns 503 with `Retry-After: 5` while the engine is resuming and signal subscriptions are not yet ready.

## Plugin Facade

Plugins publish signals through the facade namespace:

```elixir
{:ok, result} = facade.signals.publish.("order-shipped")
```

The single argument is `signal_name` — no payload, no correlation. The plugin's identity is recorded in the signal origin metadata.

## Boundary Event Behaviour

### Interrupting

When a signal arrives at an interrupting boundary event:
1. The boundary branch is taken
2. The host activity is interrupted (its FNI is aborted, its handler Task killed)
3. Sibling boundary events on the same host are aborted
4. The boundary event does **not** re-subscribe

### Non-interrupting (multi-fire)

When a signal arrives at a non-interrupting boundary event:
1. A parallel branch is spawned from the boundary
2. The host activity continues unaffected
3. The boundary event re-subscribes for the same signal, ready to fire again
4. Each subsequent signal arrival spawns another parallel branch

This cycle continues until the host activity completes, at which point the boundary event is cleaned up.

## Best Practices

- **Use signals for broadcast notifications** — when multiple processes or activities need to know that something happened, without exchanging data.
- **Use messages for targeted delivery** — when you need to route data to a specific process instance by correlation.
- **Design for simultaneous delivery** — a signal triggers all matching subscribers at once. Ensure your processes can handle concurrent activation.
- **Leverage the pending window** — the default 60-second TTL covers typical resume and deploy races. If your subscriber may not be ready, the pending buffer gives it a grace period.
- **Declare global signal definitions** — every `signalRef` must point to a `<bpmn:signal>` at the definitions level with a stable `name` attribute (this is the routing key).

## Related

- [Message Events](message-events.md) — targeted, correlated, payload-carrying events
- [Timer Events](timer-events.md) — time-based event triggers
- [Link Events](link-events.md) — intra-process jumps
- [Error Boundary Events](error-boundary-events.md) — error-driven flow branching
- [FEEL Expressions](expressions.md) — mapping expressions for token manipulation
- [Monitoring](monitoring.md) — `SignalPublished` and `SignalArrived` engine events
