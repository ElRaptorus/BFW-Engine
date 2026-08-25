# Common Pitfalls

Recurring mistakes, gotchas, and non-obvious constraints discovered during
engine development. Each entry describes the mistake, explains why it
happens, and shows the correct approach.

---

## P1: Core must not import Peripheral — use a Persistence behaviour

**Mistake:** Calling `Ash.create/3` or `Ash.get/3` directly from `core_execution` to persist PI/FNI state. This compiles but violates the Core → Peripheral dependency direction.

**Why it happens:** The PI runtime needs to write to the database, and Ash is the persistence framework. The natural impulse is to call Ash directly.

**Correct approach:** Define a `@behaviour` in Core (`EvilEngine.Execution.Persistence`) with callbacks like `create_process_instance/1`. Provide a `NoOp` adapter for tests. The real Ash implementation (`EvilEngine.Persistence.ExecutionAdapter`) lives in `peripheral_persistence` and is wired via `Application.get_env(:core_execution, :persistence_adapter)`.

```elixir
# In core_execution — behaviour definition
defmodule EvilEngine.Execution.Persistence do
  @callback create_process_instance(map()) :: {:ok, map()} | {:error, term()}
  def adapter, do: Application.get_env(:core_execution, :persistence_adapter, __MODULE__.NoOp)
end

# In peripheral_persistence — Ash-backed implementation
defmodule EvilEngine.Persistence.ExecutionAdapter do
  @behaviour EvilEngine.Execution.Persistence
  @impl true
  def create_process_instance(attrs), do: ...
end
```

---

## P2: gen_statem — do validation in init/1, not in deferred internal events

**Mistake:** Using `{:ok, :preparing, data, [{:next_event, :internal, {:prepare, opts}}]}` from `init/1` to defer model fetch and Start Event resolution to a state callback. This causes `start_link` to return `{:ok, pid}` before validation runs, so startup errors never propagate to the caller.

**Why it happens:** It feels clean to separate "initialization" from "preparation" into different state callbacks. But `:gen_statem` sends `proc_lib:init_ack` (the `{:ok, pid}` reply) immediately after `init/1` returns, before processing queued internal events.

**Correct approach:** Do all validation (model fetch, Start Event resolution, Task.Supervisor start) synchronously inside `init/1`. Return `{:stop, {reason, data}}` on failure (propagates as `{:error, {reason, data}}` to caller) or `{:ok, :running, data}` on success.

```elixir
def init(opts) do
  with {:ok, model} <- fetch_process_model(opts.process_version_id),
       {:ok, start} <- resolve_start_event(model, opts[:start_event_id]),
       {:ok, sup}   <- Task.Supervisor.start_link(strategy: :one_for_one) do
    data = %State{...}
    {:ok, :running, data}
  else
    {:error, reason} -> {:stop, {reason, %State{...}}}
  end
end
```

---

## P3: SequenceFlowResolver — don't rely on FlowNode.outgoing

**Mistake:** Using `flow_node.outgoing` (the list of outgoing sequence flow IDs embedded in the FlowNode struct) to find successor flows. This field is only populated if the BPMN XML includes `<bpmn:outgoing>` child elements on each flow node, which many BPMN editors omit.

**Why it happens:** The BPMN spec defines `<bpmn:outgoing>` as an optional convenience element on flow nodes. The parser reads it when present, but many real-world BPMN files only define `sourceRef`/`targetRef` on the `<bpmn:sequenceFlow>` elements themselves.

**Correct approach:** Fall back to scanning `process.sequence_flows` by `source_ref` when `outgoing` is empty:

```elixir
defp fetch_outgoing_flows(%FlowNode{} = node, %BpmnProcess{} = process) do
  case node.outgoing do
    ids when is_list(ids) and ids != [] ->
      # Use the pre-indexed outgoing list
      flow_index = Map.new(process.sequence_flows, &{&1.id, &1})
      Enum.filter(ids, &Map.has_key?(flow_index, &1)) |> Enum.map(&flow_index[&1])

    _ ->
      # Scan by source_ref
      Enum.filter(process.sequence_flows, &(&1.source_ref == node.id))
  end
end
```

---

## P4: Ash resources need `primary? true` on named create actions

**Mistake:** Defining a named `create :create do ... end` action without `primary? true`. When `Ash.create/3` is called without specifying an action, Ash looks for the primary create action. Without `primary? true`, a named action is not auto-promoted, and Ash raises `"Required primary create action for ..."`.

**Why it happens:** In Ash 3.x, `defaults [:create]` would auto-create a primary create action, but a manually defined `create :create do ... end` block does not inherit the `primary?` flag. The `defaults [:read]` line in the same block adds to the confusion.

**Correct approach:** Always add `primary? true` to named create actions that should serve as the default:

```elixir
create :create do
  primary? true
  accept [:id, :state, ...]
end
```

---

## P5: FNI IDs must be valid UUIDv7 when the Ash resource declares `:uuid_v7`

**Mistake:** Using a custom `generate_id()` that produces UUIDv4-format strings while the Ash resource attribute is declared as `:uuid_v7`. The create action silently fails because Ash cannot load the value as `UUIDv7`.

**Why it happens:** `core_execution` cannot depend on `ash`, so it cannot call `Ash.UUIDv7.generate/0` directly. A hand-rolled UUID generator is needed, but it must produce the correct version-7 format.

**Correct approach:** Generate proper UUIDv7 using timestamp + random bits:

```elixir
defp generate_id do
  timestamp_ms = System.system_time(:millisecond)
  <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
  <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
  |> Base.encode16(case: :lower)
  |> then(fn <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> ->
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end)
end
```

---

## P6 (removed)

Entry removed — no longer applicable. Handlers now receive the FNI ID via `HandlerContext.flow_node_instance_id` and explicitly use it in async return tuples. The original concern about handlers not knowing the FNI ID was superseded by the `HandlerContext` struct.

---

## P7: `ModelCache.put_new` inside a DB transaction

**Mistake:** Calling <code>EvilEngine.BPMN.ModelCache.put_new/2</code> **inside** the same database transaction that inserts `process_versions`. If the transaction **rolls back**, the ETS cache entry can still exist — deploy failures or aborted batches leave a **stale AST** keyed by a `process_version_id` that was never committed (or points at rolled-back data).

**Why it happens:** ETS is not transactional with Postgres. The cache is a per-node side store; only SQL commit/rollback affects durable rows.

**Correct approach:** Call **`ModelCache.put_new` only after the transaction commits successfully** (e.g. move cache warming to the success path after `Repo.transaction` returns `{:ok, _}`). Batch deploy paths should insert all version rows first, commit, then populate the cache for the committed ids.

## P8: Atom-keyed maps passed to the FEEL evaluator

**Mistake:** Passing a raw Elixir map with atom keys (e.g., `%{token: payload, this: payload}`) to `Expressions.eval/2` instead of building a proper `%Expressions.Context{}` struct. The Rust NIF expects string-keyed maps; atom keys cause expressions like `token.input` to silently evaluate to `null` instead of returning an error, making FEEL mapping failures invisible.

**Why it happens:** Elixir idiomatically uses atom keys (`%{foo: "bar"}`). The `Expressions.eval/2` API has a clause accepting raw maps alongside `%Context{}` structs, so compilation succeeds. But the NIF only matches string keys (`"token"`, `"this"`), so atom-keyed entries become invisible at evaluation time.

**Correct approach:** Always build and pass a `%Expressions.Context{}` struct. Its `to_feel_scope/1` function produces the string-keyed map the NIF requires. Never pass ad-hoc maps to `Expressions.eval/2` for handler-level FEEL evaluation. Use `Context.flow_node_this/1` to populate the `this` binding with flow node metadata — **never** set `this` to the token payload (see P16).

```elixir
feel_ctx = %Expressions.Context{
  token: payload || %{},
  this: Expressions.Context.flow_node_this(flow_node),
  context: %{},
  data_objects: context.data_objects,
  process: context.process,
  process_instance: context.process_instance,
  identity: context.identity
}
Expressions.eval(expression, feel_ctx)
```

---

## P9: Soft-deletable resources MUST have `base_filter` on `:read`

**Mistake:** Adding a `deleted` boolean column to an Ash resource but leaving the default `:read` action unfiltered. Deleted records become visible through GraphQL queries, REST endpoints, WebSocket channel joins, and Ash calculations.

**Why it happens:** `defaults [:read]` generates a `:read` action with no filter. Nothing prevents queries from returning `deleted = true` rows unless the resource explicitly excludes them.

**Correct approach:** Replace `defaults [:read]` with an explicit `:read` action that filters out deleted records. Suppress the Ash primary-read warning since the filter is intentional:

```elixir
use Ash.Resource,
  ...,
  primary_read_warning?: false

actions do
  defaults []

  read :read do
    primary? true
    filter expr(deleted == false)
  end

  # ... other actions ...
end
```

Error messages must never reveal that a record is soft-deleted. From the consumer's perspective, a deleted resource simply does not exist — all errors should say "not found", never "soft-deleted".

---

## P10: Never expose soft-delete terminology in public APIs, SDK types, or documentation

**Mistake:** Using the term "soft-delete" in TSDoc comments, SDK type names, API error messages, or user-facing documentation. For example: `/** Soft-delete a terminal process instance. */` or returning an error like `"The process version was soft-deleted"`.

**Why it happens:** Soft-delete is an internal implementation detail — the database retains the row with a `deleted` flag. Developers working on the codebase know this and naturally use the term in descriptions. But from the consumer's perspective, a deleted resource is gone. Revealing that it still exists internally is both confusing and a potential security concern (it tells an attacker the data is recoverable).

**Correct approach:**

- **Public API errors:** Always say "not found". Never mention "soft-deleted", "marked as deleted", or "flagged for deletion".
- **SDK types:** Do not include `deleted`, `deletedAt`, or `deletedBy` fields on any public type. These fields exist in the database schema but must never be exposed through REST, GraphQL, WebSocket, or plugin APIs.
- **TSDoc / documentation:** Describe the operation as "delete", not "soft-delete". The consumer does not need to know (or care) whether the engine uses hard or soft deletion internally.
- **Internal code comments:** Using "soft-delete" in internal Elixir code comments or architecture docs is fine — the distinction matters for developers working on the engine. The rule applies only to consumer-facing surfaces.

---

## P11: ResumeRunner must only resume root-level PIs

**Mistake:** Querying all PIs with `state == "running"` for resume, without filtering out child PIs (those with a non-nil `parent_process_instance_id`). This causes child PIs spawned by Call Activities to be resumed independently by `ResumeRunner` **and** by their parent's Call Activity handler — leading to duplicate execution, race conditions, and unpredictable state.

**Why it happens:** The `list_running_process_instances` query was initially written before Call Activity support existed. When Call Activities were added, the resume query was not updated to exclude child PIs.

**Correct approach:** Filter to root-level PIs only. Child PIs are managed exclusively by their parent handler (Call Activity or SubProcess) during resume — it either re-monitors a still-running child or spawns a new one.

```elixir
def list_running_process_instances do
  ProcessInstance
  |> Ash.Query.filter(state == "running" and is_nil(parent_process_instance_id))
  |> Ash.read(domain: @domain, authorize?: false)
  |> ...
end
```

