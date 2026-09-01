# DMN Decision Engine

---

## Overview

The `core_dmn` umbrella app implements a DMN 1.5 decision engine: SAX-based XML parsing, structural validation, FEEL expression precompilation, ETS-backed model caching, and synchronous evaluation with structured execution traces. Phase 3 covers single decision tables and literal expressions (G8); Phase 4 adds DRD chaining via `DependencyResolver` and multi-decision evaluation in `Evaluator`; Phase 6 adds all CL3 boxed expression types (G9–G16), Decision Services (G17–G18), and FEEL verification (G20–G21). DMNDI elements are silently skipped by the engine parser — diagram rendering is handled client-side by the SDK parser.

Dependencies: `core_types`, `core_expressions` (same Core-layer boundary as other engine apps).

---

## Architecture

### Data flow

```
DMN XML
  → Parser.parse/1           → %Definitions{}
  → Validator.validate/1     → {:ok, definitions} | {:error, violations}
  → Precompiler.precompile/1 → definitions with compiled FEEL refs
  → ModelCache.put_new(id, definitions)

Evaluation (single decision):
  ModelCache.fetch(decision_version_id)
  → Evaluator.evaluate(definitions, decision_id, input, opts)
  → %EvaluationResult{result, trace, ...}

Evaluation (decision service):
  ModelCache.fetch(decision_version_id)
  → Evaluator.evaluate_service(definitions, service_id, input, opts)
  → %ServiceEvaluationResult{outputs, trace, ...}
```

### Core Layer (`core_dmn`)

#### EvilEngine.DMN

**Path:** `apps/core_dmn/lib/evil_engine/dmn.ex`

Public facade re-exporting the three pipeline stages:

| Function | Delegates to |
|----------|-------------|
| `parse/1` | `Parser.parse/1` |
| `validate/1` | `Validator.validate/1` |
| `parse_and_validate/1` | `parse/1`, then `validate/1`, then `Precompiler.precompile/1` via `with` |

#### Parser

**Path:** `apps/core_dmn/lib/evil_engine/dmn/parser.ex`

```elixir
@spec parse(String.t()) :: {:ok, Definitions.t()} | {:error, term()}
```

SAX-based (Saxy) stream parser. The `SaxHandler` module uses a stack-based approach identical to the BPMN parser: `definitions → decision → decisionTable → input/output/rule → entries`. Hit policy strings (`UNIQUE`, `U`, `FIRST`, `F`, etc.) are normalized to atoms. The full raw XML is preserved on `%Definitions{raw_xml: ...}` for re-serialization.

Phase 6 extends the handler with a **recursive expression body attachment pattern**: every container that holds an `expression_body()` child (Decision, ContextEntry, Binding, BoxedConditional branches, BoxedFilter/For/Every/Some sub-expressions, etc.) receives finished child expressions through `attach_completed_expression/2` → `do_attach/3`, which dispatches on the parent tag found in the handler stack. Nestable expression types (context, invocation, list, relation, conditional, filter, for, every, some) use `push_*`/`pop_*` helper pairs to support arbitrary nesting depth. DMNDI elements are silently skipped by the catch-all handler — diagram interchange is a rendering concern handled by the SDK parser client-side.

**Decision Service parsing (G17):** `<decisionService>` is parsed as a top-level definitions child. Children `<outputDecision>`, `<encapsulatedDecision>`, `<inputDecision>`, and `<inputData>` (within a service) use `href` attributes to reference element IDs. The handler disambiguates top-level `<inputData>` (creates `%InputData{}`) from service-nested `<inputData>` (extracts href) via stack guards.

#### Validator

**Path:** `apps/core_dmn/lib/evil_engine/dmn/validator.ex`

```elixir
@spec validate(Definitions.t()) :: {:ok, Definitions.t()} | {:error, [{atom(), String.t()}]}
```

Collects all violations across all decisions, BKMs, and DRG references — never short-circuits. Validation rules:

| Check | Violation | Condition |
|-------|-----------|-----------|
| Missing expression | `:invalid_decision` | `decision.expression == nil` |
| Hit policy | `:invalid_hit_policy` | Not in the 7 standard policies |
| Aggregation on non-COLLECT | `:invalid_aggregation` | `aggregation != nil` when `hit_policy != :collect` |
| Invalid aggregation value | `:invalid_aggregation` | Not in `[:sum, :min, :max, :count, nil]` |
| Missing inputs | `:missing_inputs` | `inputs == []` |
| Missing outputs | `:missing_outputs` | `outputs == []` |
| Missing rules | `:missing_rules` | `rules == []` |
| Rule dimension mismatch | `:rule_entry_mismatch` | Entry count ≠ column count |
| Blank literal | `:blank_literal_expression` | `LiteralExpression.text` blank after trim |
| BKM missing logic | `:invalid_bkm` | `encapsulated_logic == nil` |
| Non-FEEL function type | `:invalid_function_kind` | `type` not `:feel` (CL1 restriction) |
| Empty function body | `:invalid_bkm` | `FunctionDefinition.body == nil` |
| Duplicate params | `:duplicate_formal_parameters` | Non-unique formal parameter names |
| KR ref integrity | `:invalid_knowledge_requirement` | `required_knowledge_id` not in BKMs |
| AR ref integrity | `:invalid_authority_requirement` | `required_authority/decision/input_id` unresolvable |
| IR ref integrity | `:invalid_information_requirement` | `required_decision_id` not in local decisions (qualified `namespace#id` references are skipped — validated at runtime) |
| ItemDef type_ref | `:invalid_item_definition` | `type_ref` not a built-in or defined name |
| Import namespace | `:invalid_import` | Blank namespace |
| Decision cycle | `:drg_cycle` | DFS detects cycle among decisions |
| BKM cycle | `:bkm_cycle` | DFS detects cycle among BKMs |
| Empty BoxedContext | `:invalid_boxed_context` | `context_entries == []` |
| Context entry expression | `:invalid_boxed_context` | Any entry has `expression == nil` |
| Duplicate context variables | `:invalid_boxed_context` | Non-unique `variable.name` within a context |
| Empty BoxedList | `:invalid_boxed_list` | `elements == []` |
| Relation column mismatch | `:invalid_relation` | Row expression count ≠ column count |
| Missing conditional branch | `:invalid_boxed_conditional` | Any of `if/then/else_expression` is `nil` |
| Missing filter expression | `:invalid_boxed_filter` | `in_expression` or `match_expression` is `nil` |
| Blank iterator variable | `:invalid_boxed_for`/`:invalid_boxed_every`/`:invalid_boxed_some` | `iterator_variable` blank |
| Missing iterator expressions | Same as above | `in_expression` or body expression is `nil` |
| Invocation called_function | `:invalid_boxed_invocation` | `called_function` blank |
| Invocation BKM ref | `:invalid_boxed_invocation` | `called_function` not found in definitions BKMs |
| DS empty outputs | `:invalid_decision_service` | `output_decisions == []` |
| DS unknown decision ref | `:invalid_decision_service` | Any decision ref in output/encapsulated/input not in `definitions.decisions` |
| DS unknown input data ref | `:invalid_decision_service` | Any input data ref not in `definitions.input_data` |
| DS output in encapsulated | `:invalid_decision_service` | A decision appears in both `output_decisions` and `encapsulated_decisions` |
| DS input decision internal | `:invalid_decision_service` | An `input_decision` also appears in output or encapsulated sets |

