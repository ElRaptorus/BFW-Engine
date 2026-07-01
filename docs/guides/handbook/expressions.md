# FEEL Expressions

FEEL (Friendly Enough Expression Language) is the expression language defined by the DMN specification. The engine evaluates FEEL via a high-performance Rust NIF, supporting the full expression grammar, unary tests, and all standard built-in functions.

## Where Expressions Are Used

| Context | Example |
|---------|---------|
| Conditional sequence flows | `token.amount > 1000` on Exclusive Gateway outgoing flows |
| Service Task HTTP body | `evil:httpBody` expression evaluated before request |
| Service Task HTTP auth header | `evil:httpAuthHeader` expression |
| Service Task HTTP response headers | `evil:httpResponseHeaders` mapping |
| Input/output mappings | Call Activity `in_mappings` and `out_mappings` |
| Correlation keys | `evil:correlationKey` on a process |
| Unary tests | Gateway conditions, decision table cells |

## Context Bindings

Every expression evaluates within a context of seven root bindings, plus an optional loop overlay:

| Binding | Contents |
|---------|----------|
| `token` | Current token payload (the main data flowing through the process) |
| `this` | Current flow node metadata (`id`, `name`, `type`) |
| `context` | Shared process-level context map |
| `dataObjects` | Current Data Object snapshot for the PI |
| `process` | Process metadata (`id`, `name`, `version`) |
| `processInstance` | PI metadata (`id`, `startedAt`, `startedBy`) |
| `identity` | Caller identity from JWT claims (`id`, `name`, `roles`) |
| `loop` | *(optional)* Multi-Instance iteration context (`index`, `total`, `completed`) |

### Accessing Bindings

```
token.amount              => 500
this.name                 => "Review Order"
process.version           => "2.1.0"
identity.name             => "Alice"
dataObjects.customerName  => "Bob"
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