---

## P12: <code>Ash.set_actor/1</code> does not exist in Ash 3.x — use `Ash.PlugHelpers.set_actor/2`

**Mistake:** Calling <code>Ash.set_actor(actor)</code> inside a Plug to set the actor for downstream Ash calls.

**Why it happens:** Ash 2.x had a process-dictionary-based <code>Ash.set_actor/1</code> that stored the actor globally for the current process. In Ash 3.x this function was removed. Code or documentation written against Ash 2.x (or generated from stale examples) will reference it.

**Correct approach:** In a Plug context, store the actor on the `Plug.Conn` struct using `Ash.PlugHelpers.set_actor/2`. Downstream code retrieves it with `Ash.PlugHelpers.get_actor/1`.

```elixir
# Wrong — Ash.set_actor/1 is undefined in Ash 3.x
def call(conn, _opts) do
  Ash.set_actor(prepare_actor(conn.assigns[:identity]))
  conn
end

# Correct — actor stored on the conn, not in the process dictionary
def call(conn, _opts) do
  case conn.assigns[:identity] do
    nil      -> conn
    identity -> Ash.PlugHelpers.set_actor(conn, prepare_actor(identity))
  end
end
```

Note: plain `Ash.read/create/update/destroy` calls inside Phoenix controllers do **not** automatically inherit the actor from `conn.private[:ash][:actor]`. They require an explicit `actor:` keyword argument or `authorize?: false`. The actor on the conn is consumed by AshPhoenix-aware controller helpers, and will be used automatically after the `EvilEngine.Api` facade migration.

---

## P13: Ash read policies return `{:ok, []}` on failure, not `{:error, %Ash.Error.Forbidden{}}`

**Mistake:** Writing tests or production code that expects `{:error, %Ash.Error.Forbidden{}}` when an Ash read policy is not satisfied (e.g. no actor present and `authorize_if actor_present()` fails).

**Why it happens:** Write policies (create, update, destroy) do return hard `Forbidden` errors when not satisfied. Read policies behave differently by design.

**Correct approach:** For read actions, Ash uses row-level filtering rather than hard errors. When a policy condition fails, Ash adds a `false` filter to the query, so the result is `{:ok, []}` (empty list) rather than a Forbidden error. This is intentional — it prevents information leakage about whether records exist at all.

```elixir
# Wrong — read policies return {:ok, []} not {:error, Forbidden}
assert {:error, %Ash.Error.Forbidden{}} = Resource |> Ash.read(domain: Domain)

# Correct
assert {:ok, []} = Resource |> Ash.read(domain: Domain)

# To actually trigger a hard Forbidden on a read, pass authorize?: true
# and ensure the resource is configured to always enforce authorization.
# Without an actor and without authorize?: true, Ash may skip policy evaluation.
assert {:error, %Ash.Error.Forbidden{}} =
  Resource |> Ash.read(domain: Domain, authorize?: true, actor: nil)
```

---

## P14: User-payload subtrees must not be camelCased

**Mistake:** Adding a user-payload field (like `payload`, `inputToken`, `typeProperties`) to the Wire module's recursive conversion, or forgetting to add a new opaque field to the `@opaque_atom_fields` set.

**Why it happens:** The camelCase encoder recurses into nested maps by default. Fields carrying user-defined data structures (process tokens, form data, JWT claims) must be excluded from conversion because downstream consumers depend on the exact key names the process author chose.

**Correct approach:** When adding a new field that carries user or plugin data, add its atom name to `@opaque_atom_fields` in `EvilEngine.Types.Wire`. The canonical list includes: `payload`, `result`, `input_token`, `output_token`, `started_with_context`, `started_by`, `deployer`, `claims`, `form_fields`, `type_properties`, `error_info`, `payload_contract`, `result_contract`, `data_contracts`, `bpmn_xml`, `violations`, `metadata`, `deleted_by`, `data_object_cache`.

**Do NOT mark engine-structural error fields as opaque.** Fields like `failures`, `conflicts`, `details`, and `reason` in error responses contain engine-built maps with structural keys (e.g. `processModelId`, `rulesetFailures`) that must be camelCased. Only truly user-authored data belongs in the opaque set.

---

## P15: Partitioned tables require child partitions before INSERT

**Mistake:** Running `mix ecto.reset` (or `mix ecto.migrate`) and then immediately executing integration tests that write to `data_object_writes` or `process_instance_events`. The INSERTs fail with `ERROR: no partition of relation "data_object_writes" found for row` and PIs go `fatal`.

**Why it happens:** The migration creates the parent partitioned tables (`PARTITION BY RANGE (created_at)` / `(occurred_at)`) but does not create child partitions. PostgreSQL requires at least one child partition whose range covers the row's timestamp value before any INSERT can succeed. Without it, the DB has nowhere to route the row.

**Correct approach:** Always call `EvilEngine.Persistence.Partitions.ensure_partitions()` after migrations and before any test or runtime code that writes to partitioned tables.

---

## P16: `this` binding must be flow node metadata — never the token payload

**Mistake:** Setting `this` to the token payload (or output payload) when assembling a FEEL `%Context{}`. This causes `this.id`, `this.name`, and `this.type` to resolve to token fields instead of the executing flow node's BPMN metadata, silently corrupting any expression that relies on the documented binding semantics.

**Why it happens:** Early handler implementations copied `this: payload` from a pattern where `this` was intended as a "current scope" alias for `token`. Since most FEEL expressions only reference `token.*`, the mismatch went undetected by tests. FEEL's null propagation made things worse — `this.name` returned `null` instead of an error, so broken expressions silently produced incorrect results instead of failing.

**Correct approach:** Use `Context.from_handler_context/2` (see P17) which builds `this` correctly.

---

## P17: Never build `%Context{}` manually — use `from_handler_context/2`

**Mistake:** Constructing `%EvilEngine.Expressions.Context{}` structs inline in handlers, passing atom-keyed maps for `process`, `process_instance`, or `identity`.

**Why it happens:** The Rust FEEL NIF decodes nested maps via `HashMap<String, Term>`. Elixir atom keys cannot be decoded as Rust `String` values, so atom-keyed maps silently become `Value::Null` in FEEL. The error is invisible because FEEL uses null propagation — `process.id` returns `null` instead of raising an error, so expressions silently produce wrong results.

**Correct approach:** Always call `Context.from_handler_context(handler_context, token_payload)` to build FEEL contexts. This function:

1. Converts `process` (atom-keyed `%{id: ..., name: ..., version: ...}`) to `%{"id" => ..., "name" => ..., "version" => ...}`
2. Converts `process_instance` to camelCase string keys (`startedAt`, `startedBy`)
3. Converts `identity` to string keys
4. Converts `DateTime` values to ISO 8601 strings
5. Populates `context` from `HandlerContext.context` (the immutable start payload)
6. Stringifies any atom keys in `data_objects`

```elixir
# Wrong — atom keys become null in FEEL
feel_context = %Context{
  token: payload,
  process: context.process,        # atom keys!
  identity: context.identity,      # atom keys!
  context: %{},                    # always empty!
  ...
}

# Correct — canonical assembly with proper key conversion
feel_context = Context.from_handler_context(handler_context, payload)
```

---

## P18: The `context` FEEL binding must be populated from `started_with_context`

**Mistake:** Hardcoding `context: %{}` in FEEL context assembly. This makes the `context.*` binding always empty, preventing FEEL expressions from accessing process-level variables.

**Why it happens:** `HandlerContext` originally did not have a `context` field, and `started_with_context` on `ProcessInstance.State` was only used for persistence, not for FEEL evaluation.

**Correct approach:** `HandlerContext` now carries a `context` field populated from `state.started_with_context || %{}` in `build_handler_context/3`. The `Context.from_handler_context/2` function reads this field. Never hardcode `context: %{}` — always read from the handler context.

---

## P19: FEEL `Expressions.compile/2` requires a context shape with variable names

**Mistake:** Calling `Expressions.compile(expression)` (or `compile(expression, %{})`) for expressions that reference variables like `x + y`. The compiled reference succeeds but evaluates to `nil` at runtime because the FEEL parser didn't know `x` and `y` were variable references.

**Why it happens:** The Rust NIF FEEL parser is scope-aware — it needs to know which names are variables at parse time to distinguish them from function names or reserved words. Without a context shape declaring the variable names, the parser treats unknown names as null references.

**Correct approach:** Always pass a context shape map with at least the variable names as keys:

```elixir
# Wrong — compiles but evaluates to nil for variable references
{:ok, ref} = Expressions.compile("x + y", %{})

# Correct — FEEL parser knows x and y are variables
{:ok, ref} = Expressions.compile("x + y", %{"x" => nil, "y" => nil})
```

The DMN `Precompiler` builds this context shape from `definitions.input_data` names and BKM `formal_parameters`. The BPMN runtime uses `Context.to_feel_scope/1` which already provides full variable names.

---

## P20: Fatal PI transition must persist ALL non-terminal FNI states — not just kill pids

**Mistake:** Implementing `terminate_active_fnis` to only call `Process.exit(pid, :kill)` on active FNIs without persisting their state change to the database. This leaves `active` and `waiting` FNI rows in the DB after the PI is `fatal`, creating an inconsistency between PI state and FNI states.

**Why it happens:** The abort path (`abort_all_fnis`) was implemented correctly — it kills pids AND persists FNI state to `aborted`. The fatal path was implemented as a simpler "kill-only" function, presumably because the gen_statem is stopping anyway. But the DB survives the process: when the PI is queried later (for debugging, retry, or audit), stale `active`/`waiting` FNI rows cause confusion and incorrect retry logic.

**Correct approach:** `fatal_all_fnis` (renamed from `terminate_active_fnis`) must mirror `abort_all_fnis`: filter all `active`/`waiting` FNIs, kill their pids, persist each to `fatal`, emit `FlowNodeInstanceFinished` events, and invoke `handle_fatal/1` on the handler if implemented. Since the handler-owned lifecycle refactoring, both `fatal_all_fnis` and `abort_all_fnis` delegate individual FNI transitions to `FniLifecycle.transition_to_fatal/4` and `FniLifecycle.transition_to_aborted/4` respectively:

```elixir
defp fatal_all_fnis(data) do
  data.flow_node_instance_states
  |> Enum.filter(fn {_id, entry} -> entry.state in [:active, :waiting] end)
  |> Enum.each(fn {flow_node_instance_id, entry} ->
    if entry.pid != nil, do: Process.exit(entry.pid, :kill)

    flow_node = find_flow_node(data, entry.flow_node_id)

    FniLifecycle.transition_to_fatal(
      flow_node_instance_id,
      data.process_instance_id,
      %{reason: "process_fatal"},
      flow_node
    )

    invoke_optional_callback(flow_node, :handle_fatal, [entry])
  end)
end
```

---

## P21: Child PIs spawned by Call Activities must not survive parent termination