#### Precompiler

**Path:** `apps/core_dmn/lib/evil_engine/dmn/precompiler.ex`

```elixir
@spec precompile(Definitions.t(), precompile_opts()) :: {:ok, Definitions.t()} | {:error, term()}
```

Walks all decisions and `business_knowledge_models` at deploy time and compiles FEEL expressions into `compiled_ref` / `compiled_expression_ref` fields via `EvilEngine.Expressions.compile/2`. Builds a context shape from `definitions.input_data` names, decision output variable names, BKM output variable names, and (when imports can be resolved) imported decision/BKM variable names. This allows the FEEL parser to resolve variable references at compile time. Input-entry unary tests are compiled as `__unary_input__ in (<test>)` so evaluation reuses `Expressions.evaluate/2` with `__unary_input__` bound to the cell value. Skips `"-"` and `""` input entries (wildcard matches). Accepts an optional `import_resolver` in opts; defaults to `ImportResolver.build_model_cache_resolver/0`. Falls back gracefully if imports cannot be resolved at precompile time (imported model not yet deployed).

Phase 6 extends the precompiler with `precompile_expression_body/2` and `precompile_function_body/2` dispatchers that recursively traverse boxed expression trees. Each boxed expression type has a dedicated `precompile_boxed_*` function that walks its sub-expressions. Iterator expressions (`BoxedFor`, `BoxedEvery`, `BoxedSome`) enrich the `context_shape` with their `iterator_variable` when precompiling the return/satisfies body, enabling FEEL variable resolution within loops.

**Rule indexing (P9.3):** At the end of `precompile_decision_table/2`, the precompiler calls `build_rule_index/1` which analyzes input entries across all rules. For columns where **every** entry is either a simple equality literal (e.g. `"A"`, `42`) or a wildcard (`"-"`, `""`), it builds a per-column index: `literal_value → MapSet(rule_indices)` plus a `wildcards` set for dash/empty entries. The index is stored on `%DecisionTable{rule_index: ...}` and used at runtime by `DecisionTableEvaluator.filter_by_rule_index/2` for O(1) candidate pre-filtering before FEEL evaluation of remaining non-indexed columns. Columns containing FEEL expressions (ranges, comparisons, function calls) are not indexed — the indexer is conservative, only indexing what it can guarantee as exact equality matches.

#### DecisionTableEvaluator

**Path:** `apps/core_dmn/lib/evil_engine/dmn/evaluator/decision_table_evaluator.ex`

Extracted module containing decision table evaluation logic shared by `Evaluator` and `BkmInvoker`:

| Function | Purpose |
|----------|---------|
| `eval_expression/3` | Evaluates a compiled FEEL expression against the input context |
| `eval_input_expression/3` | Evaluates an input column's compiled expression |
| `evaluate_input_entry/2` | Tests a single input entry (unary test) against a resolved value |
| `evaluate_output_entries/2` | Builds an output map from matched rule entries using `named_output_key/2` |
| `named_output_key/2` | Determines the output column key (priority: `name` > `label` > `"output_#{index}"`) |
| `evaluate_compact/2` | Compact rule matching (used by BkmInvoker): applies rule index filtering, then FEEL evaluation of non-indexed columns |
| `match_table_rules/2` | Index-aware rule matching: `filter_by_rule_index/2` narrows candidates, `rule_matches_non_indexed?/3` evaluates remaining columns |
| `resolve_table_inputs/2` | Evaluates all input expressions and returns resolved values |
| `validate_input_constraints/2` | Checks resolved inputs against `inputValues` unary tests |
| `evaluate_default_outputs/1` | Evaluates `defaultOutputEntry` FEEL expressions when no rules match |

#### ModelCache

**Path:** `apps/core_dmn/lib/evil_engine/dmn/model_cache.ex`

GenServer + ETS cache keyed by `decision_version_id` (UUID). Same single-flight pattern as `EvilEngine.BPMN.ModelCache`.

| Aspect | Value |
|--------|-------|
| Primary ETS table | `:evil_engine_dmn_model_cache` (`:set`, `:public`, `read_concurrency: true`) |
| Namespace index table | `:evil_engine_dmn_namespace_index` (`:set`, `:public`) |
| Cache key | `decision_version_id` (UUID string) |
| Cached value | `%Definitions{}` (parsed + precompiled AST) |

Public API:

| Function | Description |
|----------|-------------|
| `put_new/2` | ETS `insert_new` — will not overwrite existing entries; also updates the namespace index |
| `fetch/1` | ETS hit or single-flight GenServer load from backend |
| `get/1` | Returns `Definitions.t() | nil` |
| `delete/1` | Removes a cached entry and updates the namespace index (backfills if multiple versions share a namespace) |
| `reset_state/0` | Clears both tables (test helper) |
| `list_cached_ids/0` | Returns all cached keys |
| `lookup_by_namespace/1` | O(1) lookup of `decision_version_id` by namespace string via the secondary index |

On cache miss, `fetch/1` calls `GenServer.call({:load_and_cache, id})`. Concurrent misses for the same ID coalesce via `Task.async`. The loader is configured via `Application.get_env(:core_dmn, :model_cache_loader)` — in production this is `{EvilEngine.Persistence.ExecutionAdapter, :load_dmn_xml}`.

**Namespace index (P9.1):** The secondary ETS table `:evil_engine_dmn_namespace_index` maps `namespace → decision_version_id` for O(1) import resolution. `put_new/2` inserts the mapping on cache store; `delete/1` removes it and backfills from remaining cached versions sharing the same namespace. `ImportResolver.build_model_cache_resolver/0` delegates to `lookup_by_namespace/1` instead of scanning all cached IDs.

#### TypeResolver

**Path:** `apps/core_dmn/lib/evil_engine/dmn/type_resolver.ex`

Resolves `typeRef` values against `ItemDefinition` declarations and built-in FEEL types (G6). Used by the Evaluator for input coercion (before evaluation) and output type checking (after evaluation).

| Function | Purpose |
|----------|---------|
| `resolve_type/2` | Maps a `type_ref` string to `{:builtin, atom()}` or `{:item_definition, %ItemDefinition{}}` |
| `coerce_input_context/2` | Walks `definitions.input_data`, coerces matching values in `input_context` by declared `type_ref` |
| `coerce_input_context_with_trace/2` | Same as `coerce_input_context/2` but returns `{:ok, map(), [CoercionTrace.t()]}` — used by `Evaluator.do_evaluate/4` to populate `EvaluationTrace.input_coercions` |
| `coerce_value/3` | Coerces a single value to a resolved type descriptor (string→number, ISO 8601→date, collection wrapping, composite field validation) |
| `check_output_types/3` | Soft-checks output column `typeRef` after evaluation; returns `[warning()]` maps with `:output_type_mismatch` code (not hard errors per CL1) |
| `value_conforms?/3` | Predicate: returns `true` when a value matches the resolved type |

