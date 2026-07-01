# FEEL NIF Spike — Validation Results

Poc for assessing viability of using dsntk (v0.3.0) + Rustler (v0.37.3) as a FEEL expression parser.

## Summary

**Verdict: PASS.** The dsntk (v0.3.0) + Rustler (v0.37.3) integration is fully
viable for the ThomasTheDaemonEngine FEEL evaluator. All 40 tests pass,
covering every engine-relevant expression pattern.

## Test Matrix

| Category                            | Tests | Pass | Notes                              |
|-------------------------------------|------:|-----:|------------------------------------|
| Compile + eval_compiled round-trip  |     3 |    3 | Precompilation works               |
| One-shot eval_expression            |     2 |    2 |                                    |
| FEEL type coverage                  |     8 |    8 | bool, null, string, int, float, list, map |
| Conditional sequence flow patterns  |     3 |    3 | `token.amount > 100`, compound `and` |
| Path access                         |     2 |    2 | Deep nested `token.order.customer.name` |
| if/then/else                        |     2 |    2 |                                    |
| List operations (for, some, every)  |     4 |    4 |                                    |
| Null propagation (3VL)              |     2 |    2 | `null + 5 => null`                 |
| Built-in functions                  |     5 |    5 | `string length`, `contains`, `count`, `sum`, `not` |
| Temporal types                      |     3 |    3 | Date, duration, date arithmetic    |
| Unary tests                         |     4 |    4 | `< 100`, `[1..5]`, `(1..5)`        |
| Full 7-binding engine context       |     1 |    1 | token, this, context, dataObjects, process, processInstance, identity |
| Precompilation perf sanity          |     1 |    1 | 1000 evals in ~5ms                 |
| **Total**                           |**40** |**40**|                                    |

## Key Findings

### 1. Precompilation Works

The central requirement — "no parsing on the runtime hot path" — is fully satisfied.
`compile/2` returns a `ResourceArc<CompiledExpression>` that wraps the Rust `AstNode`
in a `Mutex`. This opaque reference can be stored in ETS or a GenServer and reused
across arbitrarily many `eval_compiled/2` calls. The 1000-iteration sanity test
confirms correctness and stability under repeated evaluation with varying contexts.

### 2. Scope-Aware Parser

dsntk's FEEL parser is **scope-aware**: it needs to know which variable names exist
at parse time to correctly disambiguate FEEL's context-sensitive grammar. This means:

- `compile/2` requires a context (or at least a context shape) at compile time.
- For the engine's deploy-time precompilation, we pass the 7-binding root context
  shape (with placeholder values) so the parser can resolve names like `token`,
  `this`, `identity`, etc.
- At evaluation time, `eval_compiled/2` receives the actual runtime context values.

**Implication for engine design**: The `EvilEngine.Expressions.compile/1` API should
accept the expression string + a context shape. This is not a limitation — the
engine always knows the context shape at deploy time.

### 3. Unary Test Evaluation

dsntk's `evaluate()` on a `parse_unary_tests()` AST returns the raw unary test
values (e.g., `UnaryLess(100)`) rather than directly comparing against an input.
The comparison happens at a higher level in dsntk's decision table evaluator.

**Workaround**: Wrap the unary test in a FEEL `in` expression:
`__unary_input__ in (<test>)`, binding `__unary_input__` to the actual input value.
This produces the expected boolean result and is syntactically clean.

### 4. Type Mapping (Elixir <-> FEEL)

The NIF bridge handles all relevant FEEL types:

| FEEL Type                | Elixir Representation             |
|--------------------------|-----------------------------------|
| `null`                   | `nil`                             |
| `boolean`                | `true` / `false`                  |
| `number` (integer)       | integer                           |
| `number` (decimal)       | float                             |
| `string`                 | binary string                     |
| `list`                   | list                              |
| `context`                | `%{String.t() => term()}`         |
| `date`                   | `{:feel_date, "YYYY-MM-DD"}`      |
| `time`                   | `{:feel_time, "HH:MM:SS..."}`     |
| `date and time`          | `{:feel_datetime, "..."}`         |
| `days and time duration` | `{:feel_duration_dt, "PT..."}`    |
| `years and months dur.`  | `{:feel_duration_ym, "P..."}`     |

Temporal types are returned as tagged tuples so the Elixir side can convert them
into the engine's preferred temporal structs.

### 5. Binary Size

- Release build (unstripped): **15 MB**
- Release build (stripped):   **13 MB**

Most of the size comes from `reqwest` (HTTP client), which is a transitive
dependency of `dsntk-feel-evaluator`. For the production integration, this
can likely be eliminated by feature-gating or by using only the parser +
evaluator core without the networking features, potentially reducing the
binary to ~5-7 MB.

### 6. Build Performance

- First full build (cargo fetch + compile): ~65 seconds
- Incremental recompile (Rust source change): ~2 seconds
- `mix test` execution (40 tests): ~0.09 seconds

### 7. Dirty Scheduler Integration

All parsing NIFs use `#[nif(schedule = "DirtyCpu")]` to avoid blocking BEAM
schedulers during expression compilation. `eval_compiled` runs on the normal
scheduler since evaluation of a pre-compiled AST is fast.

## Discovered Issues / Risks

| Issue                          | Severity | Mitigation                                     |
|--------------------------------|----------|-------------------------------------------------|
| Scope-aware parser             | Low      | Pass context shape at compile time (natural fit for engine) |
| Unary tests need wrapping      | Low      | Wrap in `in` expression; encapsulate in NIF     |
| `reqwest` dependency bloat     | Low      | Feature-gate or vendor evaluator without HTTP   |
| `FeelNumber` no f64 conversion | Low      | String round-trip works; consider `from_str` in prod |

## Files in This PoC

```
docs/poc/feel_nif_spike/
├── mix.exs                          # Elixir project (rustler dep)
├── lib/feel_nif.ex                  # NIF module (4 functions)
├── native/feel_nif/
│   ├── Cargo.toml                   # Rust crate (dsntk + rustler deps)
│   └── src/lib.rs                   # Rust NIF implementation (261 lines)
├── test/
│   ├── test_helper.exs
│   └── feel_nif_test.exs            # 40 test cases
└── RESULTS.md                       # This file
```

## Conclusion

The Rust NIF approach with dsntk is production-viable. Proceed to Step 2.