**Mistake:** A Call Activity starts a child PI under `EvilEngine.Execution.Supervisor` (DynamicSupervisor), not under the parent PI's Task.Supervisor. When the parent PI terminates (fatal or aborted), its Task.Supervisor is stopped — killing the handler Task — but the child PI keeps running independently. The child's `notify_pid` points to the (now dead) handler Task; any `send(notify_pid, ...)` calls are silently dropped. Result: orphan child PIs remain alive and in the database as "running" after the parent has terminated.

**Why it happens:** Child PIs are OTP processes supervised by the shared DynamicSupervisor, not linked to the parent PI's process tree. There is no `:DOWN` monitor between the parent PI and the child PI (only between the handler Task and the child). When the parent goes terminal, the handler Task is killed, severing the only link to the child.

**Correct approach:** Use handler-driven cascade via the optional `handle_fatal/1` and `handle_aborted/1` callbacks on `FlowNodeHandler`. The `CallActivity` handler implements both callbacks to cascade the matching terminal state to the child PI:

- `handle_fatal/1` → calls `ProcessInstance.force_fatal(child_pid, %{reason: "parent_fatal"})`
- `handle_aborted/1` → calls `ProcessInstance.abort(child_pid, "parent_aborted", nil)`

ProcessInstance's `fatal_all_fnis` and `abort_all_fnis` invoke these callbacks after persisting each FNI's terminal state. The cascade is recursive: if the child PI has its own Call Activities, `fatal_all_fnis`/`abort_all_fnis` on the child will cascade further to grandchildren.

Key invariants:
- Already-finished child PIs are never retroactively changed (the child is looked up in the Registry; if not found, the callback returns `:ok`)
- The `catch :exit` guard in `cascade_to_child/2` handles the race condition where the child dies between Registry lookup and the call
- `interrupted` FNIs (boundary events) trigger `handle_aborted/1` because `interrupted` is an FNI-only state — the child PI should be `aborted`, not `interrupted`

---

## P22: Crash between PI termination and cascade completion can leave orphans

**Mistake:** If the engine crashes (SIGKILL, OOM, hardware fault) between persisting a PI's terminal state and completing `fatal_all_fnis`/`abort_all_fnis`, stale DB rows survive: FNIs stuck in `active`/`waiting` on a terminal PI, or child PIs still `running` while their parent is already terminal. These orphans would be invisible to the resume logic (which only loads root-level running PIs) and would never be cleaned up.

