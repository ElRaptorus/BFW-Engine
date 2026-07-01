# Event-Based Gateways

An Event-Based Gateway suspends execution and creates a race between several alternative events. The **first event to fire wins**: execution continues along exactly that one path, and all sibling event subscriptions are cancelled. Only one branch of the gateway ever runs.

## How It Works

1. The PI reaches the Event-Based Gateway
2. The engine spawns a waiting FNI for every outgoing intermediate catch event simultaneously
3. All catch events subscribe to their respective sources (timer, message, signal, condition)
4. Whichever event fires first wins the race
5. The winning FNI completes and the token flows to the winning branch
6. All losing FNIs are cancelled (state `:interrupted`)
7. Execution continues from the winner's outgoing sequence flow — the others are never taken

## Supported Event Types

An Event-Based Gateway can race any mix of the following intermediate catch event types:

| Event Type | Fires When |
|---|---|
| Timer | The configured duration elapses or the configured date is reached |
| Message | A matching message arrives (with optional correlation) |
| Signal | A matching signal broadcast is received |
| Conditional | A FEEL condition evaluates to `true` |

All four types can be combined freely in a single gateway race. The exact same correlation, payload, and condition semantics apply as when these events appear outside a gateway — the gateway adds only the first-wins race logic.

## BPMN XML

An Event-Based Gateway is wired by placing it before two or more Intermediate Catch Events. Each catch event must have exactly one outgoing sequence flow:

```xml
<bpmn:eventBasedGateway id="EBG_1" name="Wait for Response or Timeout">
  <bpmn:incoming>Flow_In</bpmn:incoming>
  <bpmn:outgoing>Flow_to_message</bpmn:outgoing>
  <bpmn:outgoing>Flow_to_timer</bpmn:outgoing>
</bpmn:eventBasedGateway>

<!-- Branch 1: wait for a message -->
<bpmn:intermediateCatchEvent id="Catch_response" name="Response received">
  <bpmn:messageEventDefinition messageRef="Msg_response" />
  <bpmn:incoming>Flow_to_message</bpmn:incoming>
  <bpmn:outgoing>Flow_handle_response</bpmn:outgoing>
</bpmn:intermediateCatchEvent>

<!-- Branch 2: timeout after 30 seconds -->
<bpmn:intermediateCatchEvent id="Catch_timeout" name="Timed out">
  <bpmn:timerEventDefinition>
    <bpmn:timeDuration>PT30S</bpmn:timeDuration>
  </bpmn:timerEventDefinition>
  <bpmn:incoming>Flow_to_timer</bpmn:incoming>
  <bpmn:outgoing>Flow_handle_timeout</bpmn:outgoing>
</bpmn:intermediateCatchEvent>
```

## FNI States

When the race completes:

| FNI | State | Meaning |
|-----|-------|---------|
| The gateway FNI itself | `:finished` | The gateway has dispatched the race |
| The winning catch event FNI | `:finished` | This branch won and its token flowed onwards |
| Each losing catch event FNI | `:interrupted` | Cancelled because a sibling won first |

## Sibling Cancellation

When a winner is determined, the engine cancels the losing FNIs by calling `handle_aborted/1` on each loser's handler. This ensures clean resource release — timer subscriptions are cancelled, message and signal subscriptions are unregistered, and conditional waiters are removed.

## Resume on Restart

Event-Based Gateways resume correctly after an engine restart:

1. The gateway FNI is `:waiting`; the engine re-dispatches all sibling catch events via their `handle_resume/3` callbacks
2. Each sibling re-subscribes to its event source
3. Whichever fires first wins the race and cancels its siblings as normal

## Restrictions

| Restriction | Reason |
|---|---|
| No activities or gateways after an EBG | BPMN 2.0 requires that all elements immediately after an Event-Based Gateway are Intermediate Catch Events or Receive Tasks |
| Each outgoing catch event must lead to a distinct path | The gateway enforces exactly-one-winner; merging the paths back requires an explicit join gateway |
| No Receive Tasks yet | Receive Tasks as EBG alternatives are parsed but the EBG handler currently treats them identically to Message Catch Events |

## Error States

| Error | Cause | PI State |
|---|---|---|
| No outgoing catch events found | Gateway has no subscribable successors | `fatal` |
| All siblings fatal before any fires | Every event errors out before a winner is determined | `fatal` |

## Related

- [Timer Events](timer-events.md) — configure timer-based race branches
- [Message Events](message-events.md) — configure message-based race branches
- [Signal Events](signal-events.md) — configure signal-based race branches
- [Conditional Events](conditional-events.md) — configure condition-based race branches
- [Exclusive Gateways](exclusive-gateways.md) — condition-based routing without events
