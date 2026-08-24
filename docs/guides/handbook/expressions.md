# FEEL Expressions

FEEL (Friendly Enough Expression Language) is the expression language defined by the DMN specification. The engine evaluates FEEL via a high-performance Rust NIF, supporting the full expression grammar, unary tests, and all standard built-in functions.

## Where Expressions Are Used

| Context | Example |
|---------|---------|
| Conditional sequence flows | `token.amount > 1000` on Exclusive / Inclusive / Complex Gateway outgoing flows |
| Script Task / FEEL BRT | `<bpmn:script>` body |
| Service Task HTTP body / auth / response headers | `evil:httpBody`, `evil:httpAuthHeader`, `evil:httpResponseHeaders` |
| Input/output mappings | `evil:inputMapping` / `evil:outputMapping` `source` |
| Correlation | Process `evil:correlationKey`; throw `evil:correlationRetrievalExpression` |
| Message payload / mapping | `evil:payload`, `evil:eventMapping` |
| Timer expressions | `timeDate` / `timeDuration` / `timeCycle` |
| User Task | `evil:assignees`, `evil:dueDate` |
| Multi-Instance / Standard Loop | `evil:inputCollection`, `evil:loopBreakCondition`, `<loopCondition>` |
| Complex Join | `<bpmn:activationCondition>` (gets `activatedCount` / `incomingCount`) |
| Ad-hoc completion / activation | `<completionCondition>`, `evil:activeElements` |
| Unary tests | Decision table cells |

## Context Bindings

Every expression evaluates against seven root bindings. Overlays are added only while the matching construct is evaluating.

| Binding | Description |
|---------|-------------|
| `token` | Current flow node's input token (runtime payload) |
| `this` | Current flow node metadata (`id`, `name`, `type`) |
| `context` | Immutable process-level variables from the start payload (`started_with_context`), available unchanged for the entire PI lifetime |
| `dataObjects` | Data objects attached to the process (by ID) |
| `process` | Process metadata (`id`, `name`, `version`) |
| `processInstance` | Instance metadata (`id`, `startedAt`, `startedBy`) |
| `identity` | Caller identity (`id`, `roles`, `groups`, `claims`) — **no** `name` |
| `loop` | Iteration overlay (Multi-Instance / Standard Loop; absent otherwise). Sub-keys: `loop.index` (0-based), `loop.total` (collection length or `null` for Standard Loop), `loop.completed`, `loop.results`, `loop.item` (current collection element for MI; `null` for Standard Loop) |
| `activatedCount` | Complex Join only: incoming branches that have delivered a token so far |
| `incomingCount` | Complex Join only: total incoming sequence flows |
| `performedActivities` | Ad-hoc completion only: count of inner FNIs in `:finished` |
| `activeCount` | Ad-hoc completion only: inner FNIs in `:active` or `:waiting` |
| `totalActivities` | Ad-hoc completion only: total inner activities in the model |

Bindings are camelCase per the FEEL spec. The engine assembles them in `Context.from_handler_context/2`.

### Accessing Bindings

```
token.amount              => 500
this.name                 => "Review Order"
process.version           => "2.1.0"
identity.id               => "user-42"
identity.roles            => ["clerk"]
dataObjects.customerName  => "Bob"
loop.index                => 0
```

## Supported Types

| FEEL Type | Elixir Representation |
|-----------|-----------------------|
| Boolean | `true` / `false` |
| Null | `nil` |
| String | `"hello"` |
| Integer | `42` |
| Float | `3.14` |
| List | `[1, 2, 3]` |
| Context (map) | `%{"a" => 1}` |
| Date | `{:feel_date, "2025-03-20"}` |
| Time | `{:feel_time, "14:30:00"}` |
| DateTime | `{:feel_datetime, "2025-03-20T14:30:00"}` |
| Duration (days/time) | `{:feel_duration_dt, ...}` |
| Duration (years/months) | `{:feel_duration_ym, ...}` |

## Evaluation Modes

### One-Shot Evaluation

For simple expressions:

```elixir
{:ok, result} = EvilEngine.Expressions.eval("token.amount * 2", context)
```

### Precompiled Evaluation

For performance-critical paths (repeated evaluation with different contexts):

```elixir
{:ok, ref} = EvilEngine.Expressions.compile("token.amount * rate", context_shape)
{:ok, result} = EvilEngine.Expressions.evaluate(ref, context)
```

### Unary Tests

For DMN-style decision table conditions and gateway routing:

```elixir
{:ok, true}  = EvilEngine.Expressions.evaluate_unary("< 100", 50)
{:ok, true}  = EvilEngine.Expressions.evaluate_unary("[1..5]", 3)
{:ok, false} = EvilEngine.Expressions.evaluate_unary("> 10", 5)
```

## Built-in Functions

FEEL includes standard functions:

| Function | Example | Result |
|----------|---------|--------|
| `string length` | `string length("hello")` | `5` |
| `contains` | `contains("foobar", "bar")` | `true` |
| `count` | `count([1, 2, 3])` | `3` |
| `sum` | `sum([10, 20, 30])` | `60` |
| `not` | `not(false)` | `true` |

## Null Propagation

FEEL uses three-valued logic. Accessing undefined variables returns `null` (not an error), and arithmetic with `null` propagates:

```
nonexistent        => null
null + 5           => null
10 / 0             => null
```

## Common Patterns

```
# Conditional routing
token.amount > 100 and token.status = "approved"

# If/then/else
if token.priority > 5 then "urgent" else "normal"

# List operations
for x in token.items return x * 2
some x in token.scores satisfies x > 90
every x in token.scores satisfies x > 60

# Cross-binding access
token.amount < dataObjects.limit

# Date arithmetic
@"2025-03-20" + @"P10D"   => @"2025-03-30"
```

## Error Handling

Invalid expressions return `{:error, reason}` and never crash the engine. Empty expressions also return an error. Non-binary inputs are rejected by guard clauses.

## Related

- [Service Tasks](service-tasks.md) -- FEEL in HTTP body/header expressions
- [User Tasks](user-tasks.md) -- FEEL in outgoing conditions
- [Exclusive Gateways](exclusive-gateways.md) -- FEEL conditions for routing decisions
- [Call Activities](call-activities.md) -- FEEL in input/output mappings
- [Starting Instances](starting-instances.md) -- the `identity` binding
