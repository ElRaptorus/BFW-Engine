---
title: Evil Engine — Data Model
parent_document: ../ImplementationPlan.md
---

<!--
  Extracted from ImplementationPlan.md §4 ("Data model (Postgres)").
-->

# Evil Engine — Data Model

See [`Schema.md`](../Schema.md) for the visual ER diagram.

> **Shipped vs specified:** the current migration creates catalog, execution,
> data-object, message/signal, and decision tables. There is **no**
> `pending_escalations` table (escalation D1). Dedicated `escalations`,
> `compensations`, and `engine_timers` tables remain specified below but are
> **not** in the current schema. Escalation and compensation runtime uses
> EngineEventBus plus in-memory registries; PI-scoped timers persist in FNI
> `type_properties`; Timer Start schedules use `Timers.Persistence.NoOp`.
> `GET /stats` computes pending user-task and FNI counts via Ash — there is
> no `user_tasks_pending` materialized view and no `process_statistics` view.

## 4. Data model (Postgres)

All tables defined as Ash resources (`AshPostgres`) with generated migrations. Time columns are `timestamptz`. Identifiers are UUIDv7 for natural time-ordering on indexes.

### 4.1 Catalog

```
processes
  id                  uuid PK
  process_model_id         text        -- the BPMN process id attribute
  name                text
  enabled             boolean
  created_at          timestamptz
  UNIQUE (process_model_id)

process_versions
  id                  uuid PK
  process_id          uuid FK -> processes.id
  version             text        NOT NULL    -- from <evil:version>, required at deploy time
  definitions_id      text        NULL        -- bpmn:definitions@id from the BPMN XML; nullable for legacy deploys
  bpmn_xml            text         -- full XML, normalized. SINGLE SOURCE OF TRUTH for the process definition. The parsed AST is built in memory by EvilEngine.BPMN.ModelCache on first access and is never persisted — neither the AST nor the compiled Data Contracts live in the database.
  deployer            jsonb        -- identity claim of deployer at deploy time
  deleted             boolean     NOT NULL DEFAULT false       -- deletion flag, irreversible in v1
  deleted_at          timestamptz NULL                         -- set in the same txn that flips `deleted` to true
  deleted_by          jsonb       NULL                         -- identity claim of the caller that deleted this version (same shape as `deployer` / `process_instances.started_by`)
  deployed_at         timestamptz
  UNIQUE (process_id, version)

-- NOTE: there is no per-version `enabled` column. The `enabled` flag lives only on `processes`.
-- NOTE: `deleted=true` means the version is deleted — blocks new PI starts on this version
--       and keeps the row + `bpmn_xml` for audit-only reads. Running PIs on a soft-deleted
--       version cannot be resumed across a `ModelCache` eviction (e.g. after node restart):
--       the cache-heal path (`load_bpmn_xml/1`) also respects `deleted=false`, so a cache miss
--       for a deleted version returns `{:error, :not_found}` and the PI's resume fails. See
--       `docs/architecture/execution.md` for the full resume contract. `deleted_at` +
--       `deleted_by` form the deletion audit trail; both are NULL while `deleted=false`.
--       Invariant enforced by a check constraint:
--       `(deleted = false AND deleted_at IS NULL AND deleted_by IS NULL)
--        OR (deleted = true AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL)`.

processes_latest_version_view  -- materialized view / regular view: latest `deleted=false` per process
```

### 4.1.1 DMN Catalog

Mirrors the BPMN catalog pattern (§4.1) for DMN decision models. Both tables
live in `apps/peripheral_persistence/`. The `DecisionResolverImpl` adapter
(Peripheral) implements the `core_execution.DecisionResolver` behaviour for
runtime resolution.

```
decision_definitions
  id                       uuid PK
  decision_definition_id   text        -- DMN definitions@id attribute (deploy key)
  name                     text
  enabled                  boolean     NOT NULL DEFAULT true
  created_at               timestamptz
  UNIQUE (decision_definition_id)

decision_versions
  id                       uuid PK
  definition_id            uuid FK -> decision_definitions.id
  version                  text        NOT NULL    -- from DMN definitions metadata
  dmn_xml                  text        NOT NULL    -- full XML, single persistent source of truth
  deployed_by              jsonb                   -- identity claim of deployer
  deployed_at              timestamptz
  deleted                  boolean     NOT NULL DEFAULT false
  deleted_at               timestamptz NULL
  deleted_by               jsonb       NULL
  UNIQUE (definition_id, version)
```

The relationship to FNI `type_properties` is **not** a FK — the BRT handler
stores `decision_version_id` and `decision_ref` as strings inside the JSON
`type_properties` map on the `flow_node_instances` row. This keeps the
execution-state schema decoupled from the DMN catalog while providing a
join key for debugger/audit queries.

### 4.2 Execution state (CRUD snapshots)

