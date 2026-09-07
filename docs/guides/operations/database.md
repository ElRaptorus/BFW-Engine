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
| `process_instance_events` | Typed event audit log (partitioned, legacy — built-in DB sink removed) |
| `gateway_pending_arrivals` | Pending gateway join tokens |
| `timer_start_schedules` | Cycle Timer Start Event schedules |
| `messages` / `pending_messages` | Published messages and pending-message hold |
| `signals` / `pending_signals` | Published signals and pending-signal hold |
| `decision_definitions` / `decision_versions` | DMN catalog |

There are **no** `escalations`, `compensations`, `engine_timers`, or `pending_escalations` tables. Escalation and compensation observability is EngineEventBus plus in-memory registries. PI-scoped catch/boundary timers persist in FNI `type_properties` plus Scheduler ETS.

## Partitioning

`process_instance_events` and `data_object_writes` are partitioned by timestamp. At boot, the engine creates partitions for the current and upcoming periods:

```bash
mix evil.partitions.ensure    # dev
bin/evil_engine eval "EvilEngine.Persistence.Release.ensure_partitions()"  # prod
```

| Env Var | Default | Purpose |
|---------|---------|---------|
| `TDE_PARTITION_AHEAD_MONTHS` | `3` | Future partition lead time |

## Retention Policies

Pass A is `mix evil.retention.purge` (cron/systemd) or `bin/evil_engine eval "EvilEngine.Persistence.Release.purge_retention()"`. Unset `TDE_RETENTION_*_DAYS` → the task is a no-op. There is no RetentionRunner GenServer.

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
| `TDE_RETENTION_ENGINE_AUDIT_DAYS` | Unused engine convention for the Pass B SQL cutoff below |
| `TDE_PENDING_MESSAGES_KEEP_AFTER_TRANSITION` | `false` = destroy pending message rows on deliver/expire/cancel |
| `TDE_PENDING_SIGNALS_KEEP_AFTER_TRANSITION` | Same for pending signals |

### Safety Invariants

- Only **root** PIs are selection keys. Skip the root if any descendant is `running` or `suspended`.
- Catalog rows (`processes`, `process_versions`) are never touched.
- Do not touch `messages` / `signals` / `pending_*` / `timer_start_schedules` from Pass A.
- Operational rows (`pending_messages.state='pending'`, `pending_signals.state='pending'`) are never Pass B eligible.
- REST `DELETE /process-instances/{id}` remains soft-delete of one PI + FNIs.

### Pass B — operator SQL (engine-audit tables)

Do **not** DELETE `timer_start_schedules`. Substitute `:cutoff` with `now() - make_interval(days => <TDE_RETENTION_ENGINE_AUDIT_DAYS>)` (or a literal timestamptz). Never delete `state = 'pending'`.

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

Boot-time `mix evil.partitions.ensure` only **creates** upcoming partitions. It is not a `pg_partman` replacement. For long-uptime nodes and for `DETACH`/`DROP` of old partitions, run `pg_partman` (or equivalent) on `process_instance_events`, `data_object_writes`, `messages`, `pending_messages`, `signals`, and `pending_signals`.

### Manual Purge REST

REST/CLI `purge` is deferred / not v1 (`purge_audit_data` unused). Ad-hoc PI-tree cleanup uses the Mix task with a temporarily low days knob, or SQL under the admin DB role.

## JSONB Compression

| Env Var | Default |
|---------|---------|
| `TDE_JSONB_COMPRESSION` | `lz4` |

Applies to new migrations only. Existing data retains its compression until rewritten (`ALTER … SET COMPRESSION` plus `UPDATE col = col`).

### LZ4 vs PGLZ measurements

From `mix test.load.hardening` on 2026-09-07 (report `test/load/reports/20260907T115201Z.json`, stdout `[BENCH] jsonb_gate …`). SQL p50/p95 are `query_time_ms` **integer milliseconds** (0 vs 1 is clock resolution). GraphQL is HTTP wall-clock in milliseconds (30 samples after Absinthe warmup). `pg_column_size` sum was identical (`lz4=7335936` / `pglz=7335936`). The 10 % gate did **not** flunk; the default stays `lz4`. The suite does not flip `TDE_JSONB_COMPRESSION`.

| Measurement | LZ4 p50 | LZ4 p95 | PGLZ p50 | PGLZ p95 | Source report |
|-------------|---------|---------|----------|----------|---------------|
| write_result (`flow_node_instances`) | 0.0 | 1.0 | 0.0 | 1.0 | `20260907T115201Z` stdout |
| DOA (`data_object_writes` / `data_objects`) | 0.0 | 0.0 | 0.0 | 0.0 | `20260907T115201Z` stdout |
| publish_message (`messages`) | 0.0 | 0.0 | 0.0 | 0.0 | `20260907T115201Z` stdout |
| resume `input_token` reads | 0.0 | 1.0 | 0.0 | 0.0 | `20260907T115201Z` stdout |
| GraphQL `inputToken` / `outputToken` | 13.381 | 17.263 | 12.765 | 17.313 | `20260907T115201Z` stdout + `jsonb_*_graphql_tokens` |

## Dev Reset

```bash
mix ecto.reset    # drops, creates, migrates, seeds
```

## Related

- [Data Objects](../handbook/data-objects.md) -- data object semantics
- [Deployment](deployment.md) -- production boot commands
