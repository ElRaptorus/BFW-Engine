# Expression engine (FEEL)

## Context shape

Expressions see a deliberately lean root record. The engine ships exactly seven
top-level bindings; the surface is extended only when concrete user feedback
demands it. Adding bindings later is forward-compatible; removing them is not.

```
{
  "token"           : currentToken,                  // the live token at this flow node
  "this"            : {id, name, type, lane?, ...},  // the executing flow node model
  "context"         : readonlyProcessContext,        // concept §Process Context
  "dataObjects"     : {<DATA_OBJECT_ID>: value, ...},
  "process"         : {id, name, version, definitionInfo},
  "processInstance" : {id, businessKey?, startedAt, parentId?},
  "identity"        : {id, name?, email?, roles?, groups?, claims}
}
```

**No `token.history`.** v1 deliberately exposes exactly two ways for an
expression to access process state:

1. **`token`** — what the current flow node received from its predecessor.
   Ephemeral; lives only for the duration of this flow node's execution.
2. **`dataObjects`** — durable, audit-trailed PI state (§Data Objects).
   The supported channel for any value that needs to survive past the next
   flow node.

**MI / standard-loop iteration overlay.** Only inside an actively iterating
Multi-Instance or standard-loop activity, the engine injects one additional
binding at root level so MI completion conditions and `<evil:loopBreakCondition>`
can introspect iteration state. Outside iterations this binding is absent.

```
{
  ...,                          // the 7 bindings above
  "loop": {
    "index"     : integer,      // 0-based current iteration counter
    "total"     : integer,      // total iteration count (MI input collection size)
    "completed" : integer,      // number of iterations finished so far
    "results"   : array         // accumulated per-iteration result tokens
  }
}
```

**Complex-join gateway overlay.** Only when evaluating a Complex Gateway
**join**'s `<bpmn:activationCondition>`, the engine injects two additional
top-level bindings via `Context.put_gateway_bindings/3` so the threshold
condition can introspect arrival state. Outside a complex-join evaluation
these bindings are absent (see [execution.md §Complex Gateway](execution.md)).

```
{
  ...,                          // the 7 bindings above
  "activatedCount" : integer,   // incoming branches that delivered a token so far
  "incomingCount"  : integer    // total number of incoming sequence flows into the join
}
```

Typical use: `activatedCount >= 2` (a 2-of-N quorum) or
`activatedCount = incomingCount` (wait for every branch). `token` during this
evaluation is the merge of all branch payloads accumulated so far.

### Library selection (dsntk + Rustler)

**Status: DECIDED (Phase 0, Item 13).**

Evaluated candidates:

| Candidate | Outcome |
|---|---|
| `feel_ex` (Hex) | Rejected — no precompilation API; parser not scope-aware; limited grammar coverage. |
| `rodar_feel` (Hex) | Rejected — hobby project, stale maintenance, unclear roadmap. |
| **Rust NIF via `dsntk` + `rustler`** | **Selected.** Full DMN FEEL 1.3 grammar; modular crates (`dsntk-feel-parser` 0.3, `dsntk-feel-evaluator` 0.3); parse/evaluate separation enables precompilation; MIT licensed; actively maintained by the DecisionToolkit project. |
| In-engine FEEL subset | Not needed — dsntk covers the full grammar including `for/in/return`, quantified expressions, temporal types, and all built-in functions. |

**Architecture:**

- **Rust crate**: `apps/core_expressions/native/feel_nif/` — a `cdylib` built by Rustler at `mix compile` time.
- **NIF module**: <code>EvilEngine.Expressions.Nif</code> (private) — four NIF functions: `compile/2`, `eval_compiled/2`, `eval_expression/2`, `eval_unary_test/3`. Parse-heavy NIFs (`compile`, `eval_expression`, `eval_unary_test`) run on `DirtyCpu` schedulers; `eval_compiled` runs on normal schedulers for minimal overhead on the hot path (see §8.3.1).
- **Precompilation**: `compile/2` parses the expression into a `dsntk AstNode`, wraps it in a `ResourceArc<CompiledExpression>` (Mutex-guarded), and returns it to Elixir as an opaque reference. The reference is reusable across evaluations — no parsing on the hot path.
- **Scope-aware parser**: dsntk's parser requires variable names in scope at parse time. `compile/2` accepts a context-shape map (placeholder values) which is converted to a `FeelScope` for the parser.
- **Unary tests**: `eval_unary_test/3` wraps the test expression as `__unary_input__ in (<expression>)` because dsntk's `evaluate()` returns raw unary-test nodes. The input value is bound to `__unary_input__` in the context, yielding a boolean result.
- **Type bridge**: Elixir terms are converted to `dsntk::Value` / `FeelContext` on the way in and back to Elixir terms on the way out. Temporal types (date, time, datetime, durations) return as tagged tuples (e.g. `{:feel_date, "2025-03-20"}`).

**Toolchain requirement**: Rust 1.94+ (pinned in `.tool-versions`).

### FEEL built-in function support

