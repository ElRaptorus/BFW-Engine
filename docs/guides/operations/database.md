# Database Administration

The engine requires PostgreSQL 16+ for JSONB support and LZ4 toast compression.

## Connection Configuration

| Env Var | Default | Purpose |
|---------|---------|---------|
| `TDE_DATABASE_URL` | -- | Full connection string (preferred) |
| `TDE_DATABASE_HOST` | -- | Hostname (alternative to URL) |
| `TDE_DATABASE_PORT` | `5432` | Port |
| `TDE_DATABASE_NAME` | -- | Database name |
| `TDE_DATABASE_USER` | -- | Username |
| `TDE_DATABASE_PASS` | -- | Password |
| `TDE_DB_POOL_SIZE` | `100` | Write pool size (PI/FNI lifecycle, deploys, message/signal persistence) |
| `TDE_DB_READ_POOL_SIZE` | `50` | Read pool size (GraphQL queries, REST list/get endpoints) |
| `TDE_DB_CHECKOUT_RETRIES` | `3` | DBConnection retries on mid-query disconnect (Layer 1) |
| `TDE_DB_QUEUE_TARGET` | `100` | CoDel target latency (ms) |
| `TDE_DB_QUEUE_INTERVAL` | `2000` | CoDel measurement interval (ms) |
| `TDE_DB_CHECKOUT_TIMEOUT` | `15000` | Max wait for a pool connection (ms) |
| `TDE_DB_QUEUE_TIME_WARNING_MS` | `500` | Log warning when queue_time exceeds this threshold (ms) |
| `TDE_DB_IPV6` | `false` | Connect over IPv6 |
| `TDE_DB_SSL` | `false` | Enable SSL |

`TDE_DATABASE_URL` takes precedence over individual vars. Both the write pool (`Repo`) and read pool (`ReadRepo`) connect to the same database URL.

### Dual-Pool Architecture

The engine uses two Ecto repos with separate connection pools:

- **Write pool** (`EvilEngine.Persistence.Repo`, `TDE_DB_POOL_SIZE`) — handles all mutations: PI/FNI state writes, deployments, message/signal persistence, retry orchestration.
- **Read pool** (`EvilEngine.Persistence.ReadRepo`, `TDE_DB_READ_POOL_SIZE`) — handles all reads: GraphQL queries, REST list/get, Ash read actions.

The 2:1 default (100 write / 50 read) reflects workload asymmetry: tens of thousands of PIs produce massively concurrent writes, while a comparatively small number of Studio users issue read queries. Adjust based on your workload profile.

Size PostgreSQL with `max_connections >= (write + read) * engine_nodes + 20`. Production defaults (100 + 50) already exceed Postgres's default `max_connections` of 100; a single-node install needs at least 170 (recommend 200).

## Persistence Resilience

| Env Var | Default | Purpose |
|---------|---------|---------|
| `TDE_DB_CHECKOUT_RETRIES` | `3` | DBConnection-level retries on mid-query disconnect (Layer 1) |
| `TDE_PERSISTENCE_RETRY_MAX_ATTEMPTS` | `5` | Application-level retry attempts per adapter call (Layer 2) |
| `TDE_PERSISTENCE_RETRY_INITIAL_BACKOFF_MS` | `100` | Initial backoff before first retry; doubles on each attempt (Layer 2) |

Layer 1 handles transparent reconnection at the pool level. Layer 2 (`PersistenceRetry`) wraps all adapter calls with bounded exponential backoff and jitter. Total worst-case retry window: ~3.1s. See `docs/architecture/execution.md` §Persistence Resilience for the fail-fast vs. log-and-continue classification.

## Migration Workflow

The engine uses a **single initial migration**. Edit `apps/peripheral_persistence/priv/repo/migrations/20260501110314_create_initial_schema.exs` in place. Do **not** run `mix ash_postgres.generate_migrations`.

```bash
# Apply the initial schema (dev / test)
MIX_ENV=test mix ecto.migrate

# Production release
bin/evil_engine eval "EvilEngine.Persistence.Release.migrate()"
```

## Key Tables

Live tables include:

| Table | Purpose |
|-------|---------|
| `processes` | Process catalog (never retention-deleted) |
| `process_versions` | Versioned BPMN XML and metadata |
| `process_instances` | PI state and lifecycle |
| `flow_node_instances` | FNI state, tokens, type properties |
| `data_objects` | Current Data Object snapshots |
| `data_object_writes` | Append-only DO write audit (partitioned) |
| `process_instance_events` | Partitioned table retained for schema compatibility; the engine does not write typed events here |
| `gateway_pending_arrivals` | Pending gateway join tokens |
| `timer_start_schedules` | Cycle Timer Start Event schedules |
| `messages` / `pending_messages` | Published messages and pending-message hold |
| `signals` / `pending_signals` | Published signals and pending-signal hold |
| `decision_definitions` / `decision_versions` | DMN catalog |

