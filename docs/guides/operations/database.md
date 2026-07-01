# Database Administration

The engine requires PostgreSQL 16+ for JSONB support and LZ4 toast compression.

## Connection Configuration

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_DATABASE_URL` | -- | Full connection string (preferred) |
| `EVIL_DATABASE_HOST` | -- | Hostname (alternative to URL) |
| `EVIL_DATABASE_PORT` | `5432` | Port |
| `EVIL_DATABASE_NAME` | -- | Database name |
| `EVIL_DATABASE_USER` | -- | Username |
| `EVIL_DATABASE_PASS` | -- | Password |
| `EVIL_DB_POOL_SIZE` | `20` | Write pool size (PI/FNI lifecycle, deploys, message/signal persistence) |
| `EVIL_DB_READ_POOL_SIZE` | `10` | Read pool size (GraphQL queries, REST list/get endpoints) |
| `EVIL_DB_CHECKOUT_RETRIES` | `3` | DBConnection retries on mid-query disconnect (Layer 1) |
| `EVIL_DB_QUEUE_TARGET` | `100` | CoDel target latency (ms) |
| `EVIL_DB_QUEUE_INTERVAL` | `2000` | CoDel measurement interval (ms) |
| `EVIL_DB_CHECKOUT_TIMEOUT` | `15000` | Max wait for a pool connection (ms) |
| `EVIL_DB_QUEUE_TIME_WARNING_MS` | `500` | Log warning when queue_time exceeds this threshold (ms) |
| `EVIL_DB_IPV6` | `false` | Connect over IPv6 |
| `EVIL_DB_SSL` | `false` | Enable SSL |

`EVIL_DATABASE_URL` takes precedence over individual vars. Both the write pool (`Repo`) and read pool (`ReadRepo`) connect to the same database URL.

### Dual-Pool Architecture

The engine uses two Ecto repos with separate connection pools:

- **Write pool** (`EvilEngine.Persistence.Repo`, `EVIL_DB_POOL_SIZE`) — handles all mutations: PI/FNI state writes, deployments, message/signal persistence, retry orchestration.
- **Read pool** (`EvilEngine.Persistence.ReadRepo`, `EVIL_DB_READ_POOL_SIZE`) — handles all reads: GraphQL queries, REST list/get, Ash read actions.

The 2:1 default (20 write / 10 read) reflects workload asymmetry: tens of thousands of PIs produce massively concurrent writes, while a comparatively small number of Studio users issue read queries. Adjust based on your workload profile.

Ensure PostgreSQL `max_connections` ≥ write pool + read pool + headroom (at least 50; the default is 100).

## Persistence Resilience

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_DB_CHECKOUT_RETRIES` | `3` | DBConnection-level retries on mid-query disconnect (Layer 1) |
| `EVIL_PERSISTENCE_RETRY_MAX_ATTEMPTS` | `5` | Application-level retry attempts per adapter call (Layer 2) |
| `EVIL_PERSISTENCE_RETRY_INITIAL_BACKOFF_MS` | `100` | Initial backoff before first retry; doubles on each attempt (Layer 2) |

Layer 1 handles transparent reconnection at the pool level. Layer 2 (`PersistenceRetry`) wraps all adapter calls with bounded exponential backoff and jitter. Total worst-case retry window: ~3.1s. See `docs/architecture/execution.md` §Persistence Resilience for the fail-fast vs. log-and-continue classification.

## Migration Workflow

Migrations are generated from Ash resource changes, not hand-written:

```bash
# Generate migration from resource diff
mix ash_postgres.generate_migrations --name add_user_task_fields

# Apply migrations
mix ash_postgres.migrate

# Rollback
mix ash_postgres.rollback
```

In production releases:

```bash
bin/evil_engine eval "EvilEngine.Persistence.Release.migrate()"
```

## Key Tables

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

## Partitioning

`process_instance_events` and `data_object_writes` are partitioned by timestamp. At boot, the engine creates partitions for the current and upcoming periods:

```bash
mix evil.partitions.ensure    # dev
bin/evil_engine eval "EvilEngine.Persistence.Release.ensure_partitions()"  # prod
```

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_PARTITION_AHEAD_MONTHS` | `3` | Future partition lead time |

## Retention Policies

All retention is opt-in. A fresh installation never deletes anything.

### Per-Terminal-State PI Retention

| Env Var | Purpose |
|---------|---------|
| `EVIL_RETENTION_FINISHED_DAYS` | Max age for `finished` PIs |
| `EVIL_RETENTION_ERROR_DAYS` | Max age for `error` PIs |
| `EVIL_RETENTION_FATAL_DAYS` | Max age for `fatal` PIs |
| `EVIL_RETENTION_ABORTED_DAYS` | Max age for `aborted` PIs |
| `EVIL_RETENTION_ESCALATED_DAYS` | Max age for `escalated` PIs |
| `EVIL_RETENTION_COMPENSATED_DAYS` | Max age for `compensated` PIs |

PI purge is atomic: a PI's events, FNIs, data objects, and writes are deleted in one transaction.

### Engine Audit Retention

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_RETENTION_ENGINE_AUDIT_DAYS` | -- | Max age for engine audit table rows |

### Runner Configuration

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_RETENTION_RUN_INTERVAL` | `PT1H` | How often the runner wakes |
| `EVIL_RETENTION_BATCH_SIZE` | `500` | Max rows per transaction |

The `RetentionRunner` starts only if at least one `EVIL_RETENTION_*_DAYS` var is set.

### Safety Invariants

- `running` PIs are never touched
- Catalog rows (`processes`, `process_versions`) are never touched
- PIs with running child PIs (Call Activity) are skipped
- Operational rows (`pending_messages.state='pending'`, armed timers) are never retention-eligible

### Manual Purge

Manual purge is planned for a future release. In v1, operators can adjust retention env vars or run direct SQL under the admin DB role for ad-hoc cleanup.

## JSONB Compression

| Env Var | Default |
|---------|---------|
| `EVIL_JSONB_COMPRESSION` | `lz4` |

Applies to new migrations only. Existing data retains its compression until rewritten.

## Dev Reset

```bash
mix ecto.reset    # drops, creates, migrates, seeds
```

## Related

- [Data Objects](../handbook/data-objects.md) -- data object semantics
- [Deployment](deployment.md) -- production boot commands