**Why it happens:** `persist_pi_fatal` / `persist_pi_aborted` runs first (persists the PI's terminal state), then `fatal_all_fnis` / `abort_all_fnis` iterates through each FNI to persist its terminal state and invoke handler callbacks. If the gen_statem dies between these two steps, the PI is terminal in DB but some FNIs and child PIs are still non-terminal.

**Correct approach:** `ResumeRunner.resume_all/0` runs a startup orphan cleanup sweep **before** the paginated resume loop. Two persistence adapter callbacks handle the cleanup:

1. `cleanup_orphaned_flow_node_instances/0` — bulk-aborts all FNIs in non-terminal state on terminal PIs
2. `cleanup_orphaned_process_instances/0` — iteratively aborts child PIs whose parent is terminal, including their FNIs, until no more orphans exist (handles nested orphans)

Both sweeps write an `error_info` JSONB map on affected rows for audit trail purposes. Cleanup errors are logged but do not prevent resume from proceeding.

This eliminates the "crash edge case" burden from retry logic — retry can assume all orphans were cleaned up at engine startup.

---

## P23: Signals are not messages

**Mistake:** Applying message correlation, catch-wins-over-start gating, or pending-message fan-out semantics to signals.

**Why it happens:** Signal and message infrastructure share a similar architectural shape (publisher → subscriptions → pending → start handler). Developers may assume both subsystems follow the same delivery rules.

**Correct approach:**

- Signals match on `signal_name` only — no correlation keys, no correlation values
- REST/facade signal trigger silently ignores any `payload` in the request body
- `SignalPublisher` always runs catch/boundary delivery **and** Signal Start Event firing in parallel (true broadcast); messages gate start events behind zero-delivery
- `pending_signals` uses **FIFO single-claim** drain (first subscriber to register claims the pending row; subsequent subscribers receive only live broadcasts). Messages use the same FIFO drain for pending rows
- Signal handlers use `evil:inputMapping`/`evil:outputMapping` for token transformation. Signals carry no inbound payload, so catch-side output mapping transforms the **existing** token.

See [`routing.md`](./routing.md) §3.5.6.

---

## P24: XOR join does not absorb duplicate merge tokens

**Current state:** The exclusive gateway join simply passes through every arriving token. If a parallel-like token fan-out reaches an XOR join, duplicate tokens are forwarded downstream.

**Why it exists:** XOR splits always produce exactly one outgoing token (condition evaluation), so a correctly modeled diagram never sends duplicate tokens into an XOR join. The issue only manifests when parallel/inclusive splits (Phase 4) feed into an XOR join — an invalid modelling pattern that is the modeling Users responsibility to fix.

---

## P25: Link throw searches entire process scope

**Current state:** When a Link Throw Event fires, the engine searches for a matching Link Catch Event across the entire process scope — all flow nodes in the same `<bpmn:process>`.

**Why it exists:** Without embedded sub-processes (Phase 4 item 1), the entire process is a single flat scope. The search is correct for flat processes.

**Phase 4 fix:** Phase 4 item 1 (embedded sub-processes) will introduce scope-aware link resolution. Link Throw will first search within the innermost sub-process scope, then walk up to parent scopes if no match is found.

---

## P26: `engine:events` join stays open; visibility is enforced at dispatch

**Mistake:** Treating an open `engine:events` join as "this subscriber may see every PI and FNI event", or adding a join-time claim gate such as `monitor` / `engine:events`.

**Why it happens:** The topic is joinable with any valid JWT (same as `/stats`). Early drafts of Phase 4/6 speculated about a join gate. P26 originally recorded that gap as unfixed.

**Current approach:** Join stays open. `EventDelivery.should_deliver?/2` filters each envelope after PubSub:

- Engine-level events (`Engine*`, definition lifecycle, `MessagePublished`, `SignalPublished`) are always delivered.
- PI-level events (`ProcessInstanceStateChanged`, `ProcessInstanceRetried`) are delivered on `engine:events` only when §5.1 holds from emit-time stamps (`startedById`, `hasLanelessFlowNode`, `laneNames`).
- FNI-originating events (explicit allow-list) are delivered when `laneName` is `nil` or the subscriber holds `lane:<name>` as `"read"` or `"write"`.
- Unknown envelope types are dropped. Do not treat a missing `laneName` on an unclassified type as "always deliver".
- `zeeky_boogie_doog` bypasses the filter (write-capable admin). `observe_all` is a **separate** unbounded-read assign — it delivers every envelope but never implies write.

`process:<model_id>` is still deferred. There is no `PiFinished` event.

---

## P67: WebSocket FNI dispatch is lane-gated; GraphQL FNI reads are not

**Mistake:** Assuming that hiding an FNI from a WebSocket subscriber also hides it from GraphQL (`flowNodeInstances` on a visible PI), or tightening GraphQL FNI reads to match the WS lane gate.

**Why it happens:** Both surfaces talk about lanes and §5.1 PI visibility. It is easy to treat them as one authorization model.

**Correct approach:** Keep the split:

| Surface | PI visibility | FNI visibility |
|---|---|---|
| GraphQL reads | §5.1 (starter, laneless FNI, any matching `"read"`/`"write"` lane, zeeky, `observe_all`) | If you see the PI, you see **all** of its FNIs (§5.2) |
| WebSocket FNI dispatch | Join of `process_instance:*` uses §5.1 (`read`/`write`/`observe_all`/zeeky); `engine:events` uses the same stamps at dispatch | Each FNI-originating event is delivered when `laneName` is `nil`, in `accessible_lanes` (`read` or `write`), or the subscriber has `observe_all` / zeeky |

A starter without `lane:Management` can query the Management User Task via GraphQL and still receive PI-level WS events, but will not receive live `FlowNodeInstanceStarted` / `UserTaskCreated` for that task unless they hold `"read"` or `"write"` on Management (or `observe_all` / zeeky). GraphQL FNI reads stay §5.2 (all FNIs on a visible PI). `"read"` **does** deliver Management FNI events on WebSocket.

---

## P27: Persistence adapter calls must use `PersistenceRetry.with_retry/3` — never call the adapter directly

**Mistake:** Calling `adapter.create_process_instance(attrs)` or any other adapter callback directly from PI or FniLifecycle code, bypassing the retry wrapper.

**Why it happens:** The adapter call is a simple function invocation. Without an established pattern, new code naturally calls the adapter directly — especially when copy-pasting from older code written before persistence resilience was standardized.

**Correct approach:** Always wrap adapter calls with `PersistenceRetry.with_retry/3`:

```elixir
# Wrong — no retry, single failure = permanent data loss
adapter.create_process_instance(attrs)

# Correct — bounded retry with exponential backoff
PersistenceRetry.with_retry(
  fn -> adapter.create_process_instance(attrs) end,
  "create_pi[#{attrs.id}]"
)
```

The `label` argument is a human-readable string used in log messages. Include enough context to identify the operation (PI ID, FNI ID, etc.).

After retry exhaustion, the caller decides the policy: fail-fast (critical creation and mid-flight writes) or log-and-continue (PI terminal transitions). See the ImplementationPlan and the Persistence Resilience section in `execution.md` for the full classification.

**Coverage:** As of the DB pool hardening work, `PersistenceRetry` wraps:

- **PI/FNI lifecycle** — all `create_*`, `update_*` adapter calls in `FniLifecycle` and `ProcessInstance`
- **Boundary orchestration** — `update_flow_node_instance` in `BoundaryOrchestrator`
- **Resume** — `list_running_process_instances`, `list_flow_node_instances`, `cleanup_orphaned_*` in `ResumeRunner`
- **Retry orchestration** — `get_process_instance_for_retry`, `list_all_flow_node_instances`, `execute_retry_reset`, `revert_retry` in `Execution`
- **Message persistence** — all functions in `MessagePersistenceAdapter` (insert, find, mark, expire, update, append)
- **Signal persistence** — all functions in `SignalPersistenceAdapter` (insert, find, mark, expire, update, append)

## P28: Use offset pagination (`limit`/`offset`) — keyset pagination lacks `hasNextPage`

**Mistake:** Using keyset (cursor) pagination for table-based UIs that need page jumping, page size changes, or First/Last navigation.

**Why it happens:** Keyset pagination is efficient for infinite-scroll scenarios but AshGraphql's keyset page types only expose `results`, `count`, `startKeyset`, and `endKeyset` — no `hasNextPage`, `hasPreviousPage`, `pageNumber`, or `lastPage` fields. This forces client-side computation and prevents direct page jumps.

**Correct approach:** All Ash resources use `paginate_with: :offset` in their `graphql` list queries. Offset pagination exposes the full `PageOf*` type with server-provided metadata:

- `count` — total matching rows
- `hasNextPage` / `hasPreviousPage` — boolean flags
- `pageNumber` — 1-based current page
- `lastPage` — total number of pages
- `limit` — page size applied

Query with `limit` and `offset` arguments:

```graphql
query {
  processInstances(limit: 25, offset: 50) {
    results { id }
    count
    hasNextPage
    hasPreviousPage
    pageNumber
    lastPage
  }
}
```

**Critical:** When using offset pagination, do NOT also enable `keyset? true` in the action's pagination config. Having both enabled causes Ash's internal page-type routing to become ambiguous — the `more?` field on `Ash.Page.Offset` may be `nil` instead of a boolean, which triggers `Cannot return null for non-nullable field` errors on `hasNextPage` in GraphQL.

**Keyset fallback:** If keyset pagination is ever needed (e.g., for streaming cursors), compute `hasNextPage` client-side as `results.length < count`. The keyset page type does not provide boolean navigation flags.

**Naming:** The Absinthe `LanguageConventions` adapter (default) returns all field names in camelCase.

---

## P29: Error messages must be diagnostic

**Mistake:** Putting raw Elixir internals into user-facing `message` fields — `inspect(reason)`, `Exception.message/1`, bare atom names like `"in_mapping_failed"`, or generic fallbacks like `"An unexpected error occurred"` without naming the element or construct that failed.

**Why it happens:** Handlers return `{:error, atom}` or `{:error, atom, detail}` tuples for convenience. Outer layers sometimes stringify those values directly instead of routing through the humanization layer. Developers debugging locally use `inspect/1` and copy the pattern into production paths. Atom-to-words fallbacks in `humanize_error/1` produce title-cased atom names (`"In mapping failed"`) that look like sentences but carry no diagnostic context.

**Correct approach:** Use a three-layer pattern — rich inner errors, canonical humanization, last-mile sanitization:

1. **Inner layers** (BPMN parser, flow-node handlers, FEEL evaluator) must return error tuples that carry element context: flow node ID and name, element type, expression text, implementation name, contract violation paths, and so on. Never pass `inspect/1` output or `Exception.message/1` up the stack as the user-facing message.

2. **Canonical mapping** — `EvilEngine.Execution.ProcessInstance.Helpers.build_error_info/1` in `apps/core_execution/lib/evil_engine/execution/process_instance/helpers.ex` normalizes every error shape into `%{"error_code" => ..., "message" => ..., "detail" => ...}`. Message construction always delegates to the private `humanize_error/1` function in the same module. Every new error shape introduced by a handler **must** get an explicit `humanize_error/1` clause that produces a complete English sentence naming the specific element and explaining why it failed.

3. **Event emission** — `EvilEngine.Execution.FniLifecycle` in `apps/core_execution/lib/evil_engine/execution/fni_lifecycle.ex` calls `normalize_error_info/1` (which delegates to `build_error_info/1`) before persisting, then passes the result through `sanitize_error_info/1` immediately before publishing `FlowNodeInstanceFinished`. The sanitizer is a **last-mile safety net** only: if it fires (it detects Elixir-internal patterns like `%{`, `#PID<`, `FunctionClauseError`), it logs a warning and replaces the message with a generic placeholder. When the sanitizer fires, fix the missing `humanize_error/1` clause at the source — do not rely on the sanitizer as the primary humanization path.

4. **REST controllers** — API layers such as `EvilEngineWeb.Http.ProcessController` in `apps/api_web/lib/evil_engine_web/http/controllers/process_controller.ex` format errors into complete sentences at the controller boundary (e.g. `default_start_error_message/1`, `payload_too_large_message/1`). Controllers must never expose `inspect/1` output or raw atom names in the `message` field of REST error responses.

```elixir
# Wrong — atom name or inspect output reaches the client
%{"error_code" => "in_mapping_failed", "message" => "in_mapping_failed"}
%{"error_code" => "error", "message" => "%{reason: :feel_eval_failed, ...}"}

# Correct — explicit humanize_error/1 clause produces a diagnostic sentence
%{
  "error_code" => "in_mapping_failed",
  "message" =>
    "Input mapping failed: FEEL expression 'token.x' could not be evaluated — unknown variable 'x'",
  "detail" => %{"expression" => "token.x", "reason" => "unknown variable 'x'"}
}
```

When adding a new handler error path, add the `humanize_error/1` clause first, then add a test that asserts the `message` contains the element ID or expression text — not just that `error_code` is set.

---

## P30: `root_process_instance_id` — root PIs use self, children inherit

**Mistake:** Treating `root_process_instance_id` as `nil` for root-level PIs, omitting it when spawning child PIs in new handlers, or assuming `parent_process_instance_id` alone identifies the top-level PI for WebSocket subscriptions.

**Why it happens:** The field is typed `String.t() | nil` on event structs and PI state, which suggests optionality. Child-spawn events (`CallActivityChildStarted`, `SubProcessChildStarted`) carry `parent_process_instance_id` but not `root_process_instance_id`, which can confuse consumers about which channel to join.

**Correct approach:** At PI creation, always set `root_process_instance_id` to `opts[:root_process_instance_id] || opts.process_instance_id`. For root PIs, root equals self — never leave it unset expecting `nil` to mean "this is the root". Call Activity and SubProcess handlers pass `context.root_process_instance_id` in child `start_opts` so the chain propagates at any nesting depth.

WebSocket clients that need a unified debugger view should subscribe to `process_instance:<rootProcessInstanceId>`. The WebSocket sink fans out events where `root_process_instance_id != process_instance_id` to both channels; when root equals self, only one targeted broadcast occurs.

```elixir
# Root PI init — root equals self
root_process_instance_id: opts[:root_process_instance_id] || opts.process_instance_id

# Child PI spawn — inherit from handler context
start_opts = [
  root_process_instance_id: context.root_process_instance_id,
  parent_process_instance_id: context.process_instance_id,
  ...
]
```

---

## P31: SubProcess vs Event SubProcess confusion

**Mistake:** Expecting embedded-subprocess semantics (token arrives via an incoming sequence flow) from an Event SubProcess container, or attaching a sequence flow to the ESP shell.

**Why it happens:** BPMN 2.0 defines two subprocess flavours with the same XML element name. The parser stores the distinction on `FlowNodeData.SubProcess.triggered_by_event`. Both are executed, but through entirely different entry paths.

**Correct approach:**

| Variant | XML | Engine behaviour |
|---------|-----|------------------|
| Embedded SubProcess | `<bpmn:subProcess>` (default) | Executes when a token arrives on an incoming sequence flow; spawns a child PI via `FlowNodes.SubProcess` |
| Event SubProcess | `<bpmn:subProcess triggeredByEvent="true">` | **Never token-entered** — has no sequence flows. The scope PI's trigger machinery creates the shell FNI and dispatches it through `FlowNodes.EventSubprocess` when the ESP's typed start event fires (see [execution.md](execution.md) §Event Subprocess Handler and [routing.md](routing.md) §3.5.8) |

`FlowNodes.SubProcess.guard_event_subprocess/1` still returns `{:error, :event_subprocess_not_supported}` — but only as a **defensive** guard on the token-entry path, which an ESP can never legitimately reach. It does **not** mean ESPs are unsupported. Event Subprocesses undergo recursive deploy-time inner validation (like embedded subprocesses) plus ESP-specific start-event rules (`validate_event_subprocess_structure`).

---

## P32: SubProcess synthetic model is not a separate deployment

**Mistake:** Assuming the subprocess inner scope is deployed or cached as its own process definition, or that `ModelCache` holds a persistent entry keyed by `{process_version_id, subprocess_node_id}` separate from the parent.

**Why it happens:** Child PIs reuse the parent's `process_version_id` and resolve their `%Process{}` through `ModelCache.fetch_subprocess_model/2`, which returns a synthetic process with ID `"#{parent_process_id}__subprocess__#{subprocess_node_id}"`. This looks like a standalone model but is materialized on demand.

**Correct approach:** `fetch_subprocess_model/2` loads the parent's cached `%Definitions{}` (ETS key = `process_version_id`), locates the subprocess node by ID, and builds the synthetic `%Process{}` in memory. On resume, `SubProcess.handle_resume/4` triggers the same resolution path — nothing is written to a separate ModelCache slot. Duplicate subprocess IDs within the same process are prevented by BPMN ID uniqueness enforced at parse/validate time; a duplicate ID would make subprocess lookup ambiguous.

```elixir
# Child PI start opts — same version as parent, subprocess_node_id selects inner scope
start_opts = %{
  process_version_id: context.process_version_id,
  subprocess_node_id: flow_node.id,
  parent_process_instance_id: context.process_instance_id,
  ...
}
```

---

## P33: Claim and lane checks belong in `EvilEngine.Api`, not controllers

**Mistake:** Enforcing JWT claims (`deploy_bpmn`, `abort_process_instance`, `trigger_message`, etc.) or lane access in REST controllers via `Identity.claims` lookups, then calling Core or publishers directly.

**Why it happens:** Controllers are the first code path hit on an HTTP request, so it feels natural to gate there. Plugin facade closures and future wire adapters would then duplicate or diverge from REST enforcement.

**Correct approach:** REST controllers parse HTTP, call `EvilEngine.Api.*`, and map error tuples to status codes only. All claim checks go through `EvilEngine.Api.Validation` inside the facade. Plugins pass `skip_claims: true` on facade calls; REST never does. See [api.md](./api.md) §10.8 and [authorization.md](./authorization.md) §13.

```elixir
# BAD — claim check in controller
def deploy(conn, params) do
  unless Map.get(identity.claims, "deploy_bpmn"), do: ...
  Ash.create(...)
end

# GOOD — thin controller
def deploy(conn, params) do
  case Api.persist_deploy_batch(sources, identity) do
    {:error, :forbidden, details} -> render_error(conn, 403, ...)
    ...
  end
end
```

---

## P34: `validate_timer_event_type` requires position AND `event_type`

**Mistake:** Validating manual timer trigger eligibility by checking `flow_node_type` alone (e.g. any `intermediate_catch_event`) without also requiring `event_type == "timer"`.

**Why it happens:** Timer FNIs share the same `flow_node_type` strings as message or signal catch events on Intermediate Catch and Boundary positions. A message catch FNI has `flow_node_type: "intermediate_catch_event"` but `event_type: "message"`.

**Correct approach:** The private `validate_timer_event_type/1` in `apps/api_facade/lib/evil_engine/api.ex` matches **both** fields:

```elixir
defp validate_timer_event_type(%{flow_node_type: type, event_type: "timer"})
     when type in ["intermediate_catch_event", "boundary_event"],
     do: :ok

defp validate_timer_event_type(_), do: {:error, :not_a_timer_event}
```

Timer Start Events are not manually triggerable through this path — they are managed by `StartEventManager`, not PI-scoped handler Tasks.

---

### P17 — Dual-repo Sandbox isolation

**Symptom:** Tests using `Ecto.Adapters.SQL.Sandbox` see empty reads after writes when dual-repo routing (via `RepoRouter`) is active. Data written through `Repo` is invisible to `ReadRepo` within the same test.

**Root cause:** `SQL.Sandbox` wraps each repo in a separate database transaction. With `{:shared, self()}` mode, all processes share one transaction per repo. But `Repo` and `ReadRepo` are separate repos with separate transactions, so writes in `Repo`'s transaction are not visible to `ReadRepo`'s transaction (PostgreSQL MVCC).

**Correct approach:** `RepoRouter` uses a compile-time module attribute (`@read_repo`) that resolves to `Repo` in `MIX_ENV=test`, bypassing `ReadRepo` entirely. All test operations go through the single `Repo` pool, preserving Sandbox isolation. In `:dev` and `:prod`, the router correctly splits reads to `ReadRepo`.

---

### P18 — error_info schema consistency

**Symptom:** Client-side error display shows empty or incomplete error information (e.g., an empty `additionalInformation` object) because the expected fields don't exist on the persisted `error_info` map.

**Root cause:** Different code paths (FNI fatal, PI fatal, orphan cleanup, boundary errors) each constructed `error_info` with different key names and structures. Some used `reason` (atom or list), others used nested maps, and others used `error_code` + `error_message`. Clients had to guess which keys existed.

**Correct approach:** All `error_info` maps follow a single schema: `%{"error_code" => string, "message" => string, "detail" => term | nil}`. The `Helpers.build_error_info/1` function in `core_execution` normalizes any error reason into this shape. Raw SQL (e.g., orphan cleanup) must also use `error_code`/`message` keys, not `reason`. Tests should assert on `error_info["error_code"]`, never `error_info["reason"]`.

### P19 — FniLifecycle event emission must be gated on persistence success

**Symptom:** A WebSocket consumer (e.g., the Studio debugger) sees a `FlowNodeInstanceFinished` event claiming an FNI transitioned to `fatal`, but a subsequent GraphQL query shows the FNI still in its previous state.

**Root cause:** `FniLifecycle.transition_to_fatal/5` (and `_aborted`, `_interrupted`) used to call `emit_fni_finished` unconditionally — between the persistence attempt and the result check. If persistence failed, the event was already emitted, representing a state transition that never happened in the database.

**Correct approach:** Always emit `FlowNodeInstanceFinished` inside the `:ok` branch of the persistence result match. The happy-path `persist_and_emit_finish/6` already did this correctly; the exceptional paths were aligned to match. This ensures every engine event truthfully reflects persisted state.

### P20 — BPMN error vs handler error: different return tags, different states

**Symptom:** Confusing an Error End Event's `{:bpmn_error, error_info, result}` with a handler's `{:error, reason}` leads to wrong PI/FNI terminal states.

**Root cause:** The engine has two fundamentally different error semantics: `{:bpmn_error, ...}` is a *modeled* BPMN outcome (the diagram author intentionally placed an Error End Event), while `{:error, ...}` is an *engine failure* (handler crash, persistence failure, unsupported element). The two share the word "error" but have entirely different state machines.

**Correct approach:** `{:bpmn_error, error_info, result}` → FNI state `:error`, PI state `:error`, parent receives `{:child_pi_bpmn_error, ...}` for boundary matching. `{:error, reason}` → FNI state `:fatal`, PI state `:fatal`. Never use `{:bpmn_error, ...}` for engine failures, and never use `{:error, ...}` for intentional BPMN error propagation.

### P21 — FNI `:error` state is exclusively for Error End Events

**Symptom:** Using `:error` as a terminal state for handler failures (instead of `:fatal`) breaks the debugger's visual contract: the debugger expects `:error` to mean "this element threw a modeled BPMN error", not "this element crashed".

**Root cause:** The FNI `:error` state was introduced specifically for Error End Events (EE-6). It provides the debugger with a visual distinction between three roles in an error scenario: `:error` = "threw the error", `:interrupted` = "collateral", `:finished` = "completed before the error".

**Correct approach:** Only `FniLifecycle.finish_as_error/4` (called exclusively by the `ErrorEndEvent` handler) should produce FNIs in `:error` state. All handler failures go through `transition_to_fatal/5` → `:fatal`. If a new handler needs to signal a modeled error, it should return `{:bpmn_error, ...}` and let the PI/FniLifecycle handle the state transition.

## P35: Retry at interrupted Event-Based Gateway sibling

**Mistake:** Allowing `retry_process_instance` with a checkpoint targeting an FNI that was cancelled by the Event-Based Gateway's first-wins logic.

**Why it happens:** After an EBG race, the losing catch FNIs are persisted as `:interrupted` (not `:aborted` — the `:aborted` state is reserved exclusively for user/API-initiated abort) with `type_properties.reason == "event_based_gateway_sibling_cancelled"`. They look like regular interrupted FNIs from the persistence layer's perspective, so without a guard, the retry mechanism might accept them as valid checkpoints and create a split execution. Additionally, `non_retryable_fni?/1` excludes these FNIs from being reset during a no-checkpoint retry.

**Correct approach:** `Execution.retry_process_instance/1` checks `ebg_loser_fni?/1` before accepting any checkpoint FNI. If the checkpoint targets an interrupted EBG sibling, the retry is rejected with `{:error, :retry_checkpoint_is_ebg_loser}` (HTTP 422, error code `retry_checkpoint_is_ebg_loser`). The guard accepts both `:aborted` and `:interrupted` states for backward compatibility with pre-existing DB rows. The user must retry at the gateway itself or at a node upstream of it. The Studio Debugger should filter these FNIs from the retry target picker.

## P36: Retry at parallel join gateway

**Mistake:** Attempting to set a retry checkpoint at a parallel or inclusive join gateway FNI.

**Why it happens:** Join gateway FNIs park with partial branch-arrival state (`join_arrivals` in memory plus `gateway_pending_arrivals` rows in the database). Resetting the join FNI as a checkpoint would leave ambiguous semantics — should all branches re-run, or only the missing ones? Without an explicit guard, the retry mechanism would accept the join FNI as a valid checkpoint and corrupt the arrival counter.

**Why it fails:** `Execution.apply_checkpoint/2` checks `join_gateway_fni?/2` before accepting any checkpoint FNI. Parallel and inclusive gateway FNIs match `flow_node_type in ["parallel_gateway", "inclusive_gateway"]` and are rejected with `{:error, :retry_checkpoint_is_join_gateway}` (HTTP 422, error code `retry_checkpoint_is_join_gateway`, message: `"Cannot retry at a parallel join gateway. Retry at the fork gateway or at a node upstream of it."`).

**Correct approach:** Retry at the fork gateway or at an upstream branch task instead. Retry at an upstream branch task is safe — preserved `gateway_pending_arrivals` rows let the join re-park with already-completed branches on resume. The Studio Debugger should filter join gateway FNIs from the retry target picker.

## P37: Orphan pending signals/messages delivered to unrelated process instances

**Mistake:** Assuming that if a signal publish delivered live to a waiting subscriber, no stale pending row can reach the *next* subscriber.

**Why it happens:** Before this fix, the publish pipeline only decided whether to create a *new* pending row based on the current publish's delivery count. It never cancelled *existing* pending rows from *previous* publishes. So if a REST trigger fired with no subscriber (creating pending row P1), a subsequent BPMN throw delivered to a waiting catch (correctly, `pending: false` for that publish), but P1 remained `state='pending'`. The next PI that registered a catch for the same signal/message drained P1 — receiving a stale signal/message from an earlier, already-completed publish.

**Correct approach:** Two mechanisms now prevent stale pending delivery:
1. **Orphan pending cancellation:** When a publish successfully delivers to live subscribers or triggers start events (`has_recipients == true`), the publisher calls `cancel_pending_for_signal_name/1` (or `cancel_pending_for_message/2`) to expire all existing `state='pending'` rows for that signal/message name. This ensures that a successful live delivery invalidates any leftover pending rows from earlier zero-match publishes.
2. **`skip_pending` for REST/API triggers:** REST controllers pass `skip_pending: true` to the publisher, so zero-match REST triggers never create pending rows in the first place. This is appropriate because REST triggers are a debugging tool — they should produce an immediate effect (or no effect), not cache a signal/message for future process instances.

## P38: Inclusive Join re-evaluation must run after every FNI state change

**Mistake:** Assuming the inclusive join will fire only when a token directly arrives at the join via an incoming sequence flow.

**Why it happens:** In an inclusive gateway with dead-path elimination, a branch may reach an End Event or transition to a terminal state (fatal, aborted, interrupted) without ever sending a token to the join. In this case, the join's upstream path becomes "dead" — no active or waiting FNI can deliver a token through that path. If the join only checks on token arrival, it will park forever, waiting for a token that will never come.

**Correct approach:** `evaluate_parked_inclusive_joins/1` is called in `maybe_finish_or_continue/1` after **every** FNI state change (not just on token arrival). This hook iterates all parked inclusive join entries in `join_arrivals` and re-runs `InclusiveJoinEvaluator.should_fire?/4` against the current `flow_node_instance_states`. When a branch ends at an End Event (removing its FNI from the active set), the re-evaluation detects that the join's upstream path is now dead and fires the join with the tokens that have already arrived. The same hook fires during resumption via `evaluate_parked_inclusive_joins_on_resume/1`.

## P39: Conditional waiter registration must include immediate evaluation

**Mistake:** Registering a conditional waiter in the PI's `conditional_waiters` map without immediately evaluating the condition, relying on the next `evaluate_conditional_waiters` call to trigger it.

**Why it happens:** A race condition exists between the handler returning `{:wait, ...}` and the waiter registration. The handler's `{:wait, %FlowNodeResult{metadata: %{awaiting_condition: true}}}` is delivered to the PI via `{:fni_result, ...}`. The PI processes it in `handle_fni_wait/3`, persists the FNI as `:waiting`, and registers the waiter. However, between the handler's initial evaluation (inside the Task) and the PI's waiter registration, another FNI may have completed and mutated the PI state (e.g., a parallel branch wrote a Data Object). The standard `evaluate_conditional_waiters` call in `maybe_finish_or_continue` runs only on *subsequent* FNI state changes, so it would not see the new waiter until the next mutation — which may not happen for a long time (or ever), leaving the conditional event stuck despite its condition being true.

**Correct approach:** `maybe_register_conditional_waiter_from_wait/3` calls `evaluate_single_conditional_waiter/3` immediately after inserting the waiter into the map. This ensures that even if the condition-triggering state change occurred during the `{:wait, ...}` round-trip, the waiter fires promptly.

## P40: Parallel gateway join deadlocks with interrupting conditional boundary events

**Mistake:** Placing an interrupting conditional boundary event on an activity inside a parallel branch that converges at a join gateway.

**Why it happens:** When the interrupting boundary fires, it cancels the host activity and routes execution along the boundary path. The parallel join gateway waits for tokens from all incoming branches. The interrupted branch never delivers its token to the join, causing the join to park indefinitely (parallel joins do not have dead-path elimination — that is inclusive gateway territory).

**Correct approach:** When using interrupting boundary events (conditional, timer, message, signal) on activities in parallel branches, either (a) use an inclusive gateway join instead of a parallel gateway join (which has dead-path elimination), or (b) route each parallel branch to its own End Event (no join), or (c) ensure the boundary event's outgoing path also reaches the join gateway.

## P41: Conditional event conditions do not cross PI scope boundaries

**Mistake:** Expecting a conditional event in a parent process to fire when a state change occurs inside an Embedded Subprocess or Call Activity child, or vice versa.

**Why it happens:** Each PI (parent, child subprocess, Call Activity child) is a separate GenServer with its own `conditional_waiters` map and `data_object_cache`. The PI's `evaluate_conditional_waiters/1` only evaluates waiters registered in that PI against that PI's state. A Data Object write inside an Embedded Subprocess triggers re-evaluation of conditional waiters inside the subprocess's child PI only — the parent PI never sees the write. Similarly, a state change in the parent does not propagate to child PIs.

**Correct approach:** Design conditional event conditions to reference data visible within the conditional event's own process scope. If cross-scope signaling is needed, use Message Events (publish from child, catch in parent) or Signal Events (broadcast) instead of conditional events. See `docs/guides/handbook/conditional-events.md` §Scope Rules.

## P42: `:aborted` state reserved exclusively for user/API-initiated abort

**Mistake:** Using `FniLifecycle.transition_to_aborted` for flow-driven cancellation (boundary events cancelled by host completion, EBG losers, terminate/error end event collateral).

**Why it happens:** Before this fix, `BoundaryOrchestrator` and `EventBasedGatewayOrchestrator` used `transition_to_aborted` for all cancellation paths, conflating user-initiated abort with BPMN flow mechanics. This caused the retry mechanism to treat flow-interrupted FNIs as retryable (same state as user-aborted FNIs), creating invalid execution paths after retry.

**Correct approach:** Only two call sites may use `transition_to_aborted`: `handle_fni_aborted/3` (user cancel via API) and `abort_all_fnis/1` (PI abort cascade). All other cancellation — host completion, sibling boundary interruption, EBG loser cancellation, Terminate End Event collateral, Error End Event collateral — must use `transition_to_interrupted`. The `handle_aborted/1` callback name is a resource-cleanup hook (not a state declaration) and remains correct to call from interrupted paths.

## P43: Join gateway duplicate FNI after retry

**Mistake:** Deleting join gateway FNIs during retry. This loses the audit trail (previous FNI IDs) and breaks Inclusive Join Gateway dead-path auto-completion, causing deadlocks.

**Why it happens (historical):** An earlier fix deleted join gateway FNIs during retry to prevent duplicate FNI creation. The deletion was an over-correction: the real root cause was that `join_routing` was empty on resume because the old FNI (in terminal state) had no GPAs, so `dispatch_join_first_token` created a new FNI.

**Correct approach:** Join gateway FNIs are **reset to `active`** (never deleted). For full retry, their GPAs are cleared via `clear_gpa_fni_ids` in the reset spec. `Resumption.ensure_active_join_gateways_routed/2` detects active join FNIs with no GPAs and creates routing entries, so subsequent token arrivals route to the existing handler. For checkpoint retry, GPAs are preserved to maintain partial-join state from already-completed branches.

## P44: Complex Gateway `activationCondition` is required for JOINs only — never for splits

**Mistake:** Requiring `<bpmn:activationCondition>` on **every** Complex Gateway in the generic per-node validator (`validate_type_data/6`). This wrongly rejects valid Complex **Splits**, which have no activation condition — they route on outgoing `conditionExpression`s instead.

**Why it happens:** `validate_type_data/6` only sees a single `%FlowNode{}` in isolation. It cannot tell whether a Complex Gateway is a split or a join, because that distinction depends on the **incoming / outgoing sequence-flow counts**, which live on the process, not the node. An unconditional "always require activationCondition" rule there fails the split fixtures at deploy time with `"ComplexGateway '...' is missing required properties: activationCondition"`.

**Correct approach:** Enforce the activation-condition requirement in `check_complex_gateways/1` (called from `validate_process/2`), which has the process's `sequence_flows` and can classify each Complex Gateway by flow counts:

- `> 1` incoming **and** `> 1` outgoing → `complex_gateway_mixed`.
- `> 1` outgoing (split) → **no** activationCondition check. Unconditional non-default outgoing flows are a **runtime** fatal `:complex_gateway_unconditional_flow` (not a deploy violation); Studio lints them.
- `> 1` incoming (join) → non-blank `<bpmn:activationCondition>` required (`complex_gateway_join_missing_activation_condition`).

The generic `validate_type_data/6` clause for `%FlowNodeData.ComplexGateway{}` must therefore return `[]` and delegate entirely to the flow-count-aware check.

## P45: Complex Join scoped cancellation needs a well-formed SESE region — and the region excludes the split and join

**Mistake:** Assuming a Complex Join can cancel "the other branches" without a strictly-bounded region, or that the region includes the paired split/join nodes. Both lead to wrong cancellation scope.

**Why it happens:** Twist 2 cancellation (`interrupt_region_fnis/3`) interrupts every `:active`/`:waiting` FNI whose `flow_node_id` is in the join's `region_node_ids`. If the region is not single-entry/single-exit, "the branches between split and join" is ambiguous — a flow leaking out of the region would either be missed (leaving orphans) or, worse, cancellation would need to chase tokens outside the intended block. And if the region set mistakenly included the split `S` or the join `J` themselves, the firing join could try to interrupt itself or re-open the entry.

**Correct approach:**

- Pair each join to `S = idom_complex(J)` (nearest dominating Complex Split) and compute `region_node_ids = forward_reachable(S) ∩ backward_reachable(J) \ {S, J}` in `ComplexRegionAnalysis`. The region **excludes** both boundary nodes.
- Enforce well-formedness **at deploy** (`region_violations/1`): reject unpaired joins (`complex_join_no_paired_split`), cross-boundary edges (`complex_region_cross_boundary`), and partially overlapping regions (`complex_region_overlap`). Valid regions therefore form a **laminar family** — any two are disjoint or strictly nested, so a partial overlap can only arise together with a cross-boundary or pairing violation and is caught first.
- `interrupt_region_fnis/3` must explicitly skip the join FNI (`id != join_fni_id`) and must be **scoped** — it runs each interrupted FNI's `handle_aborted/1` for local cleanup but does **not** purge the whole PI's message/signal subscriptions (contrast `interrupt_remaining_fnis/2`, used by Terminate/Error End Events).
- When testing cancellation in the shared-connection Ecto sandbox, drive the join with branches that are **idle-waiting** (e.g. user tasks completed explicitly) before the fire. Killing an FNI that is mid-DB-write on the single shared test connection can tear the connection down and surface as a spurious `DBConnection.OwnershipError` — a test artifact, not an engine bug (in production each process has its own pooled connection).

---

## P46: Inner subprocess Start Events are never externally startable — `subprocess_node_id` requires a parent

**Mistake:** Assuming a REST/plugin caller (or a `calledElement` / `evil:startEventId` on a Call Activity) could target a Start Event nested inside an embedded / event / (future) transactional subprocess by passing its ID, its synthetic model ID (`parentId__subprocess__nodeId`), or a `subprocess_node_id` option — or relying only on data-scoping to keep inner starts invisible.

**Why it happens:** Inner start events live under `type_data.flow_nodes`, so they are *incidentally* invisible to top-level start-event resolution, Message/Signal Start indexing, and the `calledElement` catalog. That protection is real but implicit — a future model/index refactor that recursed into nested scopes, or a caller that forged `subprocess_node_id`, could silently break isolation. `subprocess_node_id` selects the synthetic inner-scope model, and it must only ever be set by the owning subprocess element's internal child spawn (which always carries a `parent_process_instance_id`).

**Correct approach:**

- **Core chokepoint is authoritative.** `Execution.start_process_instance/1` rejects any call where `subprocess_node_id` is present but `parent_process_instance_id` is nil with `{:error, :orphan_subprocess_start}`. Every entry point (REST, plugin, Call Activity, SubProcess, ESP) flows through this single guard.
- **Public surface omits internal keys structurally.** The `ProcessController` private `do_start` helper builds `start_opts` from only the public request fields plus server-derived `identity`/`process_instance_id`. Do **not** re-introduce `subprocess_node_id` (or `parent_process_instance_id: nil`) into the public start contract; extraneous body params are ignored, not accepted.
- **Keep resolution scoped.** `ProcessInstance.resolve_start_event/2` resolves strictly against `process_model.flow_nodes`. Never broaden this to recurse into `type_data.flow_nodes`.
- **Enforce global ID uniqueness at deploy.** `BPMN.Validator` reports `duplicate_flow_node_id` when a flow-node ID collides across the process and any nested subprocess scope, keeping start-event resolution and subprocess scoping unambiguous.

See [security.md](security.md) §Subprocess Start-Event Isolation.

---

## P47: An interrupting Event Subprocess must NOT kill the scope PI — it reaches `:finished`

**Mistake:** Assuming that an interrupting Event Subprocess (ESP) firing terminates its enclosing scope Process Instance the way a Terminate/Error End Event ends a process, i.e. expecting the scope PI to end in `:aborted` or `:fatal` once the ESP interrupts the main flow.

**Why it happens:** "Interrupting" reads like "kill the scope." But an interrupting ESP only cancels the scope's *other* work; the scope itself continues so it can run the ESP body and complete normally.

**Correct approach:** The interrupting fire calls `interrupt_remaining_fnis` (reason `:interrupted_by_event_subprocess`), which iterates only FNIs **other than** the ESP shell FNI — it structurally cannot target the scope PI and does not stop it (the same primitive Terminate End Events use). When the ESP child completes, `maybe_finish/1` sees `active_count == 0` and the scope PI reaches `:finished`. Tests must assert the scope reaches `finished`, never `aborted`/`fatal`, merely because the ESP fired. Two interrupting triggers enqueued together are idempotent — the first dequeued wins, the second is a no-op (its siblings are already `:interrupted`).

---

## P48: Escalation/error proximity beats propagation, and a specific code beats catch-all — but only within one scope

**Mistake:** Ranking an ESP escalation/error start against a boundary event by specificity (assuming a specific-code catcher always wins), or forgetting that a scope-level ESP catches an escalation raised in that scope **before** it propagates to the parent.

**Why it happens:** The escalation/error catcher set spans two different structural levels — boundary events attach to an *activity*, ESP starts attach to a *scope*. Mixing them into one specificity contest gives wrong winners.

**Correct approach:** The law is **proximity first, specificity second** (ESP-D6). Proximity is enforced by the call sites in `ProcessInstance` (`handle_fni_bpmn_error/*`, `handle_fni_escalation_throw`): a boundary on the throwing activity is tested first, then the scope ESP start (`EventSubprocessResolver.find_matching_error_start/2` / `find_matching_escalation_start/2`), then outward propagation to the parent. Specificity (specific code beats catch-all `nil` code) is only a tiebreak **among peers in the same scope** — two ESP starts in one scope, resolved by `rank_by_specificity/3`. A boundary-vs-ESP contest is therefore never decided by specificity. A scope-level escalation ESP start always catches a matching escalation raised in that scope before the parent sees it.

---

## P49: Conditional Event Subprocess starts are edge-triggered (false→true), not level-triggered

**Mistake:** Expecting a conditional ESP start whose FEEL condition is already `true` (or stays `true`) to keep firing on every scope state change, or expecting it to fire immediately at scope activation when the condition is already satisfied.

**Why it happens:** A conditional trigger looks like a predicate that should hold continuously. But continuous firing would spawn an unbounded stream of ESP child PIs while the condition remains true.

**Correct approach:** Conditional ESP starts are **edge-triggered** — they fire on a `false → true` transition of the FEEL condition, re-evaluated on every scope FNI state change (the same conditional-waiter mechanism as Conditional Boundary/Catch events). A non-interrupting conditional ESP re-arms after each fire and will not fire again until the condition returns to `false` and then back to `true`. This prevents busy re-firing while the condition stays true. (Related: P39 — conditional waiter registration includes an immediate evaluation.)

---

## P50: An ESP Message Start is a gated Start Event — a Catch/Boundary always beats it (no fan-out delivery)

**Mistake:** Assuming an ESP Message Start receives the message as one of the broadcast-within-key deliveries alongside an inline Message Catch/Boundary, so both fire for the same `(name, correlation)`.

**Why it happens:** All three register in the same `MessageSubscriptions` registry, so it looks like they all participate in the delivery fan-out.

**Correct approach (ESP-D13 / ESP-D13b):** The ESP Message Start registers with the informational `:event_subprocess_start` kind but is **excluded from the delivery set**, and fires via `resolve_start_events` **only when `deliveries == []`** (the same gate as standalone starts, ordered *before* them). Precedence ladder: **inline Catch/Boundary → ESP Message Start → standalone Message Start**. A Catch/Boundary in the same PI always beats the ESP Message Start; an ESP Message Start beats a standalone Message Start (a running instance consumes the message before a new PI is created). Signals are different — an ESP Signal Start is broadcast-all with no catch-wins-over-Start gate (ESP-D13c). See [routing.md](routing.md) §3.5.8.

---

## P51: An Event Subprocess shell must have NO incoming/outgoing sequence flows

**Mistake:** Drawing a sequence flow into or out of a `<bpmn:subProcess triggeredByEvent="true">` shell (out of habit from embedded subprocesses), or expecting the ESP to be reachable by a token.

**Why it happens:** In a modeler an ESP looks like any other subprocess box, and embedded subprocesses *are* wired into the flow.

**Correct approach:** An ESP is **triggered**, never token-entered — it has no incoming and no outgoing sequence flows. The deploy-time validator rejects a shell that carries either with `:event_subprocess_has_sequence_flow` (`validate_event_subprocess_structure`). The ESP body runs as a child PI spawned by the scope PI's trigger machinery; its inner End Events terminate the child, they do not route a token back into the parent.

---

## P52: Flow-node IDs must be globally unique across the whole process tree — nested ESP scopes cannot reuse `Start_1`

**Mistake:** Reusing convenient IDs like `Start_1` / `End_1` inside an Event Subprocess (or a nested ESP-in-ESP) that already exist in the top-level process or another scope.

**Why it happens:** BPMN modelers often scope IDs mentally per subprocess, and an ESP inner scope *feels* like a separate namespace.

**Correct approach:** `BPMN.Validator.check_unique_flow_node_ids/1` recurses into **every** `SubProcess` scope — including `triggered_by_event: true` — via `collect_all_flow_node_ids/1`, and rejects any collision across the process and all nested subprocess scopes with `:duplicate_flow_node_id`. Suffix IDs per scope (e.g. `ESP_Msg_Start`, `Inner_ESP_Start`) so nested-ESP and ESP-in-ESP diagrams deploy. This uniqueness is what keeps start-event resolution and subprocess scoping unambiguous (see P46).

---

## P53: Compensation Boundary Events are not subscription boundaries

**Mistake:** Treating Compensation Boundary Events like timer/message/signal boundaries and expecting them to be pre-spawned alongside the host activity.

**Why it happens:** Compensation boundaries look structurally similar to other boundary events, but they have fundamentally different semantics. They are passive registration carriers — their sole purpose is to link a host activity to a compensation handler via a `<bpmn:association>`.

**Correct approach:** `BoundaryOrchestrator.resolve_subscription_boundaries/3` filters out `:compensation` event definitions. The compensation handler is dispatched only when a Compensate Throw/End Event fires and the PI's compensation registry contains an entry for the host activity. The `CompensationBoundaryEvent` handler module exists only as a safety guard — it returns `{:error, :compensation_boundary_not_dispatched}` if accidentally invoked.

---

## P54: FlowNodeResult metadata lifecycle may be nil

**Mistake:** Using `get_in(result.metadata, [:lifecycle, Access.key(:data_object_cache_updates, %{})])` when `result.metadata[:lifecycle]` might be `nil`.

**Why it happens:** Not all handlers populate `metadata.lifecycle`. Compensation handlers and other lightweight handlers return `metadata: %{}`. `Access.key/2` calls `Map.get/3` on the lifecycle value, which crashes with `BadMapError` when it's `nil`.

**Correct approach:** Use a safe extraction helper that checks for `nil` first:

```elixir
defp extract_cache_updates(metadata) do
  case metadata[:lifecycle] do
    nil -> %{}
    lifecycle -> Map.get(lifecycle, :data_object_cache_updates, %{})
  end
end
```

---

## P55: Compensation is NOT auto-triggered by fatal, error, escalation, or abort

**Mistake:** Expecting the engine to automatically run compensation handlers when a PI encounters a fatal error, an Error End Event fires, an escalation goes uncaught, or the PI is aborted via API.

**Why it happens:** In transactional systems (and in BPMN 2.0 Transaction SubProcesses with `<cancelEventDefinition>`), compensation is automatically triggered on transaction rollback. This creates the expectation that any failure path should automatically undo previous work. But the engine's compensation support is based on explicit throw/end events, not implicit transaction semantics.

**Correct approach:** Compensation requires explicit modeling by the diagram author. To compensate after an error, the typical BPMN pattern is:

1. Attach an Error Boundary Event to the failing activity (or scope)
2. Route the boundary's outgoing flow to a Compensate Intermediate Throw Event
3. The throw event dispatches compensation handlers in LIFO order
4. After handlers complete, the flow continues (or ends via a Compensate End Event)

Fatal PIs, aborted PIs, escalated PIs, and error PIs do **not** trigger compensation. The PI reaches its terminal state directly. Retry is the recovery mechanism for fatal/aborted/error PIs, not compensation.

---

## P56: `isForCompensation` tasks have no sequence flows — they are linked via association

**Mistake:** Expecting a compensation handler activity (`isForCompensation="true"`) to have incoming or outgoing sequence flows, or flagging it as an orphan node during validation.

**Why it happens:** Every other activity in BPMN must be connected to at least one sequence flow to be reachable. Compensation handlers look like normal tasks in the modeler and in the XML, so the validator's orphan-node check would reject them without a special exemption.

**Correct approach:** Activities with `isForCompensation="true"` are linked to their host activity via a `<bpmn:association>` that connects a Compensation Boundary Event (on the host) to the handler. The parser resolves the association at model-build time and stores `compensation_handler_id` on the boundary event's type data. The validator explicitly exempts `isForCompensation` activities from orphan-node checks (no sequence flows required) and from dead-end checks.

---

## P57: Subprocess handler `resolve_outgoing` is eager — always add a normal outgoing flow

**Mistake:** Modeling an embedded subprocess with only a boundary event (e.g. a timer or error boundary) and no outgoing sequence flow, expecting the boundary to be the only exit path.

**Why it happens:** The embedded subprocess handler calls `resolve_outgoing` during `handle_enter`, **before** starting the child PI. If the subprocess shell has no outgoing sequence flows and no default flow, `resolve_outgoing` returns `{:error, :dead_end}`, which fatals the subprocess FNI before the child PI ever starts — and before any boundary event has a chance to fire.

**Correct approach:** Always add a normal outgoing sequence flow from the subprocess shell, even if you expect the boundary to always fire. The outgoing flow serves as the "happy path" exit. The boundary event fires independently and interrupts the subprocess if needed. Without the outgoing flow, the subprocess never starts.

## P58: Do not duplicate child-PI lifecycle code — use `ChildLifecycle`

**Mistake:** Copying child-PI lifecycle logic (await, result processing, error/escalation handling, resume, cascade) from `SubProcess` or `CallActivity` into a new handler.

**Why it happens:** The child-PI lifecycle involves ~600 lines of interconnected logic (receive loop, token aggregation, output mappings, boundary resolution, escalation propagation, resume from persistence, fatal/abort cascade). It is tempting to copy from an existing handler when building a new subprocess-like handler (e.g. Transaction SubProcess).

**Correct approach:** Use `EvilEngine.Execution.FlowNodes.ChildLifecycle`. This module contains all shared child-PI lifecycle functions and is parameterized via options (`child_label`, `extra_terminal_states`, `extra_message_handler`, `fresh_lifecycle_fn`) to accommodate handler-specific differences. Both `SubProcess` and `CallActivity` already delegate to it. New handlers should do the same and add handler-specific concerns through the parameterization points.

---

## P59: Ad-hoc inner activities have no Start/End Events

**Mistake:** Modeling Start Events or End Events inside an `<bpmn:adHocSubProcess>`, or expecting the engine to resolve a start event for the ad-hoc child PI.

**Why it happens:** Ad-hoc subprocesses look like embedded subprocesses in the modeler, and embedded subprocesses require exactly one None Start Event. But ad-hoc subprocesses have fundamentally different semantics — their inner activities are not connected by sequence flows and are activated on demand.

**Correct approach:** The deploy-time validator rejects ad-hoc subprocesses that contain Start Events (`:adhoc_subprocess_has_start_event`) or End Events (`:adhoc_subprocess_has_end_event`). At runtime, `AdHocMode.resolve_initial_state/3` returns `{:ok, nil}` (no start event resolution), and `initial_dispatch/4` is a no-op — the handler manages activation directly. The child PI completes via completion signal or natural drain, not via End Event token consumption.

---

## P60: `cancelRemainingInstances=false` requires `Map.get`, not `||`

**Mistake:** Using `opts[:adhoc_cancel_remaining_instances] || true` when propagating `cancelRemainingInstances` from `start_opts` to PI state.

**Why it happens:** The `||` operator in Elixir treats `false` as falsy. When the BPMN model sets `cancelRemainingInstances="false"`, the option value is `false`, and `false || true` evaluates to `true` — silently overriding the intended behavior and always cancelling remaining instances.

**Correct approach:** Use `Map.get(opts, :adhoc_cancel_remaining_instances, true)`, which correctly distinguishes `false` (explicitly set) from absent (use default `true`):

```elixir
# Wrong — false || true == true, overriding the BPMN attribute
cancel_remaining = opts[:adhoc_cancel_remaining_instances] || true

# Correct — Map.get preserves explicit false
cancel_remaining = Map.get(opts, :adhoc_cancel_remaining_instances, true)
```

---

## P61: Ad-hoc completion condition vs natural drain

**Mistake:** Conflating `adhoc_completion_signaled` with `adhoc_natural_drain_enabled`, or expecting the ad-hoc child PI to complete without either flag being set.

**Why it happens:** Two distinct completion mechanisms exist for ad-hoc subprocesses, and they are easy to confuse because both cause the PI to finish when no active/waiting FNIs remain.

**Correct approach:** Both flags are checked in `AdHocMode.should_complete?/1`:

- `adhoc_completion_signaled` — set by an explicit REST/plugin call (`POST /adhoc-subprocesses/:id/complete`). User-triggered. Checked first.
- `adhoc_natural_drain_enabled` — set by engine-managed mode after dispatching all inner activities. Engine-triggered. The PI completes when all dispatched activities finish without manual intervention.

If neither flag is set, the PI never completes — it waits indefinitely for an activation or completion signal. This is the correct behavior for plugin-managed mode where the plugin decides when to activate activities and when to signal completion. Do not set `adhoc_natural_drain_enabled` in plugin-managed mode.

## P62: Nested subprocess start must flush the enclosing shell back onto `subprocess_stack`

**Mistake:** Mutating the enclosing subprocess shell through `state.current_node` in `SaxHandler` and assuming the mutation survives a nested subprocess.

**Why it happens:** `do_handle_start_subprocess/4` overwrites `state.current_node` with the newly opened shell. The enclosing shell's accumulated state lives only in `current_node` at that moment — `subprocess_stack` still holds the snapshot taken when that shell was *pushed*. `maybe_flush_subprocess_shell/1` is the only function that syncs `current_node` back onto the stack head, and it was originally called only from `do_handle_end_subprocess/1`. Any mutation applied between the enclosing shell's start tag and the nested shell's start tag was therefore silently discarded when the nested scope popped and restored the stale snapshot.

Concretely this dropped `<bpmn:incoming>` / `<bpmn:outgoing>` refs from any embedded subprocess, transaction, or ad-hoc subprocess whose flow refs are declared *before* a nested subprocess — a valid and common serialization order. At runtime the outer shell then had no outgoing flow and its token dead-ended.

**Correct approach:** `do_handle_start_subprocess/4` calls `maybe_flush_subprocess_shell/1` on entry, before building the nested node:

```elixir
defp do_handle_start_subprocess(element_name, type_data, attributes, state) do
  state = maybe_flush_subprocess_shell(state)
  node = %FlowNode{...}
```

Any new state that is accumulated on the shell node (not on the inner scope's `current_process`) is subject to the same hazard. Route such mutations through `current_node` and rely on the flush, or write directly to the `subprocess_stack` head as the `handle_end("incoming", %{current_node: nil, ...})` clause does.

## P63: A `ModelCache` cold-miss inside a GraphQL resolver triggers a full DB read + re-parse, not a cache lookup

**Mistake:** Assuming `ProcessVersion.processModel` / `FlowNodeInstance.flowNode` resolvers are always O(1) ETS reads because "GraphQL Model graph resolvers read `ModelCache`".

**Why it happens:** `ModelCache.fetch/1` only returns instantly on a **warm** entry (`:ets.lookup/2` hit). On a miss — most commonly after `ModelCache.delete/1` (explicit eviction, used by tests and possibly by future retention tooling) or a cold engine restart before the version is re-primed — `fetch/1` falls through to `GenServer.call(__MODULE__, {:load_and_cache, process_version_id})`, which invokes the configured `:model_cache_loader` (`{EvilEngine.Persistence.ExecutionAdapter, :load_bpmn_xml}` in production). That is a DB read of `bpmn_xml` followed by a full `EvilEngine.BPMN.Parser.parse/1` — the same cost as a fresh deploy, executed synchronously inside the GraphQL request.

**Correct approach:** The Model graph resolvers still return the correct result on a cold miss (`graphql_model_graph_wp7_test.exs` "cold-cache behaviour" pins this), so correctness is not at risk — but latency is. Do not assume a `processModel` query is always cheap; if profiling shows repeated cold misses on hot process versions, address it by warming the cache at deploy time (already the case — `persist_deploy_batch/3` primes `ModelCache` on a successful commit) or by monitoring `[:evil_engine, :model_cache, :fetch]` telemetry (`metadata.cache_hit`) rather than by changing resolver code. The resolver contract is "correct on both warm and cold paths"; performance tuning belongs in cache-warming policy, not in the GraphQL layer.

## P64: The GraphQL depth limit was sized for the flat persistence graph — recursive `SubProcessNode.flowNodes` needs headroom

**Mistake:** Treating `EVIL_GRAPHQL_MAX_DEPTH` (default 16) as generous for the Process Model graph because it was generous for `processInstance { flowNodeInstances { ... } }`.

**Why it happens:** `SubProcessNode.flowNodes` is genuinely recursive (`SubProcessNode implements FlowNode`, and `flowNodes: [FlowNode!]!` can itself contain `SubProcessNode`s). A debugger-shaped query selecting `flowNode { ... on SubProcessNode { flowNodes { ... on SubProcessNode { flowNodes { ... } } } } }` for a diagram with embedded subprocesses nested a few levels deep can hit a persistence-graph-sized limit well before it hits any genuinely excessive query.

**Correct approach:** The default is **16**, sized for `getProcessInstance → processVersion → processModel → flowNodes` plus the SDK helper's default recursion depth of 4. `graphql_model_graph_wp7_test.exs` pins a regression test asserting the canonical `buildProcessModelSelection(4)`-shaped query returns data with no errors, and that the configured limit stays at least 16. If `EVIL_GRAPHQL_MAX_DEPTH` is ever lowered, or a client raises its recursion depth past what the SDK helper defaults to, re-run that test before assuming the change is safe.

## P65: `FieldTable.verify!/0` does not prove a GraphQL field exists

**Mistake:** Treating a FieldTable row marked `exposed` as proof that clients can query that field.

**Why it happens:** `FieldTable.verify!/0` compares Elixir struct keys against the `exposed`/`excluded` lists. It never looks at Absinthe type definitions. `SendTask.out_mappings` was a concrete case: the table (and the struct, and the TS `FLOW_NODE_TYPE_FIELDS` after the fact) said the field was exposed, while `:send_task_node` omitted it and the GraphQL query simply could not select it.

**Correct approach:** After adding or renaming a Model-graph field, update **both** the FieldTable row and the `field :...` declaration in `model_types.ex` (plus the TS `FLOW_NODE_TYPE_FIELDS` / `buildProcessModelSelection` helpers). `EvilEngineWeb.Graphql.ModelGraphIntrospectionTest` asserts every `exposed` atom exists on the Absinthe type `FieldTable.graphql_identifier/1` names, and that every `EvilEngine.BPMN.Model.*` struct module is registered. Do not rely on `verify!/0` alone.

## P66: Packages CI must install Rust before `mix release`

**Mistake:** Compiling a `MIX_ENV=prod` OTP release in `.github/workflows/packages-ci.yml` with only `erlef/setup-beam`, then expecting `mix compile` / `mix release` to succeed.

**Why it happens:** `core_expressions` builds a Rustler NIF (dsntk FEEL). The Dockerfile already installs rustup; the Packages workflow did not. Cargo cache keys in the same job are not a substitute for `rustc`. Without a toolchain the integration job fails and the SDK/client publish job never runs.

**Correct approach:** Install native build deps (`build-essential`, `pkg-config`, `libssl-dev`) and pin Rust to the version in `.tool-versions` (`dtolnay/rust-toolchain` with `1.97.0`) before `mix deps.get --only prod`. Keep lint/build/unit and publish `pnpm` invocations filtered to `@elraptorus/daemonengine_sdk` and `@elraptorus/daemonengine_client` — `pnpm -r` also walks example packages that have no `lint` / `test:unit` scripts. Query GitHub Packages explicitly (`pnpm view … --registry https://npm.pkg.github.com`) when auto-incrementing the publish version; the public npm registry does not host `@elraptorus/*`.

## P68: Do not put `max_children` on the DynamicSupervisor / do not queue leftover PIs for later resume

**Mistake:** Setting `max_children` on `EvilEngine.Execution.Supervisor` from `EVIL_MAX_CONCURRENT_PIS`, or queueing PIs that exceed the cap for a later resume pass.

**Why it happens:** The env var looks like a supervisor limit. Queueing leftovers seems like a way to honor the cap at boot.

**Correct approach:** `max_children` is hardcoded `:infinity`. The cap is a **soft pre-check** on `Execution.start_process_instance/1` for **new public starts** only. **Resume bypasses the cap by design** so a PI tree comes back as a whole (parent Call Activity / SubProcess / Transaction / Ad-hoc shells plus children). Applying the cap mid-resume, or resuming a parent while deferring its children, leaves a corrupted tree — worse than temporary oversubscription. After boot, new starts hit the cap again; the oversubscribed set drains by natural completion. See [execution.md](./execution.md) §DynamicSupervisor + Registry and §Resume on Startup.

## P69: Do not point production Timer Start persistence at NoOp

**Mistake:** Leaving production `:core_timers, :persistence_module` on `EvilEngine.Timers.Persistence.NoOp`, so cycle Timer Start schedules vanish on engine restart even though `StartEventManager.reload_start_schedules/0` runs at boot.

**Why it happens:** NoOp is the test-env default (`config/test.exs`). Copying that assignment into production `config/config.exs` (or forgetting to set the Ash adapter) makes boot reload a no-op: there is nothing in Postgres to reload.

**Correct approach:** Production `config/config.exs` must set `:core_timers, :persistence_module` to `EvilEngine.Persistence.TimerStartScheduleAdapter` (Ash + the operational `timer_start_schedules` table). Test env keeps NoOp; `ExecutionCase` switches integration tests to the adapter. PI-scoped catch/boundary timers stay in FNI `type_properties` plus Scheduler ETS — there is no `engine_timers` table.

**Related test isolation:** Cycle Timer Start registrations stay in Scheduler ETS until `unregister_timer_starts/1`. Integration and conformance share one BEAM in `coverage_runner.exs`, so a leftover `R/PT1S` schedule can delay or starve a later `PT0S` boundary (C83/C91: expected two final tokens, got one). `ExecutionCase` setup calls `EvilEngine.Timers.Scheduler.reset_state/0` after terminating leftover PIs.

## P70: Error Boundary catch codes resolve `errorRef`; catch-all ranks after specific; `fail_async` is the production Service Task failure path

**Mistake:** Treating Error Boundary matching as document-order first-match on raw XML `errorCode`/`errorMessage` attributes, or assuming a Service Task plugin failure must return `{:error, _}` from `handle_enter/3` to be catchable.

**Why it happens:** Throw-side Error End Events document inline `evil:errorCode` overriding a global `<bpmn:error>`. Catch-side boundaries typically carry `errorRef` with no inline code. A 3-arity `find_matching_error_boundary/3` that never receives `Definitions` cannot resolve `errorRef`, so a correctly modelled specific boundary looks like a catch-all (or matches nothing). Separately, Service Tasks are async-only: production failures after `{:async, ref}` go through `fail_async_service_task`, not a second `handle_enter`.

**Correct approach:**

- Resolve the boundary's catch code the same way as throw-side: inline `evil:errorCode` if present, else global `errorCode` via `errorRef`, else `nil` (catch-all). Pass `Definitions` into `BoundaryResolver.find_matching_error_boundary/4`.
- Rank matches: first boundary whose **resolved** code equals the raised `error_code` (message AND-filter still applies), then first catch-all. Document order is not a specificity tiebreak.
- Plugin Service Task failures use `facade.service_tasks.fail_async.(flow_node_instance_id, error_code, error_message)`. The PI routes that through the same Error Boundary resolver as enter-time errors. `finish_async` output-pipeline failures use the same complete-path wrap.