Systematic audit of DMN-mandated FEEL built-in functions against the dsntk
NIF. Test file: `apps/core_dmn/test/evil_engine/dmn/feel_builtin_functions_test.exs`.

**Summary: 61/63 functions pass (97%)**

| Category | Functions tested | All pass? | Notes |
|---|---|---|---|
| Conversion | `number`, `string` | No | `number(from)` returns nil — unsupported |
| Boolean | `not` | Yes | |
| String | `substring`, `string length`, `upper case`, `lower case`, `contains`, `starts with`, `ends with`, `matches`, `replace`, `split` | Yes | |
| List | `list contains`, `count`, `min`, `max`, `sum`, `mean`, `distinct values`, `flatten`, `sort`, `reverse`, `index of`, `append`, `concatenate`, `sublist`, `insert before`, `remove`, `union`, `product`, `median`, `stddev`, `mode`, `all`, `any` | Yes | `mean` returns integer when result has no fraction (precision quirk) |
| Numeric | `decimal`, `floor`, `ceiling`, `abs`, `modulo`, `sqrt`, `log`, `exp`, `odd`, `even` | Yes | |
| Date/Time | `date`, `time`, `date and time`, `now`, `today`, `day of week`, `month of year` | Yes | |
| Context | `get value`, `get entries`, `context put`, `context merge` | Yes | |
| Range | `before`, `after` | Yes | |
| Type/Conditional | `if-then-else`, `instance of` | Yes | |

**Known limitations:**
- `number(from)`: dsntk does not support the `number()` conversion function. Workaround: use direct numeric literals or type coercion via `TypeResolver`.
- `not()` in unary test context: returns nil (documented in P4.10). Works correctly as a boolean function.

The previous note that "dsntk covers all built-in functions" is updated to
reflect the `number()` gap identified in this audit.

### NIF scheduler and concurrency

The Rust NIF exposes four functions, each with deliberate scheduler placement:

| NIF function | Scheduler | Rationale |
|---|---|---|
| `compile` | `DirtyCpu` | Parsing is CPU-intensive and unbounded; running on dirty schedulers protects normal BEAM schedulers from jitter |
| `eval_compiled` | Normal | Evaluating a precompiled AST is fast (sub-millisecond for typical expressions); normal schedulers avoid the dirty-scheduler context-switch overhead |
| `eval_expression` | `DirtyCpu` | Parse + evaluate in one shot; parsing dominates cost |
| `eval_unary_test` | `DirtyCpu` | Parse + evaluate; same reasoning as `eval_expression` |

**Hot-path profile:** Decision table evaluation at runtime calls `eval_compiled` exclusively (all expressions are precompiled at deploy time). The hot path runs entirely on normal schedulers, which is optimal for throughput.

**Concurrency concern — `Mutex<AstNode>`:** Each `CompiledExpression` wraps the parsed AST in a `Mutex`. When multiple BEAM processes concurrently evaluate the **same** compiled expression reference (e.g., 1,000 BRTs evaluating the same decision table), they serialize on the Rust mutex. This is typically acceptable because:

1. Each unary-test cell has its own `CompiledExpression` — contention distributes across many refs.
2. `eval_compiled` holds the lock only for the evaluation itself (microseconds).
3. The BEAM's preemptive scheduler prevents a single mutex wait from blocking other processes.

Under extreme load (50,000+ concurrent evaluations of the same model), mutex contention can become measurable. Mitigation strategies:

- **Clone the AST per evaluation** (eliminates mutex entirely, adds clone overhead per call).
- **Use `RwLock`** instead of `Mutex` (read-shared for evaluation; only write-locks for mutation, which never happens post-compile).
- **Pool compiled expressions** (N copies per model, round-robin assignment).

None of these are implemented today — the current `Mutex` design is sufficient for observed workloads.

**Dirty scheduler tuning:** The BEAM defaults to `min(N, 64)` dirty CPU schedulers where N is the number of CPU cores. For DMN-heavy deployments:

- Monitor dirty scheduler utilization via `:recon.scheduler_usage/1` or the `observer` tool.
- If dirty schedulers saturate during deploy spikes (many concurrent `compile` calls), increase the count with the `+SDcpu` flag in `vm.args` or `rel/vm.args.eex`.
- The normal scheduler count (`+S`) affects `eval_compiled` throughput — the BEAM default of one per core is generally optimal.

Example `vm.args` for a 16-core production host:

```
+S 16:16       # normal schedulers (default, usually fine)
+SDcpu 16:16   # dirty CPU schedulers (increase if deploy spikes saturate)
+SDio 10:10    # dirty IO schedulers (not used by FEEL NIFs)
```

### NIF batch evaluation

**Status: Not recommended at this time.**

The review identified a potential optimization: batching multiple unary test evaluations (e.g., all input entries for a single rule, or all rules for a single input column) into a single NIF call to reduce NIF-boundary crossing overhead.

**Current state:** Each decision table cell evaluation is an individual `eval_compiled` NIF call. For a 100-rule table with 5 inputs, that's up to 500 NIF calls per evaluation.

**dsntk API surface:**