```
-- NOTE: `process_instances.process_version_id` is a stable UUID FK. A resumed PI always
-- executes on the same `process_version` it originally started on — even if newer versions
-- have been deployed since, or the original version has been deleted.

-- NOTE: LZ4 column-level compression is applied to every heavy JSONB column listed below (via
-- `COMPRESSION lz4`). Typically 20-40% storage reduction + 3-8% CPU win over the Postgres-default PGLZ
-- on realistic workloads. Phase 5 load tests gate this: if the measured overhead exceeds 10% vs PGLZ
-- on any representative workload, the default reverts. Small/short JSONB columns (e.g. `started_by`
-- identity claims) stay uncompressed; TOAST kicks in automatically past ~2 KiB either way.

process_instances
  id                              uuid PK
  process_version_id              uuid FK         -- immutable for the lifetime of the PI; used by Resume
  parent_process_instance_id      uuid FK NULL  -- for call activities / subprocesses
  business_key                    text NULL     -- user-assigned business key
  triggerer_flow_node_instance_id uuid NULL
  state                           text          -- running | finished | fatal | aborted | error | escalated | compensated
  started_at                      timestamptz
  finished_at                     timestamptz NULL
  started_by                      jsonb         -- identity claim
  started_with_context            jsonb COMPRESSION lz4   -- readonly process context (concept §Process Context); capped at EVIL_TOKEN_MAX_BYTES
                                                -- NOTE: there is no `final_token` column — the PI's "final token(s)"
                                                --   are derivable from End-Event FNIs' `output_token` via GraphQL's
                                                --   `finalTokens: [Json!]` Ash calculation ([`api.md`](./api.md) §10.2). For `finished` PIs
                                                --   the calc returns the list of End-FNI output_tokens (length 1 for
                                                --   linear flows, N for parallel-End flows); for all other terminal
                                                --   states (`fatal`/`aborted`/`error`/`escalated`/`compensated`)
                                                --   it returns `null` — those states did not produce a BPMN "result".
                                                -- NOTE (Call Activity contract, Phase 3): the Call Activity `onFinished`
                                                --   handler reads `output_token` from the terminating End-Event FNI(s)
                                                --   of the child PI — the same data source as `finalTokens`.
  deleted                         boolean NOT NULL DEFAULT false   -- PI deletion via DeleteProcessInstance
  deleted_at                      timestamptz NULL                 -- set atomically with deleted=true
  deleted_by                      jsonb NULL                       -- identity claim of the deleting user
                                                -- CHECK (deleted_at IS NULL = (deleted = false))
                                                -- CHECK (deleted_by IS NULL = (deleted = false))
                                                -- Deleted PIs are excluded from default list queries / GraphQL
                                                -- but remain in the DB for retention/purge cleanup.
  INDEX (state) WHERE state='running'
  INDEX (process_version_id, state)
  INDEX (business_key)

flow_node_instances
  id                              uuid PK
  process_instance_id             uuid FK
  flow_node_id                    text          -- BPMN element id
  flow_node_type                  text          -- startEvent | userTask | ...
  event_type                      text NULL     -- event definition subtype: message | signal | timer | error |
                                                --   escalation | conditional | compensation | terminate | cancel | link.
                                                --   NULL for non-event flow nodes and plain (untyped) events.
                                                --   SendTask/ReceiveTask get 'message' (BPMN message-task semantics).
                                                --   Derived from the BPMN model at FNI creation time; immutable.
  lane_name                       text NULL     -- denormalized from AST (FlowNode.lane_id → Lane.name).
                                                --   NULL = flow node not in any lane, or process has no lanes.
                                                --   Set at FNI creation time; immutable.
  state                           text
  started_at                      timestamptz
  finished_at                     timestamptz NULL
  previous_flow_node_instance_ids uuid[]        -- array to support joins (parallel/inclusive)
  triggerer_flow_node_instance_id uuid NULL
  input_token                     jsonb COMPRESSION lz4   -- capped at EVIL_TOKEN_MAX_BYTES at write_result/handler-return time
  output_token                    jsonb COMPRESSION lz4 NULL   -- capped at EVIL_TOKEN_MAX_BYTES; retained in v1 (derived final tokens
                                                                --   is a smaller win with gateway-transform edge cases; defer)
  type_properties                 jsonb COMPRESSION lz4   -- per-element runtime-relevant snapshot
  INDEX (process_instance_id)
  INDEX (process_instance_id, lane_name)        -- supports the PI visibility SEMI JOIN
  INDEX (state) WHERE state='active'
  INDEX (flow_node_type, state)

-- NOTE: the `active_tokens` table has been removed.
--   Normal execution passes tokens in-memory between handlers inside the PI's `:gen_statem` process
--   — the database is never read for a token payload during execution, only written for durability.
--   Every "active token" is 1:1 with a `flow_node_instances` row in state='active' whose `input_token`
--   column already stores the payload. Resume rehydrates active tokens by scanning
--   `flow_node_instances WHERE state='active'` per running PI — no separate shadow table needed.
--   The narrow case `active_tokens` formerly covered — parallel-join arrival buffering — moves to
--   the dedicated `gateway_pending_arrivals` table below.

gateway_pending_arrivals   -- parallel / inclusive gateway join buffering
                           -- Written when a token arrives at a join gateway whose incoming branches
                           -- have not yet all fired. One row per (gateway_flow_node_instance_id, source_branch_id).
                           -- Rows are deleted atomically when the gateway fires (all-required-branches-
                           -- arrived) or when the enclosing scope is interrupted.
                           -- Not partitioned — the working set is bounded by "currently-waiting gateway
                           -- joins across all running PIs" which is small at any instant.
                           -- **Runtime status:** Fully wired into the execution engine (not schema-only).
                           -- Each branch arrival at a join gateway is persisted for crash-safe parallel
                           -- gateway join synchronization. All arrival rows for a gateway FNI are deleted
                           -- when the join fires. On engine restart, `ProcessInstance.Resumption.rebuild_join_arrivals/2`
                           -- reconstructs the in-memory `join_arrivals` state from these rows.
  id                         uuid PK (UUIDv7)
  process_instance_id        uuid FK NOT NULL
  gateway_flow_node_instance_id             uuid FK flow_node_instances NOT NULL
                                                 -- the gateway join's FNI, in state='active' and waiting
  source_branch_sequence_flow_id  text NOT NULL
                                                 -- the bpmn:sequenceFlow@id of the incoming branch that
                                                 -- delivered this token. Distinguishes arrivals on the
                                                 -- same gateway from different branches.
  source_flow_node_instance_id              uuid FK flow_node_instances NOT NULL
                                                 -- the FNI at the tail of the branch whose completion
                                                 -- delivered this arrival. Useful for debugging.
  arrived_payload            jsonb COMPRESSION lz4 NOT NULL
                                                 -- the token payload as seen from this branch, capped
                                                 -- at EVIL_TOKEN_MAX_BYTES.
  arrived_at                 timestamptz NOT NULL
  UNIQUE (gateway_flow_node_instance_id, source_branch_sequence_flow_id)
                                                 -- one row per (gateway, branch); a second arrival on
                                                 -- the same branch is an invariant violation
  INDEX (process_instance_id)
  INDEX (gateway_flow_node_instance_id)

data_objects        -- CURRENT-VALUE snapshot, one row per (PI, DO), upserted on every write.
                    -- Used for runtime reads and resume-time cache rehydration.
                    -- History lives in data_object_writes (§4.3).
                    -- Schema is unified with data_object_writes: both tables share the
                    -- same column set. Convenience aggregations (write_count, first/last_written_by)
                    -- were dropped — they are derivable from the history table.
  id                    uuid PK
  process_instance_id   uuid FK
  data_object_id        text          -- BPMN id (bpmn:dataObject@id, unique within the Process Model)
  flow_node_instance_id uuid FK flow_node_instances NOT NULL  -- FNI of the write that created this snapshot
  value                 jsonb COMPRESSION lz4   -- JSON value; `jsonb 'null'` is a legitimate written value.
                                      -- Row absence (not jsonb null) means "never written" / unset.
                                      -- Capped at EVIL_TOKEN_MAX_BYTES at DOA-commit time.
  created_at            timestamptz NOT NULL     -- timestamp of this snapshot (== the write that produced it)
  UNIQUE (process_instance_id, data_object_id)
```