Built-in FEEL types: `string`, `number`, `boolean`, `date`, `time`, `dateTime`, `dayTimeDuration`, `yearMonthDuration`, `Any`.

Input coercion pipeline (runs in `Evaluator.evaluate/4` before decision resolution):

1. For each `InputData` with a non-nil `type_ref`, resolve the type via `resolve_type/2`
2. Coerce the corresponding input value (matched by `InputData.name` in the context map)
3. Validate against `allowed_values` if set (via `Expressions.evaluate_unary/3`)
4. On failure: `{:error, :type_coercion_failed, %{input: name, expected: type_ref, got: value}}`

#### ImportResolver

**Path:** `apps/core_dmn/lib/evil_engine/dmn/import_resolver.ex`

Resolves DMN `<import>` cross-model references (G7). Lookup is injected via a resolver function `(namespace -> {:ok, Definitions.t()} | {:error, term()})`, matching the `CalledElementResolver` pattern in `core_execution`.

| Function | Purpose |
|----------|---------|
| `resolve_imports/2` | Resolves every direct import on a `%Definitions{}`; returns `{:ok, %{namespace => Definitions}}` or `{:error, :import_not_found, %{namespace: ...}}` |
| `detect_circular_imports/2` | DFS walk from a deployed model's namespace; returns `{:error, :circular_import, %{chain: [...]}}` when a cycle closes |
| `validate_imports/2` | Deploy-time gate: circular check (root model's imports + transitive resolver walk) then `resolve_imports/2`; violations as `[{atom(), message}]` |
| `resolve_imported_element/3` | Evaluation-time lookup of a qualified reference (`"namespace#ElementId"` or local `"ElementId"`) against local definitions and a resolved-imports map |
| `build_model_cache_resolver/0` | Returns a resolver that delegates to `ModelCache.lookup_by_namespace/1` for O(1) namespace resolution |

`validate_imports/2` uses the in-memory deploying model for direct imports (the model may not yet be in `ModelCache`). `detect_circular_imports/2` loads the root via the resolver (for already-deployed models).

#### Evaluator

**Path:** `apps/core_dmn/lib/evil_engine/dmn/evaluator.ex`

```elixir
@spec evaluate(Definitions.t(), String.t() | nil, map(), evaluate_opts()) ::
        {:ok, EvaluationResult.t()} | {:error, term()} | {:error, atom(), map()}
```

Decision resolution when `decision_id` is `nil`: evaluates the single decision if the model contains exactly one; returns `{:error, {:ambiguous_decision, ...}}` for 2+ decisions, `{:error, {:no_decisions, ...}}` for 0.

DRD chaining (G1): before evaluation, `DependencyResolver.resolve_evaluation_order/2` topologically sorts transitive `required_decision_id` dependencies (diamond-safe, DFS post-order with visited/visiting sets). Each decision in order is evaluated with a shared context: required `InputData` names must be present (`:missing_required_input`), upstream decision outputs are keyed by `Decision.output_variable_name/1` (priority: `variable.name` > `name` > `id`). Errors: `:drg_cycle`, `:missing_required_decision`. Models with no `required_decision_id` links behave as single-decision evaluation (one `DecisionTrace`).

BKM invocation (G2): when a decision has `KnowledgeRequirement` edges, `BkmInvoker.resolve_and_invoke/4` pre-evaluates each referenced BKM before the decision's own expression. Formal parameters are bound by name from the calling context. BKM-to-BKM chains are resolved recursively with cycle detection (`:bkm_cycle`, `:bkm_not_found`). Results are stored in the decision's context under `BkmInvoker.output_variable_name/1` (priority: `variable.name` > `name` > `id`). Single-output decision table results are unwrapped to a scalar value.

Decision Service evaluation (G17–G18): `Evaluator.evaluate_service/4` delegates to `DecisionServiceEvaluator.evaluate/4`. The evaluator resolves the `DecisionService` by ID, pre-evaluates input decisions (external to the service scope), then builds a scoped sub-DRG from output + encapsulated + input decisions. The `DependencyResolver` resolves dependency order over the full scoped graph, but only output and encapsulated decisions are actually evaluated (input decisions are already in the context). Returns `%ServiceEvaluationResult{outputs, trace, ...}` containing only the output decision results. REST endpoint: `POST /decisions/:model_id/services/:service_id/evaluate`.

Cross-model import resolution (G7): at evaluation start, `resolve_imports_if_needed/2` resolves all `<import>` namespaces using the injected `import_resolver` (defaults to `ImportResolver.build_model_cache_resolver/0`). The `DependencyResolver` skips qualified references (`namespace#elementId`) in the local topological sort. When `bind_required_decisions` encounters a qualified `required_decision_id`, it calls `ImportResolver.resolve_imported_element/3` to find the decision in the imported model, then recursively evaluates it via `evaluate/4` on the imported `Definitions`. The result is stored in the shared context under the imported decision's output variable name. Errors: `:import_not_found` (imported model not deployed), `:element_not_found` (decision ID missing in imported model). Deploy-time import validation is intentionally omitted (same rationale as BPMN CallActivities: allow WIP deployments).

#### DependencyResolver

**Path:** `apps/core_dmn/lib/evil_engine/dmn/evaluator/dependency_resolver.ex`

```elixir
@spec resolve_evaluation_order(String.t(), Definitions.t()) ::
        {:ok, [String.t()]}
        | {:error, :drg_cycle, %{decision_ids: [String.t()]}}
        | {:error, :missing_required_decision, %{decision_id: String.t(), required_by: String.t()}}
```

Filters out qualified references (`namespace#elementId`) from the local dependency graph — these are imported decisions resolved at evaluation time by the `Evaluator`, not part of the local topological sort.

#### BkmInvoker

**Path:** `apps/core_dmn/lib/evil_engine/dmn/evaluator/bkm_invoker.ex`

```elixir
@spec resolve_and_invoke([KnowledgeRequirement.t()], Definitions.t(), map(), MapSet.t()) ::
        {:ok, map(), [BkmTrace.t()]}
        | {:error, :bkm_not_found, %{bkm_id: String.t()}}
        | {:error, :bkm_cycle, %{bkm_ids: [String.t()]}}
        | {:error, term()}
```

Resolves and pre-evaluates BKMs referenced via `KnowledgeRequirement` edges. Returns the updated context and a list of `BkmTrace` structs (one per invoked BKM, including recursive dependents). For each required BKM: (1) bind formal parameters from the calling context by name, (2) recursively resolve dependent BKMs, (3) evaluate the `FunctionDefinition` body (LiteralExpression or DecisionTable), (4) store the result under `output_variable_name/1`, (5) build a `BkmTrace` recording timing and formal parameter bindings. Single-output decision table results are unwrapped from `%{"output_0" => value}` to `value` for FEEL ergonomics.

BKM traces from the `build_decision_context` pipeline are attached to the `DecisionTrace` via `%{decision_trace | bkm_traces: bkm_traces}`. For boxed-expression decisions (Path C) that contain `<invocation>` elements, BKM traces are threaded explicitly through the return type: `evaluate_expression_body/3` returns `{:ok, result, bkm_traces}`, and `BoxedExpressionEvaluator` propagates traces through all sub-expression evaluations.

Evaluation paths (dispatched on `decision.expression`):

| Path | Condition | Possible errors |
|------|-----------|-----------------|
| Decision table | `%DecisionTable{} = decision.expression` | `{:input_expression_eval_failed, ...}`, `{:hit_policy_violation, ...}` |
| Literal expression | `%LiteralExpression{} = decision.expression` | `{:literal_expression_eval_failed, text, reason}` |
| Boxed expression | Any other `expression_body()` struct | Dispatched via `evaluate_expression_body/3` (see below) |
| Guard: missing | `decision.expression == nil` | `{:missing_decision_logic, ...}` |

#### BoxedExpressionEvaluator (Phase 6)

**Path:** `apps/core_dmn/lib/evil_engine/dmn/evaluator/boxed_expression_evaluator.ex`

`Evaluator.evaluate_expression_body/3` is the generic entry point for evaluating any expression body type. It pattern-matches on the struct and delegates to `BoxedExpressionEvaluator` for CL3 boxed types. All boxed evaluation functions return `{:ok, result, bkm_traces}` to support explicit BKM trace threading.

| Expression type | Evaluator function | Semantics |
|---|---|---|
| `BoxedContext` | `BoxedExpressionEvaluator.evaluate_context/3` | Sequential entry evaluation; each entry's result bound to `variable.name`; last entry without variable is result |
| `BoxedInvocation` | `BoxedExpressionEvaluator.evaluate_invocation/3` | Resolve BKM by `called_function`, bind arguments, invoke |
| `BoxedList` | `BoxedExpressionEvaluator.evaluate_list/3` | Evaluate each element, return as list |
| `Relation` | `BoxedExpressionEvaluator.evaluate_relation/3` | Evaluate rows; each row produces a map keyed by column names |
| `FunctionDefinition` | Returns `{:function, %FunctionDefinition{}}` | Stored as an opaque value; invocation limited to BKM `encapsulatedLogic` + `BoxedInvocation` |
| `BoxedConditional` | `BoxedExpressionEvaluator.evaluate_conditional/3` | if/then/else branching |
| `BoxedFilter` | `BoxedExpressionEvaluator.evaluate_filter/3` | Evaluate `in_expression` (list), filter by `match_expression` predicate per item |
| `BoxedFor` | `BoxedExpressionEvaluator.evaluate_for/3` | Iterate `in_expression`, bind `iterator_variable`, collect `return_expression` results |
| `BoxedEvery` | `BoxedExpressionEvaluator.evaluate_every/3` | Iterate, evaluate `satisfies_expression`; true iff all satisfy |
| `BoxedSome` | `BoxedExpressionEvaluator.evaluate_some/3` | Iterate, evaluate `satisfies_expression`; true if any satisfies |

Options: `include_unmatched_details: true` includes unmatched rules in the trace with empty `output_values`.

#### HitPolicies

**Path:** `apps/core_dmn/lib/evil_engine/dmn/evaluator/hit_policies.ex`

```elixir
@spec apply(atom(), atom() | nil, [{struct(), map()}], struct()) ::
        {:ok, term()} | {:error, term()}
```

All 7 standard DMN hit policies:

| Hit policy | 0 matches | 1 match | N matches |
|------------|-----------|---------|-----------|
| UNIQUE | `defaultOutputEntry` or `nil` | output | violation if N > 1 |
| FIRST | `defaultOutputEntry` or `nil` | first output | first output (by rule order) |
| ANY | `defaultOutputEntry` or `nil` | output | all must be equal, else violation |
| COLLECT | aggregated (`[]` or `0` for COUNT) | aggregated | aggregated (see below) |
| RULE ORDER | `[]` | list | list in rule order |
| OUTPUT ORDER | `[]` | sorted list | sorted by output priority |
| PRIORITY | `defaultOutputEntry` or `nil` | highest-priority | highest-priority output |

When `defaultOutputEntry` is defined on output columns, UNIQUE/FIRST/ANY/PRIORITY evaluate the default FEEL expression and return it instead of `nil` on zero matches. COLLECT/RULE ORDER/OUTPUT ORDER return empty results (correct per DMN spec — no "default" for aggregation/ordering policies).

COLLECT aggregations:

| Aggregation | Result |
|-------------|--------|
| `nil` | Raw list of output maps |
| `:sum` | Sum of numeric values |
| `:min` | Minimum numeric value |
| `:max` | Maximum numeric value |
| `:count` | `length(outputs)` |

---

## Model Structs

All under `apps/core_dmn/lib/evil_engine/dmn/model/`:

| Struct | Key fields |
|--------|-----------|
| `Definitions` | `id`, `name`, `namespace`, `decisions`, `input_data`, `business_knowledge_models`, `knowledge_sources`, `decision_services`, `item_definitions`, `imports`, `raw_xml` |
| `Decision` | `id`, `name`, `output_label`, `expression` (`Types.expression_body() \| nil`), `information_requirements`, `knowledge_requirements`, `authority_requirements`, `variable`; `output_variable_name/1` returns the context key for DRD chaining |
| `DecisionTable` | `id`, `hit_policy` (atom), `aggregation`, `preferred_orientation`, `inputs`, `outputs`, `rules`, `rule_index` (deploy-time index for equality-test columns; see P9.3) |
| `LiteralExpression` | `id`, `text`, `type_ref`, `expression_language`, `compiled_ref` |
| `Input` | `id`, `label`, `input_expression`, `input_values`, `type_ref`, `compiled_expression_ref` |
| `InputData` | `id`, `name`, `type_ref` |
| `InputEntry` | `id`, `text`, `compiled_ref` |
| `Output` | `id`, `label`, `name`, `output_values`, `type_ref`, `default_output_value` |
| `OutputEntry` | `id`, `text`, `compiled_ref` |
| `Rule` | `id`, `description`, `input_entries`, `output_entries`, `annotation_entries` |
| `InformationRequirement` | `id`, `required_decision_id`, `required_input_id` |
| `BusinessKnowledgeModel` | `id`, `name`, `encapsulated_logic`, `knowledge_requirements`, `authority_requirements`, `variable` |
| `Types` | Shared `expression_body()` union type: `DecisionTable.t() \| LiteralExpression.t() \| BoxedContext.t() \| BoxedInvocation.t() \| BoxedList.t() \| Relation.t() \| FunctionDefinition.t() \| BoxedConditional.t() \| BoxedFilter.t() \| BoxedFor.t() \| BoxedEvery.t() \| BoxedSome.t()` |
| `BoxedContext` | `id`, `context_entries: [ContextEntry.t()]` |
| `ContextEntry` | `variable: InformationItem.t() \| nil`, `expression: expression_body()` |
| `BoxedInvocation` | `id`, `called_function: String.t()`, `bindings: [Binding.t()]` |
| `Binding` | `parameter: InformationItem.t()`, `expression: expression_body()` |
| `BoxedList` | `id`, `elements: [expression_body()]` |
| `Relation` | `id`, `columns: [InformationItem.t()]`, `rows: [[expression_body()]]` |
| `BoxedConditional` | `id`, `if_expression`, `then_expression`, `else_expression` (all `expression_body()`) |
| `BoxedFilter` | `id`, `in_expression`, `match_expression` (both `expression_body()`) |
| `BoxedFor` | `id`, `iterator_variable: String.t()`, `in_expression`, `return_expression` |
| `BoxedEvery` | `id`, `iterator_variable: String.t()`, `in_expression`, `satisfies_expression` |
| `BoxedSome` | `id`, `iterator_variable: String.t()`, `in_expression`, `satisfies_expression` |
| `FunctionDefinition` | `id`, `type` (`:feel`/`:java`/`:pmml`/`:unsupported`), `formal_parameters`, `body: Types.expression_body() \| nil` |
| `InformationItem` | `id`, `name`, `type_ref` |
| `KnowledgeRequirement` | `id`, `required_knowledge_id` |
| `KnowledgeSource` | `id`, `name`, `type`, `authority_requirements` |
| `AuthorityRequirement` | `id`, `required_authority_id`, `required_decision_id`, `required_input_id` |
| `ItemDefinition` | `id`, `name`, `type_ref`, `allowed_values`, `item_components`, `is_collection` |
| `DecisionService` | `id`, `name`, `output_decisions: [String.t()]`, `encapsulated_decisions`, `input_decisions`, `input_data` (all ID lists) |
| `Import` | `id`, `namespace`, `location_uri`, `import_type` |

---

## Evaluation Trace

Every evaluation produces a structured `%EvaluationResult{}` with an embedded `%EvaluationTrace{}`:

```elixir
%EvaluationResult{
  decision_model_id: String.t(),
  decision_name: String.t() | nil,
  hit_policy: atom(),
  result: term(),
  trace: %EvaluationTrace{},
  evaluated_at: DateTime.t(),
  duration_microseconds: non_neg_integer(),
  matched_rules: [String.t()],
  definitions_id: String.t() | nil,
  definitions_namespace: String.t() | nil,
  decision_version_id: String.t() | nil
}
```

Phase 7 enrichment fields (`definitions_id`, `definitions_namespace`, `decision_version_id`) are populated by `Evaluator.evaluate/4` and serialized via `EvaluationResult.to_json_map/1` for REST and FNI `type_properties`.

Trace nesting:

| Level | Struct | Contains |
|-------|--------|----------|
| Root | `EvaluationTrace` | `decisions: [DecisionTrace]`, `input_coercions: [CoercionTrace]` |
| Decision | `DecisionTrace` | `decision_model_id`, `decision_name`, `hit_policy`, `inputs`, `matched_rules`, `unmatched_rules_count`, `result`, `duration_microseconds`, `warnings`, `bkm_traces: [BkmTrace]`, `import_traces: [ImportTrace]` |
| Input | `InputTrace` | `input_id`, `input_label`, `expression`, `resolved_value` |
| Rule | `RuleTrace` | `rule_id`, `rule_index`, `description`, `input_evaluations`, `output_values` |
| Entry | `InputEntryTrace` | `input_id`, `expression`, `tested_value`, `matched` |
| BKM | `BkmTrace` | `bkm_id`, `bkm_name`, `formal_parameters`, `result`, `duration_microseconds`, `dependent_bkm_traces` |
| Import | `ImportTrace` | `namespace`, `decision_id`, `source_definitions_id`, `evaluation_trace`, `result`, `duration_microseconds` |
| Coercion | `CoercionTrace` | `input_name`, `original_value`, `coerced_value`, `target_type`, `coerced` |

In single-decision models, `trace.decisions` contains exactly one `DecisionTrace`. In DRD chaining (Phase 4), upstream decisions appear in dependency order.

All trace structs expose `to_json_map/1` for REST serialization and FNI `type_properties` storage.

### Service evaluation result

Decision Service evaluation returns `%ServiceEvaluationResult{}` instead of `%EvaluationResult{}`. Only output decision values are exposed; encapsulated decisions are internal.

| Field | Type | Description |
|-------|------|-------------|
| `service_id` | `String.t()` | The Decision Service ID |
| `service_name` | `String.t() \| nil` | The Decision Service name |
| `outputs` | `%{String.t() => term()}` | Map of output decision variable names to their evaluated values |
| `trace` | `EvaluationTrace.t()` | Trace scoped to the service's sub-DRG |
| `evaluated_at` | `DateTime.t()` | Evaluation timestamp |
| `duration_microseconds` | `non_neg_integer()` | Wall-clock duration in microseconds |

REST serialization: `ServiceEvaluationResult.to_json_map/1` then `Wire.camelize_keys/1` in `DecisionController.evaluate_service/2` (`serviceId`, `serviceName`, `outputs`, `trace`, `evaluatedAt`, `durationMicroseconds`).

---

## Observability & Trace (Phase 7)

### Telemetry event catalog

Emitted via `:telemetry.span/3` and `:telemetry.execute/3` in `Evaluator` and `ModelCache`.

| Event prefix | Lifecycle | Measurements | Metadata |
|---|---|---|---|
| `[:evil_engine, :dmn, :evaluate]` | `:start` | `system_time` | `decision_model_id`, `decision_version_id` |
| `[:evil_engine, :dmn, :evaluate]` | `:stop` (success) | `duration` | `hit_policy`, `matched_rule_count`, `decision_count`, `decision_model_id`, `decision_version_id` |
| `[:evil_engine, :dmn, :evaluate]` | `:stop` (error) | `duration` | `decision_model_id`, `decision_version_id` (no `hit_policy`/counts) |
| `[:evil_engine, :dmn, :evaluate]` | `:exception` | `duration` | start metadata + `kind`, `reason`, `stacktrace` |
| `[:evil_engine, :dmn, :cache, :hit]` | `:execute` | `count: 1` | `decision_version_id` |
| `[:evil_engine, :dmn, :cache, :miss]` | `:execute` | `count: 1` | `decision_version_id` |

`evaluate_service/4` shares the `[:evil_engine, :dmn, :evaluate]` span with additional metadata: `service_id` (on `:start`/`:stop`), `output_decision_count` (on success `:stop`), and `decision_model_id: nil`.

Note: tagged error returns (`{:error, atom(), map()}`) emit `:stop` (not `:exception`). `:exception` is only emitted when the callback raises (standard `:telemetry.span/3` behavior).

#### Prometheus metrics

Attached in `EvilEngine.Telemetry.Metrics` (`apps/peripheral_telemetry/lib/evil_engine/telemetry/metrics.ex`):

| Prometheus name (dots → underscores on wire) | Type | Tags | Source event |
|---|---|---|---|
| `evil_engine.dmn.evaluations.total` | counter | `hit_policy` | `[:evil_engine, :dmn, :evaluate, :stop]` |
| `evil_engine.dmn.evaluate.duration.milliseconds` | distribution | — | `[:evil_engine, :dmn, :evaluate, :stop]` |
| `evil_engine.dmn.evaluations.exceptions.total` | counter | — | `[:evil_engine, :dmn, :evaluate, :exception]` |
| `evil_engine.dmn.cache.hit.total` | counter | — | `[:evil_engine, :dmn, :cache, :hit]` |
| `evil_engine.dmn.cache.miss.total` | counter | — | `[:evil_engine, :dmn, :cache, :miss]` |

### BkmTrace

Nested module on `EvaluationTrace`. Populated by `BkmInvoker.resolve_and_invoke/4` when a decision has `KnowledgeRequirement` edges.

```elixir
%BkmTrace{
  bkm_id: String.t(),
  bkm_name: String.t() | nil,
  formal_parameters: [%{name: String.t(), bound_value: term()}],
  result: term(),
  duration_microseconds: non_neg_integer(),
  dependent_bkm_traces: [BkmTrace.t()]
}
```

Recursive — nested BKM invocations produce nested `dependent_bkm_traces`.

### ImportTrace

Populated when `Evaluator` evaluates a qualified `required_decision_id` via `ImportResolver.resolve_imported_element/3`.

```elixir
%ImportTrace{
  namespace: String.t(),
  decision_id: String.t(),
  source_definitions_id: String.t(),
  evaluation_trace: EvaluationTrace.t(),
  result: term(),
  duration_microseconds: non_neg_integer()
}
```

Wraps the full evaluation trace of the imported model. `decision_id` is the imported decision's ID within the source model. `result` captures the imported evaluation result. `duration_microseconds` records the wall-clock time of the nested `evaluate/4` call.

### CoercionTrace

Populated by `TypeResolver.coerce_input_context_with_trace/2` before decision resolution.

```elixir
%CoercionTrace{
  input_name: String.t(),
  original_value: term(),
  coerced_value: term(),
  target_type: String.t() | nil,
  coerced: boolean()
}
```

Records whether each typed input was coerced during evaluation.

### DecisionTrace warnings

Populated only for decision-table evaluations by `TypeResolver.check_output_types/3`. Each warning is a map with atom keys internally, stringified by `DecisionTrace.to_json_map/1`:

```elixir
%{
  code: :output_type_mismatch,
  output_id: String.t(),
  output_name: String.t() | nil,
  expected_type_ref: String.t(),
  actual_value: term()
}
```

Literal expression and boxed expression evaluations always have `warnings: []`.

### Debugger data contract

Fields the Studio debugger consumes from evaluation results and traces:

| Trace field | Studio use |
|---|---|
| `definitions_id` | Diagram matching — maps trace decisions back to the deployed DMN model |
| `definitions_namespace` | Import resolution — identifies which namespace an import trace belongs to |
| `bkm_traces` | BKM node highlighting — Studio can overlay invocation timing on the DRG diagram |
| `import_traces` | Cross-model navigation — links to the imported model's evaluation for drill-down |
| `input_coercions` | Input type debugging — shows which inputs were coerced and their original values |
| `warnings` | Output type validation — lists `output_type_mismatch` entries for decision-table outputs |

---

## Persistence Layer

DMN catalog persistence mirrors the BPMN catalog:

| Ash Resource | Table | Key columns |
|---|---|---|
| `DecisionDefinition` | `decision_definitions` | `id`, `model_id`, `name`, `enabled`, `created_at` |
| `DecisionVersion` | `decision_versions` | `id`, `definition_id`, `version`, `dmn_xml`, `deployed_by`, `deleted_at` |

Both resources live in `apps/peripheral_persistence/`. The `DecisionResolverImpl` implements the `core_execution` `DecisionResolver` behaviour for cache-miss loading.

---

## REST API

See [`api.md` §10.1.2](api.md) for the complete endpoint table. Summary:

| Method | Path | Claim |
|--------|------|-------|
| `POST /decisions` | Deploy | `deploy_dmn` |
| `POST /decisions/{id}/evaluate` | Evaluate (latest version) | any authenticated |
| `POST /decisions/{id}/versions/{v}/evaluate` | Evaluate (specific version) | any authenticated |
| `POST /decisions/{id}/services/{sid}/evaluate` | Evaluate Decision Service | any authenticated |
| `GET /decisions` | List | any authenticated |
| `GET /decisions/{id}` | Show | any authenticated |
| `GET /decisions/{id}/versions` | Version history | any authenticated |
| `PUT /decisions/{id}/enable` | Enable | `deploy_dmn` |
| `PUT /decisions/{id}/disable` | Disable | `deploy_dmn` |
| `DELETE /decisions/{id}` | Undeploy all | `delete_dmn` |
| `DELETE /decisions/{id}/versions/{v}` | Soft-delete version | `delete_dmn` |

The `zeeky_boogie_doog` admin override claim bypasses all DMN authorization checks.

---

## Plugin Facade

Plugins access DMN operations through `facade.decisions`, a namespace on the `EngineFacade` struct wired by the `Loader` to `EvilEngine.Api.*` functions with the plugin's synthetic identity pre-injected.

**Path:** `apps/engine_sdk/lib/evil_engine/engine_facade/decisions.ex`

| Closure | Arity | Delegates to |
|---------|-------|-------------|
| `list` | 0 | `Api.list_decision_definitions/0` |
| `get` | 1 | `Api.get_decision_by_model_id/1` |
| `get_latest_version` | 1 | resolve definition → `Api.get_latest_decision_version/1` |
| `validate` | 1 | `Api.validate_dmn/1` (parse + validate without deploying) |
| `deploy` | 1 | `Loader.parse_and_deploy_dmn/3` (runs `DMN.parse_and_validate` before `Api.deploy_dmn_batch/3`) |
| `evaluate` | 3 | resolve definition → `Api.evaluate_decision/3` |
| `evaluate_by_version` | 4 | `Api.evaluate_decision_by_version/4` (specific version) |
| `evaluate_service` | 4 | resolve definition → `Api.evaluate_decision_service/4` |
| `get_versions` | 1 | resolve definition → `Api.list_decision_versions_for_definition/1` |
| `get_xml` | 1 | resolve definition → latest version → `version.dmn_xml` |
| `enable` | 1 | resolve definition → `Api.update_decision_enabled/2` |
| `disable` | 1 | resolve definition → `Api.update_decision_enabled/2` |
| `delete_version` | 2 | resolve definition → find version → `Api.soft_delete_decision_version/3` |
| `undeploy` | 1 | resolve definition → soft-delete all active versions |

All closures that accept a `model_id` resolve through `with_decision/2`, returning `{:error, :decision_not_found}` when the definition doesn't exist.

---

## BRT Integration (Phase 5)

The Business Rule Task handler (`FlowNodes.BusinessRuleTask`) in DMN mode
wires the execution runtime to the DMN evaluator. The dispatch chain:

```
token → in_mappings → payload_contract
  → DecisionResolver.adapter().resolve_latest_version(decision_ref)
  → DMN.ModelCache.fetch(decision_version_id)
  → Task.async { DMN.Evaluator.evaluate(definitions, decision_element_id, payload, opts) }
  → Task.yield(task, timeout) || Task.shutdown(task)
  → result_variable wrapping → out_mappings → result_contract → PayloadCap → downstream
```

### Result shaping

- **Map result** (decision table) → used directly as output payload
- **Scalar result** (literal expression) → wrapped in `%{"result" => scalar}`
- **`result_variable` set** (e.g. `"discount"`) → wrapped as `%{"discount" => dmn_result}`

### `type_properties` shape

Stored on the FNI for auditing and debugger consumption:

```elixir
%{
  mode: "dmn",
  decision_ref: "definitions_discount",
  decision_version_id: "uuid-...",
  definitions_id: "definitions_discount",
  definitions_namespace: "https://example.com/dmn/discount",
  version: "1.0.0",
  hit_policy: "unique",
  matched_rules: ["Rule_2"],
  trace: %{decisions: [%{decision_model_id: ..., inputs: [...], ...}]},
  duration_us: 1234
}
```

Note: `type_properties` is an opaque field — inner keys are stored and returned as **snake_case** strings (not camelCased by `Wire.camelize_keys/1`). This differs from the REST `/evaluate` response where the same trace structs appear in camelCase. Consumers (e.g., the Studio debugger) must handle snake_case when reading from `FlowNodeInstance.typeProperties`.

### Circuit breakers

| Guard | Config key | Default | Behaviour |
|-------|-----------|---------|-----------|
| Max import depth | `:core_dmn, :max_import_depth` | `10` | Rejects recursive cross-model import chains exceeding depth; returns `{:error, :max_import_depth_exceeded, metadata}` |
| Evaluation timeout | `:core_execution, :dmn_evaluation_timeout_ms` | `30_000` | Wraps `Evaluator.evaluate/4` in a `Task.async` + `Task.yield/2`; returns `{:error, {:dmn_evaluation_timeout, metadata}}` on timeout |

### Multi-decision DMN models

When a DMN model contains multiple `<decision>` elements, the evaluator
cannot auto-resolve which decision to evaluate and returns
`{:error, {:ambiguous_decision, ...}}`. The BRT handler reads
`evil:decisionElementId` from the BPMN extension elements and passes it
as the `decision_id` argument to `DMN.Evaluator.evaluate/4`. When the
extension is omitted, `nil` is passed and single-decision models
auto-resolve as before.

### Option passthrough

| BRT field | Evaluator opt | Effect |
|-----------|--------------|--------|
| `trace_unmatched_rules` | `include_unmatched_details` | When `true`, unmatched rules appear in the trace with empty `output_values` |
| `decision_element_id` | `decision_id` (2nd argument) | Selects which `<decision>` to evaluate in multi-decision models |

---

## Plugin Integration

Plugins interact with the DMN subsystem through two channels:

1. **Observation via Event Sinks** — plugins register event sinks that filter for `%FlowNodeInstanceFinished{}` events where `flow_node_type == :business_rule_task`. The event's `type_properties` field (populated on `:finished` terminal state) carries the full execution trace with string keys: `"mode"`, `"decision_ref"`, `"decision_version_id"`, `"matched_rules"`, `"hit_policy"`, `"trace"`, `"duration_us"`. For non-success states (`:fatal`, `:aborted`, `:interrupted`) `type_properties` defaults to `%{}`.

2. **Analysis via Facade Closures** — the `facade.decisions` namespace provides read access to decision models, versions, XML, and evaluation capabilities. Plugins use these to perform post-execution analysis (dead rule detection, regression testing, Decision Service smoke testing) without replacing the BRT execution path.

**Architectural invariant:** Business Rule Task execution is exclusively handled by the engine's built-in `"feel"` and `"dmn"` modes. Plugins never execute BRTs — they observe and analyze. The `implementation="plugin"` mode was removed as an anti-pattern: DMN is the BRT's native purpose, and delegating BRT execution to plugins blurs BPMN element semantics.

**Plugin interaction patterns:**

| Pattern | Mechanism | Example |
|---------|-----------|---------|
| Real-time KPI tracking | Event Sink on `fni.finished` | `decision_kpi_calculator` |
| Trace-based explanation | Named Script reading token trace | `explain_decision` |
| Audit trail publishing | Event Sink + `AuditMessageBuilder` | `decision_trace_publisher` |
| Decision Service validation | `facade.decisions.evaluate_service` | `decision_service_smoke_tester` |
| Version regression detection | `facade.decisions.evaluate` + `get_versions` | `decision_regression_tester` |
| Dead rule detection | Process orchestration + trace analysis | `dead_rule_detector` |
| Real-time latency analytics | Event Sink + histogram + spike detector | `decision_analytics` |
| Post-execution compliance audit | Event Sink + FNI inspect + boundary evaluate | `decision_audit_reporter` |
| DRD chain inspection | `facade.decisions.evaluate` with trace | `drd_chain_orchestrator` |
| CL3 expression showcase | Full evaluation + expression mapping | `boxed_expression_showcase` |

See `examples/plugins/business_rules/` in the repository root for all Elixir examples.

---

## Configuration

| Key | App | Purpose | Default |
|-----|-----|---------|---------|
| `model_cache_loader` | `:core_dmn` | `{module, function}` for cache-miss loading | `{ExecutionAdapter, :load_dmn_xml}` |
| `max_import_depth` | `:core_dmn` | Maximum cross-model import recursion depth | `10` |
| `decision_resolver` | `:core_execution` | Module implementing `DecisionResolver` | `DecisionResolverImpl` (prod), `NoOp` (test) |
| `dmn_evaluation_timeout_ms` | `:core_execution` | Timeout for DMN evaluation in the BRT handler | `30_000` (prod), `5_000` (test) |

---

## File Path Reference

| Module | Path |
|--------|------|
| `EvilEngine.DMN` | `apps/core_dmn/lib/evil_engine/dmn.ex` |
| EvilEngine.DMN.Application (@moduledoc false) | `apps/core_dmn/lib/evil_engine/dmn/application.ex` |
| `EvilEngine.DMN.Parser` | `apps/core_dmn/lib/evil_engine/dmn/parser.ex` |
| `EvilEngine.DMN.Parser.SaxHandler` | `apps/core_dmn/lib/evil_engine/dmn/parser/sax_handler.ex` |
| `EvilEngine.DMN.Parser.SaxHandler.BoxedExpressions` | `apps/core_dmn/lib/evil_engine/dmn/parser/sax_handler/boxed_expressions.ex` |
| `EvilEngine.DMN.Validator` | `apps/core_dmn/lib/evil_engine/dmn/validator.ex` |
| `EvilEngine.DMN.Precompiler` | `apps/core_dmn/lib/evil_engine/dmn/precompiler.ex` |
| `EvilEngine.DMN.ModelCache` | `apps/core_dmn/lib/evil_engine/dmn/model_cache.ex` |
| `EvilEngine.DMN.TypeResolver` | `apps/core_dmn/lib/evil_engine/dmn/type_resolver.ex` |
| `EvilEngine.DMN.ImportResolver` | `apps/core_dmn/lib/evil_engine/dmn/import_resolver.ex` |
| `EvilEngine.DMN.QualifiedReference` | `apps/core_dmn/lib/evil_engine/dmn/qualified_reference.ex` |
| `EvilEngine.DMN.Evaluator` | `apps/core_dmn/lib/evil_engine/dmn/evaluator.ex` |
| `EvilEngine.DMN.Evaluator.DecisionTableEvaluator` | `apps/core_dmn/lib/evil_engine/dmn/evaluator/decision_table_evaluator.ex` |
| `EvilEngine.DMN.Evaluator.BoxedExpressionEvaluator` | `apps/core_dmn/lib/evil_engine/dmn/evaluator/boxed_expression_evaluator.ex` |
| `EvilEngine.DMN.Evaluator.BkmInvoker` | `apps/core_dmn/lib/evil_engine/dmn/evaluator/bkm_invoker.ex` |
| `EvilEngine.DMN.Evaluator.DependencyResolver` | `apps/core_dmn/lib/evil_engine/dmn/evaluator/dependency_resolver.ex` |
| `EvilEngine.DMN.Evaluator.HitPolicies` | `apps/core_dmn/lib/evil_engine/dmn/evaluator/hit_policies.ex` |
| `EvilEngine.DMN.EvaluationResult` | `apps/core_dmn/lib/evil_engine/dmn/evaluation_result.ex` |
| `EvilEngine.DMN.EvaluationTrace` | `apps/core_dmn/lib/evil_engine/dmn/evaluation_trace.ex` |
| `EvilEngine.DMN.EvaluationTrace.BkmTrace` | `apps/core_dmn/lib/evil_engine/dmn/evaluation_trace.ex` (nested module) |
| `EvilEngine.DMN.EvaluationTrace.ImportTrace` | `apps/core_dmn/lib/evil_engine/dmn/evaluation_trace.ex` (nested module) |
| `EvilEngine.DMN.EvaluationTrace.CoercionTrace` | `apps/core_dmn/lib/evil_engine/dmn/evaluation_trace.ex` (nested module) |
| `EvilEngine.DMN.Model.Types` | `apps/core_dmn/lib/evil_engine/dmn/model/types.ex` |
| `EvilEngine.DMN.Model.Definitions` | `apps/core_dmn/lib/evil_engine/dmn/model/definitions.ex` |
| `EvilEngine.DMN.Model.Decision` | `apps/core_dmn/lib/evil_engine/dmn/model/decision.ex` |
| `EvilEngine.DMN.Model.DecisionTable` | `apps/core_dmn/lib/evil_engine/dmn/model/decision_table.ex` |
| `EvilEngine.DMN.Model.LiteralExpression` | `apps/core_dmn/lib/evil_engine/dmn/model/literal_expression.ex` |
| `EvilEngine.DMN.Model.Input` | `apps/core_dmn/lib/evil_engine/dmn/model/input.ex` |
| `EvilEngine.DMN.Model.InputData` | `apps/core_dmn/lib/evil_engine/dmn/model/input_data.ex` |
| `EvilEngine.DMN.Model.InputEntry` | `apps/core_dmn/lib/evil_engine/dmn/model/input_entry.ex` |
| `EvilEngine.DMN.Model.Output` | `apps/core_dmn/lib/evil_engine/dmn/model/output.ex` |
| `EvilEngine.DMN.Model.OutputEntry` | `apps/core_dmn/lib/evil_engine/dmn/model/output_entry.ex` |
| `EvilEngine.DMN.Model.Rule` | `apps/core_dmn/lib/evil_engine/dmn/model/rule.ex` |
| `EvilEngine.DMN.Model.InformationRequirement` | `apps/core_dmn/lib/evil_engine/dmn/model/information_requirement.ex` |
| `EvilEngine.DMN.Model.BusinessKnowledgeModel` | `apps/core_dmn/lib/evil_engine/dmn/model/business_knowledge_model.ex` |
| `EvilEngine.DMN.Model.FunctionDefinition` | `apps/core_dmn/lib/evil_engine/dmn/model/function_definition.ex` |
| `EvilEngine.DMN.Model.InformationItem` | `apps/core_dmn/lib/evil_engine/dmn/model/information_item.ex` |
| `EvilEngine.DMN.Model.KnowledgeRequirement` | `apps/core_dmn/lib/evil_engine/dmn/model/knowledge_requirement.ex` |
| `EvilEngine.DMN.Model.KnowledgeSource` | `apps/core_dmn/lib/evil_engine/dmn/model/knowledge_source.ex` |
| `EvilEngine.DMN.Model.AuthorityRequirement` | `apps/core_dmn/lib/evil_engine/dmn/model/authority_requirement.ex` |
| `EvilEngine.DMN.Model.ItemDefinition` | `apps/core_dmn/lib/evil_engine/dmn/model/item_definition.ex` |
| `EvilEngine.DMN.Model.Import` | `apps/core_dmn/lib/evil_engine/dmn/model/import.ex` |
| `EvilEngine.DMN.Model.BoxedContext` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_context.ex` |
| `EvilEngine.DMN.Model.ContextEntry` | `apps/core_dmn/lib/evil_engine/dmn/model/context_entry.ex` |
| `EvilEngine.DMN.Model.BoxedInvocation` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_invocation.ex` |
| `EvilEngine.DMN.Model.Binding` | `apps/core_dmn/lib/evil_engine/dmn/model/binding.ex` |
| `EvilEngine.DMN.Model.BoxedList` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_list.ex` |
| `EvilEngine.DMN.Model.Relation` | `apps/core_dmn/lib/evil_engine/dmn/model/relation.ex` |
| `EvilEngine.DMN.Model.BoxedConditional` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_conditional.ex` |
| `EvilEngine.DMN.Model.BoxedFilter` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_filter.ex` |
| `EvilEngine.DMN.Model.BoxedFor` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_for.ex` |
| `EvilEngine.DMN.Model.BoxedEvery` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_every.ex` |
| `EvilEngine.DMN.Model.BoxedSome` | `apps/core_dmn/lib/evil_engine/dmn/model/boxed_some.ex` |
| `EvilEngine.DMN.Model.DecisionService` | `apps/core_dmn/lib/evil_engine/dmn/model/decision_service.ex` — DecisionService model struct |
| `EvilEngine.DMN.Evaluator.DecisionServiceEvaluator` | `apps/core_dmn/lib/evil_engine/dmn/evaluator/decision_service_evaluator.ex` — Scoped sub-DRG evaluator |
| `EvilEngine.DMN.ServiceEvaluationResult` | `apps/core_dmn/lib/evil_engine/dmn/service_evaluation_result.ex` — Service evaluation result struct |
| `DecisionDefinition` (Ash) | `apps/peripheral_persistence/lib/evil_engine/persistence/resources/decision_definition.ex` |
| `DecisionVersion` (Ash) | `apps/peripheral_persistence/lib/evil_engine/persistence/resources/decision_version.ex` |
| `DecisionResolverImpl` | `apps/peripheral_persistence/lib/evil_engine/persistence/decision_resolver_impl.ex` |
| `DecisionController` | `apps/api_web/lib/evil_engine_web/http/controllers/decision_controller.ex` |