There are **no** `escalations`, `compensations`, `engine_timers`, or `pending_escalations` tables. Escalation and compensation observability is EngineEventBus plus in-memory registries. PI-scoped catch/boundary timers persist in FNI `type_properties` plus Scheduler ETS.

## Partitioning

Six tables are range-partitioned by timestamp: `process_instance_events`,
`data_object_writes`, `messages`, `pending_messages`, `signals`, and
`pending_signals`. At boot the engine creates partitions for the current
period and upcoming periods:

```bash
mix evil.partitions.ensure    # dev
bin/evil_engine eval "EvilEngine.Persistence.Release.ensure_partitions()"  # prod
```

| Env Var | Default | Purpose |
|---------|---------|---------|
| `TDE_PARTITION_INTERVAL` | `quarterly` | `monthly`, `quarterly`, `half_yearly`, `yearly`, or `off` |
| `TDE_PARTITION_AHEAD_MONTHS` | `3` | Future partition lead time (at least 1) |

`mix evil.partitions.ensure` only **creates** upcoming partitions. It does
not drop old ones. For long-uptime nodes, run `pg_partman` (or equivalent)
`DETACH` / `DROP` on those six tables. See [Partition drop](#partition-drop-pg_partman) below.

## Retention

Two independent jobs:

1. **Process-instance trees** — Mix task, opt-in per terminal state.
2. **Message / signal audit rows** — operator SQL. The engine does not
   delete those tables on a schedule.

Unset `TDE_RETENTION_*_DAYS` → the Mix task is a no-op.

```bash
mix evil.retention.purge
mix evil.retention.purge --dry-run
bin/evil_engine eval "EvilEngine.Persistence.Release.purge_retention()"
bin/evil_engine eval "EvilEngine.Persistence.Release.purge_retention(dry_run: true)"
```

Example cron (daily 03:00 UTC):

```cron
0 3 * * * cd /opt/evil_engine && bin/evil_engine eval "EvilEngine.Persistence.Release.purge_retention()"
```

| Env Var | Purpose |
|---------|---------|
| `TDE_RETENTION_FINISHED_DAYS` | Max age for `finished` PIs |
| `TDE_RETENTION_ERROR_DAYS` | Max age for `error` PIs |
| `TDE_RETENTION_FATAL_DAYS` | Max age for `fatal` PIs |
| `TDE_RETENTION_ABORTED_DAYS` | Max age for `aborted` PIs |
| `TDE_RETENTION_ESCALATED_DAYS` | Max age for `escalated` PIs |
| `TDE_RETENTION_COMPENSATED_DAYS` | Max age for `compensated` PIs |
| `TDE_RETENTION_CANCELLED_DAYS` | Max age for `cancelled` PIs (Mix purge only; REST delete still omits `cancelled`) |
| `TDE_RETENTION_BATCH_SIZE` | Max root trees per Mix invocation (default `500`) |
| `TDE_RETENTION_RUN_INTERVAL` | Ignored; cron owns the interval |
| `TDE_RETENTION_ENGINE_AUDIT_DAYS` | Not read by the engine. Use it as the cutoff (in days) for the SQL below |
| `TDE_PENDING_MESSAGES_KEEP_AFTER_TRANSITION` | Default `true`: keep pending-message rows after deliver/expire/cancel (audit). `false`: destroy the row on transition, so the table only holds live `pending` rows |
| `TDE_PENDING_SIGNALS_KEEP_AFTER_TRANSITION` | Same for pending signals |

### What the Mix task deletes

- Selection key is a **root** process instance whose `finished_at` is older
  than the knob for its terminal state.
- Skip that root if any descendant is `running` or `suspended`.
- One transaction per tree: `process_instance_events` →
  `gateway_pending_arrivals` → `data_object_writes` → `data_objects` →
  `flow_node_instances` → `process_instances`.
- Catalog rows (`processes`, `process_versions`) are never touched.
- `messages`, `signals`, `pending_*`, and `timer_start_schedules` are
  never touched by this task.
- REST `DELETE /process-instances/{id}` remains a **soft-delete** of one
  PI and its FNIs. There is no REST purge endpoint.

Ad-hoc cleanup of a specific aged cohort: lower the matching
`TDE_RETENTION_*_DAYS` temporarily and run the Mix task (or `--dry-run`
first).

### Message and signal audit cleanup (operator SQL)

Do **not** DELETE `timer_start_schedules`. Never delete rows with
`state = 'pending'`. Substitute `:cutoff` with
`now() - make_interval(days => <TDE_RETENTION_ENGINE_AUDIT_DAYS>)` or a
literal timestamptz.

```sql
-- Preview
SELECT COUNT(*) FROM messages WHERE published_at < :cutoff;
SELECT COUNT(*) FROM pending_messages
  WHERE state <> 'pending' AND published_at < :cutoff;
SELECT COUNT(*) FROM signals WHERE published_at < :cutoff;
SELECT COUNT(*) FROM pending_signals
  WHERE state <> 'pending' AND published_at < :cutoff;

-- Delete (batched; wrap in a transaction per table)
DELETE FROM pending_messages
  WHERE id IN (
    SELECT id FROM pending_messages
    WHERE state <> 'pending' AND published_at < :cutoff
    LIMIT 500
  );
DELETE FROM pending_signals
  WHERE id IN (
    SELECT id FROM pending_signals
    WHERE state <> 'pending' AND published_at < :cutoff
    LIMIT 500
  );
DELETE FROM messages
  WHERE id IN (
    SELECT id FROM messages
    WHERE published_at < :cutoff
    LIMIT 500
  );
DELETE FROM signals
  WHERE id IN (
    SELECT id FROM signals
    WHERE published_at < :cutoff
    LIMIT 500
  );
```

### Partition drop (`pg_partman`)

For `DETACH` / `DROP` of old partitions, run `pg_partman` (or equivalent)
on `process_instance_events`, `data_object_writes`, `messages`,
`pending_messages`, `signals`, and `pending_signals`.

## Payload cap (`TDE_TOKEN_MAX_BYTES`)

Every user-supplied payload is checked against a single engine-wide byte
cap. The check uses the canonicalized JSON size.

| Env Var | Default | Floor |
|---------|---------|-------|
| `TDE_TOKEN_MAX_BYTES` | `65536` (64 KiB) | `1024` — values below this refuse boot |

There is no per-process or per-endpoint override. There is no maximum;
raise it if the workload legitimately needs larger tokens.

**Applies to:** process start payload and `started_with_context`, User
Task completion results, async Service Task `finish_async` /
`fail_async` payloads, published messages, Data Object values at
write time, and flow-node output tokens. Signals carry no payload.

**Rejection:**

| Surface | Behaviour |
|---------|-----------|
| HTTP (start, message trigger, user-task finish, …) | **413** before any engine state changes |
| GraphQL | `extensions.code = "PAYLOAD_TOO_LARGE"` |
| Handler / FEEL / DOA output produced inside the engine | causing FNI → `fatal` |

Tuning: keep the default unless you have measured a real need. Raising
the cap increases memory per in-flight token and JSONB toast size.
Lowering it below 64 KiB is safe as long as it stays ≥ 1024. Pair with
JSONB compression below; the cap is a size gate, not a compressor.

See [Error Handling](../handbook/error-handling.md) for the HTTP body
shape and [Troubleshooting](troubleshooting.md) for 413.

## JSONB compression (`TDE_JSONB_COMPRESSION`)

| Env Var | Default |
|---------|---------|
| `TDE_JSONB_COMPRESSION` | `lz4` |

Requires PostgreSQL 14+ (the engine requires 16+). The setting applies to
**new** column data created by migrations. Existing rows keep whatever
compression they were written with until rewritten:

```sql
ALTER TABLE flow_node_instances ALTER COLUMN input_token SET COMPRESSION pglz;
UPDATE flow_node_instances SET input_token = input_token;
-- repeat for every heavy JSONB column you intend to convert
```

Leave `lz4` unless you have measured a real regression on your hardware.
The engine does **not** flip this variable from tests.

### LZ4 vs PGLZ measurements

Same VM, two waves (`mix test.load.hardening`, 2026-09-07, report
`test/load/reports/20260907T115201Z.json`). SQL p50/p95 are integer
`query_time_ms` (0 vs 1 is clock resolution). GraphQL is HTTP wall-clock
in milliseconds. `pg_column_size` sum was identical on both waves
(`7335936`). LZ4 was not >10 % slower than PGLZ; **the default stays
`lz4`**.

| Measurement | LZ4 p50 | LZ4 p95 | PGLZ p50 | PGLZ p95 |
|-------------|---------|---------|----------|----------|
| write_result (`flow_node_instances`) | 0.0 | 1.0 | 0.0 | 1.0 |
| DOA (`data_object_writes` / `data_objects`) | 0.0 | 0.0 | 0.0 | 0.0 |
| publish_message (`messages`) | 0.0 | 0.0 | 0.0 | 0.0 |
| resume `input_token` reads | 0.0 | 1.0 | 0.0 | 0.0 |
| GraphQL `inputToken` / `outputToken` | 13.381 | 17.263 | 12.765 | 17.313 |

On this host the SQL numbers are at clock resolution. Re-run
`mix test.load.hardening` on the target hardware before changing the
default.

## Dev Reset

```bash
mix ecto.reset    # drops, creates, migrates, seeds
```

## Related

- [Error Handling](../handbook/error-handling.md) -- payload-cap HTTP body
- [Deployment](deployment.md) -- production boot commands
- [Environment variables](../cheatsheets/env-vars.cheatmd) -- copy-paste block