The `dsntk-feel-evaluator` crate exposes a single `evaluate(scope, ast) -> Value` function. There is no built-in batch API, vectorized evaluation, or multi-AST evaluation entry point.

**Feasibility assessment:**

| Approach | Effort | Benefit | Trade-offs |
|---|---|---|---|
| Rust-side batch: accept `Vec<(ResourceArc, Term)>`, evaluate in a loop, return `Vec<Term>` | Medium | Eliminates N-1 NIF boundary crossings per batch | Increases lock hold time per batch (Mutex); larger term encoding; still sequential FEEL evaluation |
| Rust-side parallel: `rayon::par_iter` over batch items | High | CPU parallelism within a single NIF call | Requires cloning AST nodes (Mutex → Arc); rayon thread pool competes with BEAM schedulers; complex error handling |
| Elixir-side Task.async_stream | Low | Parallelism via BEAM processes | Already available; limited by scheduler count; adds process overhead |

**Why not recommended now:**

1. **P9.3 (rule indexing) already reduces NIF calls significantly** — for indexed columns, no NIF call is needed at all. The remaining NIF calls are only for non-indexed columns.
2. **`eval_compiled` runs on normal schedulers** — NIF boundary crossing overhead is minimal (no dirty scheduler context switch).
3. **The Mutex per CompiledExpression** means batch evaluation within a single NIF call would serialize on the same lock anyway (unless ASTs are cloned).
4. **Implementation complexity** — a Rust batch API requires changes to the NIF bridge, new Rustler term encoding/decoding for vectors of resources, and careful error handling for partial failures.
5. **P9.5 load benchmarks** will establish whether evaluation throughput is actually the bottleneck. If BPMN orchestration overhead dominates, NIF optimization has diminishing returns.

**Revisit conditions:** If P9.5 benchmarks show that FEEL NIF evaluation is the dominant cost component (>60% of per-BRT wall time), batch evaluation becomes worthwhile. The recommended approach would be `Vec<(ResourceArc, Term)>` with per-AST `try_lock` and fallback to individual evaluation on contention.

### Engine-added bindings

Beyond plain FEEL, the engine pre-populates the seven root bindings of §8.1
— `token`, `this`, `context`, `dataObjects`, `process`, `processInstance`,
`identity` — plus the iteration-scoped `loop.*` overlay. No scripting sneaks
in: these are read-only path references evaluated by the FEEL engine.

#### Context assembly — `Context.from_handler_context/2`

All FEEL context assembly **must** go through
`EvilEngine.Expressions.Context.from_handler_context/2`. This function is the
canonical entry point that converts the atom-keyed runtime maps from
`HandlerContext` into properly string-keyed, camelCase maps that the Rust NIF
can decode. Direct construction of `%Context{}` is prohibited.

Key conversions performed:

| HandlerContext field | FEEL binding | Key conversion |
|---|---|---|
| `flow_node_this` | `this` | Already string-keyed (built by `flow_node_this/1`) |
| `context` | `context` | Pass-through (originates from JSON start payload, already string-keyed) |
| `data_objects` | `dataObjects` | Atom keys → string keys via `ensure_string_keys/1` |
| `process` | `process` | `%{id: …}` → `%{"id" => …, "name" => …, "version" => …}` |
| `process_instance` | `processInstance` | `%{id: …, started_at: …}` → `%{"id" => …, "startedAt" => …, "startedBy" => …}` |
| `identity` | `identity` | `%{id: …, roles: …}` → `%{"id" => …, "roles" => …, "groups" => …, "claims" => …}` |

The `context` field on `HandlerContext` is populated from
`State.started_with_context` (the initial start payload) and is immutable for
the lifetime of the process instance.

### Expression evaluation call sites

| Site | Example |
|---|---|
| Conditional sequence flow (**active**) | `<bpmn:conditionExpression>token.amount > 100</bpmn:conditionExpression>` — used by `ExclusiveGateway` handler |
| Conditional boundary / intermediate | same |
| Complex gateway join activation | `<bpmn:activationCondition>activatedCount &gt;= 2</bpmn:activationCondition>` — standard BPMN child of `<bpmn:complexGateway>`; evaluated by `ComplexJoinEvaluator` with the `activatedCount`/`incomingCount` overlay (§8.1) |
| User Task assignees | `<evil:assignees>identity.groups[_.contains("reviewers")]</evil:assignees>` |
| Throw event payload mapping | `<evil:inputMapping source="token.orderId" target="orderId"/>` |
| Data Object association source | inline FEEL in data association |
| Call Activity input mapping (**active**) | `<evil:inputMapping source="..." target="..."/>` — FEEL expression evaluated against caller's token |
| Call Activity output mapping (**active**) | `<evil:outputMapping source="..." target="..."/>` — FEEL expression evaluated against child's aggregated result tokens |
| Loop break / collection / completion | Multi-Instance / Standard Loop FEEL on the loop characteristics |

Every expression is **precompiled** at deploy time and the compiled form is cached keyed by `(process_version_id, flow_node_id, expression_slot)`. Runtime hot path: variable binding + evaluation only — no parsing on the hot path.

---