### 4.3 Audit / communication (append-only)

```
process_instance_events
  -- PARTITIONED: PARTITION BY RANGE (occurred_at), one partition per calendar month
  -- (e.g. process_instance_events_2026_04). Partitions are created ahead of time by a Mix
  -- task (`mix evil.partitions.ensure`) run from the engine's release hook on boot; future
  -- v2 archival will drop whole partitions instead of running row-by-row DELETEs.
  --
  -- NO LONGER POPULATED: the built-in `database` EventSink was removed. This table
  -- is retained for migration compatibility but stays empty on fresh installs. Historical
  -- audit-trail design used the `database` sink to write rows here when
  -- `EVIL_EVENT_SINK_DATABASE=on`; that env var and sink no longer exist. Operators who
  -- need a SQL-queryable event log register a plugin sink instead. The Studio debugger's
  -- BPMN-flow view does NOT require this table (it reconstructs from the always-on
  -- kernel tables: flow_node_instances with triggerer_flow_node_instance_id,
  -- process_instances, data_object_writes, messages/signals/escalations with
  -- correlations[], engine_timers — see [`observability.md`](./observability.md) §11.1).
  --
  -- data_object.written rows were previously mirrored here by the DB sink; the underlying
  -- data_object_writes row (below) is always written regardless — see the note in
  -- [`../ImplementationPlan.md`](../ImplementationPlan.md) §3.6 on the "kernel state"
  -- vs "observability sink" split.
  id                      uuid NOT NULL (UUIDv7 — natural time sort)
  process_instance_id     uuid FK
  flow_node_instance_id   uuid FK NULL
  event_type              text      -- canonical values:
                                    --   pi.started | pi.finished | pi.error | pi.fatal | pi.compensated | pi.escalated | pi.resumed
                                    --   fni.started | fni.finished | fni.error | fni.fatal | fni.interrupted | fni.compensated
                                    --   message.published | message.received
                                    --   signal.published | signal.received
                                    --   escalation.raised | escalation.caught
                                    --   timer.armed | timer.fired | timer.cancelled
                                    --   data_object.written                             (payload carries write_id + flow_node_instance_id + value + previous_value)
                                    --   user_task.claimed | user_task.completed
                                    --   retention.purged                                (emitted by RetentionRunner + manual purge)
                                    --   sink.failed                                     (emitted by EngineEventBus when a sink crashes)
  severity                text      -- error|warn|info|debug|verbose
  occurred_at             timestamptz NOT NULL
  payload                 jsonb COMPRESSION lz4
                                    -- LZ4-compressed; payload carries the typed Event.* struct serialized
                                    -- to JSON. For data_object.written events the payload carries a reference
                                    -- to the kernel-state `data_object_writes` row (write_id) so subscribers
                                    -- can join rather than duplicate the full value. Cap applies via the emitting
                                    -- write_* boundary (the caller has already rejected oversize payloads; the
                                    -- event-persist step cannot see anything over EVIL_TOKEN_MAX_BYTES).
  PRIMARY KEY (id, occurred_at)     -- composite because partition key must be in PK
  INDEX (process_instance_id, occurred_at)
  INDEX (event_type, occurred_at)

-- NOTE: `messages`, `pending_messages`, `signals`, `escalations`, and `compensations` are
-- ENGINE-LEVEL AUDIT tables — they have no PI FK (the relation to PIs is via `messages.correlations[]`
-- / broadcast semantics), so they are NOT cleaned up by PI-cascade retention. Engine-audit retention gives them
-- their own story: monthly partitioning on the published_at / triggered_at timestamp (below) + a
-- single opt-in retention knob EVIL_RETENTION_ENGINE_AUDIT_DAYS ([`configuration.md`](./configuration.md) §14.3, §14.6) that the existing
-- `RetentionRunner` applies as a second per-tick pass. Operational-state rows (pending_messages
-- state='pending', engine_timers state='armed') are NEVER retention-eligible.

messages
  -- PARTITIONED: PARTITION BY RANGE (published_at), one partition per calendar month.
  -- Same partitioning scheme as process_instance_events. Partitions are pre-created
  -- by `mix evil.partitions.ensure` gated by EVIL_PARTITION_AHEAD_MONTHS. Composite primary
  -- key (id, published_at) because the partition key must be in the PK.
  id                       uuid NOT NULL (UUIDv7 — natural time sort)
  message_name             text      NOT NULL
  payload                  jsonb COMPRESSION lz4      -- LZ4; capped at EVIL_TOKEN_MAX_BYTES at publish time
  correlation_value        text      NULL        -- stamped at publish time ([`routing.md`](./routing.md) §3.5.2). NULL == :none (the "no-key" bucket)
  origin                   jsonb                 -- { source: "api"|"pi", process_instance_id?, flow_node_instance_id? }
  published_at             timestamptz NOT NULL  -- partition key
  correlations             jsonb     NOT NULL DEFAULT '[]'::jsonb
                                                 -- array of {process_instance_id, flow_node_instance_id, delivered_at}.
                                                 -- Length 0 = unmatched at publish (see pending_messages).
                                                 -- Length ≥ 1 = broadcast-within-key (serial-letter semantics).
                                                 -- Length > 1 legitimately occurs when multiple PIs share the same correlation_value.
  PRIMARY KEY (id, published_at)                 -- composite because published_at is the partition key
  INDEX (message_name, published_at)
  INDEX (message_name, correlation_value)        -- supports publish-side registry lookup + audit queries

pending_messages    -- [`routing.md`](./routing.md) §3.5.4 — unmatched publishes held for TTL
  -- PARTITIONED: PARTITION BY RANGE (published_at), one partition per calendar month.
  -- Note: the FK into `messages` is enforced at the logical level via (message_id, published_at)
  -- pair (both tables share the same partition key), so cross-partition FKs behave correctly.
  --
  -- RETENTION: EVIL_RETENTION_ENGINE_AUDIT_DAYS sweeps rows WHERE state IN ('delivered',
  -- 'expired','cancelled'). Rows in state='pending' are operational live state and are NEVER
  -- touched by retention — they either transition naturally (TTL sweeper at [`routing.md`](./routing.md) §3.5.4) or survive
  -- until the next engine boot for resume-time re-subscription drain ([`routing.md`](./routing.md) §3.5.5).
  --
  -- DELETE-ON-TRANSITION: if EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION=false (default
  -- true), the row is physically deleted the moment its state transitions to delivered/expired/
  -- cancelled, so this table holds only rows still in state='pending'. Operators choose between
  -- audit-retention (default) and zero-retention for this table specifically.
  id                       uuid NOT NULL (UUIDv7)
  message_id               uuid NOT NULL         -- logical FK to messages (same partition scheme)
  message_name             text NOT NULL         -- denormalized for index
  correlation_value        text NULL             -- denormalized for index; NULL == :none
  payload                  jsonb COMPRESSION lz4 -- LZ4; denormalized snapshot so delivery doesn't re-read messages
  published_at             timestamptz NOT NULL  -- partition key
  expires_at               timestamptz NOT NULL  -- published_at + EVIL_MESSAGE_PENDING_TTL
  state                    text NOT NULL         -- pending | delivered | expired | cancelled
  delivered_at             timestamptz NULL      -- set when state transitions to 'delivered'
  expired_at               timestamptz NULL      -- set when state transitions to 'expired'
  PRIMARY KEY (id, published_at)                 -- composite because published_at is the partition key
  INDEX (message_name, correlation_value) WHERE state='pending'  -- subscription-register fast-path
  INDEX (expires_at) WHERE state='pending'                       -- sweeper scan
  -- Signals and Escalations never enter this table; only Messages with zero matching subscriptions at publish time.

signals    -- engine-level audit table. No payload, no correlation_value — signals are
  -- payload-free and correlation-free pure broadcast by signal name.
  -- PARTITIONED: PARTITION BY RANGE (published_at), one partition per calendar month.
  -- Composite primary key (id, published_at). Retention-eligible in full (no operational-state
  -- subset — a signal publish has no "in-flight" shape; it either fanned out or it didn't).
  id                       uuid NOT NULL (UUIDv7)
  signal_name              text NOT NULL
  origin                   jsonb                 -- { source: "api"|"pi", process_instance_id?, flow_node_instance_id? }
  published_at             timestamptz NOT NULL  -- partition key
  deliveries               jsonb NOT NULL DEFAULT '[]'::jsonb
                                                 -- array of {process_instance_id, flow_node_instance_id}.
                                                 -- Length 0 = unmatched at publish (see pending_signals).
                                                 -- Length ≥ 1 = broadcast to every matching subscription at publish
                                                 --   PLUS every subscription that drained the pending_signals row
                                                 --   within EVIL_SIGNAL_PENDING_TTL.
  started_process_instance_ids jsonb NOT NULL DEFAULT '[]'::jsonb
                                                 -- array of PI IDs started via Signal Start Events.
  PRIMARY KEY (id, published_at)
  INDEX (signal_name, published_at)

pending_signals    -- [`routing.md`](./routing.md) §3.5.6 — signals published with zero matching listeners held for TTL.
  -- No payload, no correlation_value — signals are payload-free and correlation-free.
  -- PARTITIONED: PARTITION BY RANGE (published_at), one partition per calendar month.
  -- Same partitioning scheme as pending_messages; pre-created by `mix evil.partitions.ensure`.
  -- Logical FK into `signals` via (signal_id, published_at) — both tables share the partition key,
  -- so cross-partition logical FK behavior matches pending_messages / messages.
  --
  -- RETENTION: EVIL_RETENTION_ENGINE_AUDIT_DAYS sweeps rows WHERE state IN ('delivered',
  -- 'expired','cancelled'). Rows in state='pending' are operational live state and are NEVER
  -- touched by retention — they either transition naturally (TTL sweeper) or survive engine
  -- boot for resume-time re-subscription drain ([`routing.md`](./routing.md) §3.5.6).
  --
  -- DELETE-ON-TRANSITION: if EVIL_PENDING_SIGNALS_KEEP_AFTER_TRANSITION=false (default
  -- true), the row is physically deleted the moment its state transitions to delivered/expired/
  -- cancelled. Same semantics as EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION.
  id                       uuid NOT NULL (UUIDv7)
  signal_id                uuid NOT NULL         -- logical FK to signals (same partition scheme)
  signal_name              text NOT NULL         -- denormalized for index
  published_at             timestamptz NOT NULL  -- partition key
  expires_at               timestamptz NOT NULL  -- published_at + EVIL_SIGNAL_PENDING_TTL
  state                    text NOT NULL DEFAULT 'pending'  -- pending → delivered | expired
  delivered_at             timestamptz NULL      -- set when claimed by first subscriber
  expired_at               timestamptz NULL      -- set by PendingSweeper
  PRIMARY KEY (id, published_at)                 -- composite because published_at is the partition key
  INDEX (signal_name) WHERE state='pending'      -- subscription-register fast-path (no correlation dim — signals broadcast)
  INDEX (expires_at) WHERE state='pending'       -- TTL sweeper scan
  -- Messages and Escalations never enter this table; only Signals published with zero listeners
  --   at publish time. Crash-recovery (engine restart mid-broadcast) is also covered: the
  --   surviving pending row is drained by any subscription that re-registers within TTL after
  --   resume ([`routing.md`](./routing.md) §3.5.6).

escalations    -- same shape as signals, plus escalation_code + escalation_name. payload LZ4, cap from EVIL_TOKEN_MAX_BYTES. Tracks cross-PI propagation.
  -- PARTITIONED: PARTITION BY RANGE (published_at), one partition per calendar month.
  -- Composite primary key (id, published_at). Retention-eligible in full.
  id                       uuid NOT NULL (UUIDv7)
  escalation_code          text NOT NULL         -- bpmn:escalation@escalationCode
  escalation_name          text NULL             -- bpmn:escalation@name (optional)
  payload                  jsonb COMPRESSION lz4
  origin                   jsonb                 -- { process_instance_id, flow_node_instance_id } — always PI-sourced per [`routing.md`](./routing.md) §3.5.7
  published_at             timestamptz NOT NULL  -- partition key (when publish_escalation/1 entered the walker)
  scope_chain              jsonb NOT NULL        -- scope-chain walker trace: [{process_instance_id, scope_kind, scope_id, hop_kind}]
  outcome                  text NOT NULL         -- caught | uncaught_root | uncaught_intermediate_throw_noop | late_caught_observed
                                                 --   `late_caught_observed` = reached root uncaught AND terminal state applied
                                                 --     AND a boundary that registered during pending TTL later fired
                                                 --     its handler side-effects (non-interrupting spawn / interrupting cascade
                                                 --     on a different PI / audit). See [`routing.md`](./routing.md) §3.5.7.
  caught_at                jsonb NULL            -- { process_instance_id, flow_node_instance_id, boundary_kind: "interrupting"|"non_interrupting" } when caught
                                                 --   For `late_caught_observed` outcome, populated with the FIRST late catch.
                                                 --   (Re-catches on same escalation are one-shot .)
  PRIMARY KEY (id, published_at)
  INDEX (escalation_code, published_at)
  INDEX (outcome) WHERE outcome <> 'caught'      -- operator query: "show me uncaught escalations recently"

pending_escalations    -- **DROPPED (escalation D1).** There is no `pending_escalations` table,
  -- no late-catch drain, and no PendingSweeper involvement for escalations.
  -- Escalation boundaries are pre-spawned in `:waiting` when the host activity starts.
  -- The DDL below is historical spec text and must not be implemented.

  -- (removed)
  -- OBSERVABILITY-ONLY: the throw-element-aware terminal state is applied the instant
  --   the walker decides "uncaught"; this pending row does NOT block or defer that decision.
  --   It exists so that Escalation Boundary / Event-Subprocess-Start subscriptions registering
  --   within EVIL_ESCALATION_PENDING_TTL can still fire their handler side-effects (see [`routing.md`](./routing.md) §3.5.7).
  --
  -- PARTITIONED: PARTITION BY RANGE (published_at), one partition per calendar month.
  -- Same scheme as pending_messages / pending_signals; pre-created by `mix evil.partitions.ensure`.
  --
  -- RETENTION: EVIL_RETENTION_ENGINE_AUDIT_DAYS sweeps rows WHERE state IN ('delivered',
  -- 'expired','cancelled'). Rows in state='pending' are operational live state and NEVER swept by
  -- retention.
  --
  -- DELETE-ON-TRANSITION: if EVIL_PENDING_ESCALATIONS_KEEP_AFTER_TRANSITION=false (default
  -- true), the row is physically deleted on state transition. Same semantics as the two siblings.
  id                       uuid NOT NULL (UUIDv7)
  escalation_id            uuid NOT NULL         -- logical FK to escalations (same partition scheme)
  escalation_code          text NOT NULL         -- denormalized for index
  payload                  jsonb COMPRESSION lz4 -- LZ4; snapshot of the escalation payload
  origin                   jsonb                 -- { process_instance_id, flow_node_instance_id } — the throwing FNI ([`routing.md`](./routing.md) §3.5.7)
  scope_chain              jsonb NOT NULL        -- snapshot of the scope-chain walker trace as of "reached root uncaught"
  published_at             timestamptz NOT NULL  -- partition key (moment walker reached root uncaught)
  expires_at               timestamptz NOT NULL  -- published_at + EVIL_ESCALATION_PENDING_TTL
  state                    text NOT NULL         -- pending | delivered | expired | cancelled
                                                 --   delivered = at least one late-registering boundary consumed it.
                                                 --   expired   = TTL elapsed with no late catch (common case; the escalation
                                                 --               remained uncaught in the observability-only sense).
                                                 --   cancelled = explicit operator cancel (not a v1 goal, column reserved).
  delivered_at             timestamptz NULL      -- set on first late-registering catch within TTL
  expired_at               timestamptz NULL      -- set when TTL sweeper flips pending → expired
  PRIMARY KEY (id, published_at)                 -- composite because published_at is the partition key
  INDEX (escalation_code) WHERE state='pending'  -- boundary-register fast-path (no correlation dim)
  INDEX (expires_at) WHERE state='pending'       -- TTL sweeper scan
  -- IMPORTANT: draining a pending_escalations row in state='pending' to a late-registering
  --   boundary does NOT un-apply the terminal state of any PI. See [`routing.md`](./routing.md) §3.5.7 for the precise rules.

-- NOTE: The PI's `compensation_registry` (the ordered list of completed activities
-- eligible for compensation) is an IN-MEMORY data structure on the PI's gen_statem
-- state — it is NOT stored in a dedicated database table. On resume,
-- `Resumption.rebuild_compensation_registry/1` re-derives the registry from persisted
-- `:finished` FNIs by matching each FNI's flow node against the BPMN model's
-- compensation boundary events. Related PI state fields (`compensation_runs`,
-- `compensation_completion_counter`, `compensation_end_reached`,
-- `compensation_esp_throw_map`) are also purely in-memory.

compensations    -- compensation trigger log (one row per emitted compensation token).
  -- PARTITIONED: PARTITION BY RANGE (triggered_at), one partition per calendar month.
  -- Composite primary key (id, triggered_at). Retention-eligible in full.
  id                       uuid NOT NULL (UUIDv7)
  process_instance_id      uuid NOT NULL         -- compensation is always PI-local in v1 (no cross-PI compensation, [`../ImplementationPlan.md`](../ImplementationPlan.md) §16.4)
  ⟪triggering_flow_node_instance_id⟫        uuid NOT NULL         -- FNI that raised the compensation (End/Throw event or boundary)
  activity_ref             text NULL             -- bpmn:activityRef when compensation targets a single activity (else NULL = "all")
  payload                  jsonb COMPRESSION lz4 -- LZ4; capped at EVIL_TOKEN_MAX_BYTES
  triggered_at             timestamptz NOT NULL  -- partition key
  PRIMARY KEY (id, triggered_at)
  INDEX (process_instance_id, triggered_at)

data_object_writes   -- append-only history, one row per Data Object write.
                     -- Written in the SAME transaction as the upsert into data_objects
                     -- (kernel writes stay atomically consistent regardless of sink config).
                     -- Never read at runtime; exists for audit, debugging, replay, GraphQL queries.
                     --
                     -- Schema is UNIFIED with data_objects — both tables share the same column set:
                     -- (id, process_instance_id, data_object_id, flow_node_instance_id, value, created_at).
                     -- previous_value was dropped (derivable from ordered history); new_value renamed
                     -- to value; written_at renamed to created_at.
                     --
                     -- PARTITIONED: PARTITION BY RANGE (created_at), one partition per
                     -- calendar month, same scheme as process_instance_events. Partitions
                     -- created ahead of time by `mix evil.partitions.ensure`.
                     --
                     -- ALWAYS-ON: unlike the legacy data_object.written rows that the
                     -- removed database sink used to mirror in process_instance_events,
                     -- this table is kernel state, not an observability sink — it is required
                     -- for downstream write-audit reconstruction (Studio debugger "who wrote
                     -- what when" panel) and for resume-time invariants. It is always written.
  id                       uuid NOT NULL (UUIDv7 — natural time sort)
  process_instance_id      uuid FK NOT NULL
  data_object_id           text NOT NULL            -- BPMN id (bpmn:dataObject@id)
  flow_node_instance_id    uuid FK flow_node_instances NOT NULL
                                                    -- the FNI whose execution caused the write
  value                    jsonb COMPRESSION lz4
                                                    -- value written. jsonb 'null' is legitimate.
                                                    -- LZ4-compressed; capped at EVIL_TOKEN_MAX_BYTES at DOA-commit time.
  created_at               timestamptz NOT NULL
                                                    -- every row is DOA-originated — there is no
                                                    --   handler-facing write_data_object/2 facade in v1 (see [`../ImplementationPlan.md`](../ImplementationPlan.md) §16.4
                                                    --   non-goal "Handler-API Data Object writes"), so the prior
                                                    --   `source` column (which distinguished DOA vs handler_api) would
                                                    --   be constant and has been removed. The FNI-attribution
                                                    --   invariant ("one write ↔ one owning FNI") is trivially
                                                    --   enforced by flow_node_instance_id + DOA's 1:1 mapping from
                                                    --   a completing FNI to the DOs it targets.
  PRIMARY KEY (id, created_at)                             -- composite because partition key must be in PK
  INDEX (process_instance_id, data_object_id, created_at)  -- per-DO history, reconstruct-in-order
  INDEX (flow_node_instance_id)                            -- "what did FNI X write?"
  -- No partial indexes; all rows are terminal/historical.

engine_timers
  -- SPECIFIED, NOT IN THE CURRENT MIGRATION.
  -- PI-scoped timers persist in FNI `type_properties`; the Scheduler holds armed
  -- timers in ETS. Timer Start schedules use `Timers.Persistence.NoOp`.
  --
  -- NOT PARTITIONED: fire_at can be arbitrarily far-future for scheduled cycle timers,
  --   and adding a dedicated created_at column only for partitioning adds schema churn without
  --   meaningful storage benefit at realistic volumes (~2 timers per PI; the armed-state working
  --   set is small and PI-cascade-deleted when the owning PI is purged ).
  --
  -- RETENTION: EVIL_RETENTION_ENGINE_AUDIT_DAYS sweeps rows WHERE state IN ('fired',
  --   'cancelled') AND fire_at < cutoff via row-by-row DELETE in batches. Rows in state='armed'
  --   are operational live state and are NEVER touched by retention. armed rows with an owning
  --   PI are cascade-deleted with the PI; armed rows with process_instance_id=NULL
  --   (global timer-start-event timers) persist until the timer fires or is cancelled.
  id                      uuid PK
  process_instance_id     uuid FK NULL    -- NULL for global (timer-start event waiting for deploy)
  flow_node_id            text
  flow_node_instance_id   uuid FK NULL
  fire_at                 timestamptz
  kind                    text            -- date|duration|cycle
  iso_spec                text
  state                   text            -- armed|fired|cancelled
  INDEX (fire_at) WHERE state='armed'
  INDEX (state, fire_at) WHERE state IN ('fired','cancelled')  -- retention sweep scan
```

### 4.4 Derived indexes / views (for GraphQL queries)

There is **no** `user_tasks_pending` materialized view and **no**
`process_statistics` SQL view. `GET /stats` (`EvilEngine.Telemetry.StatsCollector`)
computes pending user-task and waiting-FNI counts with live Ash queries against
`flow_node_instances`. GraphQL list/get queries hit Ash resources directly.

### 4.5 Why this schema fits concept's requirements

| Concept requirement | Mechanism |
|---|---|
| "Never the DB bottleneck" | Partial indexes on `state='running'`/`'active'` keep working set small; JSONB GIN for free-form queries; materialized views for heavy aggregates |
| "Store full execution path" | `previous_flow_node_instance_ids` chain + `process_instance_events` append log (table exists; built-in DatabaseSink removed so it stays empty unless a plugin sink writes it) + `messages` (origin+correlation) / `signals` (origin+deliveries). Escalation and compensation traces are EngineEventBus events, not dedicated audit tables. |
| "Full Resume support after crash" | Live rehydration: select all `process_instances.state='running'`, rehydrate PI GenServer, re-project `flow_node_instances.state IN ('active','waiting')` (in-flight token payload lives on `input_token`) + `gateway_pending_arrivals` (for half-completed joins). PI-scoped timers resume from FNI `type_properties` into Scheduler ETS. There is no `engine_timers` table. |
| "Bounded per-row JSONB growth" | Payload slim-down: `process_instances.final_token` eliminated (derived); `active_tokens` table eliminated (derived); LZ4 compression on all heavy JSONB columns (typically 20-40% storage reduction with 3-8% CPU *win* over PGLZ on realistic workloads); hard 64 KiB cap per token/DO/message payload via `EVIL_TOKEN_MAX_BYTES` |
| "Bounded engine-wide audit-table growth" | Engine-audit retention (Phase 7, not shipped) closes the gap PI-cascade retention left for engine-level audit tables with no PI affinity. **Tables that exist today:** `messages` / `pending_messages` / `signals` / `pending_signals`, partitioned monthly on `published_at` (`EvilEngine.Persistence.Partitions`). Single opt-in knob `EVIL_RETENTION_ENGINE_AUDIT_DAYS`. Operational-state rows (`pending_messages.state='pending'`, `pending_signals.state='pending'`) excluded from retention. Optional `EVIL_PENDING_MESSAGES_KEEP_AFTER_TRANSITION=false` / `EVIL_PENDING_SIGNALS_KEEP_AFTER_TRANSITION=false` flips each pending table into zero-retention mode. There is no `pending_escalations` table (escalation D1). Dedicated `escalations` / `compensations` / `engine_timers` tables are specified but **not migrated** — do not plan Pass B DELETEs against them until they exist. |
| "No duplicated rows per tick" | Snapshot tables are **updated in place**; events are only inserted on real state transitions or domain events |
| "Leverage SQL" | All heavy queries are plain SQL. No client-side filtering. GraphQL queries translate 1:1 to Ecto queries via AshPostgres |
