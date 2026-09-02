# Persistence Architecture

## Connection Pool Model

The engine uses two Ecto repositories connected to the same PostgreSQL database, each with its own connection pool:

```
┌────────────────────────────────────────────────────────┐
│  GraphQL reads + REST list/get                          │
│  → EvilEngine.Persistence.ReadRepo (pool_size: N₁)     │
├────────────────────────────────────────────────────────┤
│  PI/FNI writes + deploy + retry + resume writes         │
│  → EvilEngine.Persistence.Repo (pool_size: N₂)         │
├────────────────────────────────────────────────────────┤
│  PostgreSQL (max_connections ≥ N₁ + N₂ + headroom)      │
└────────────────────────────────────────────────────────┘
```

### Routing

All 13 Ash resources use a shared router function instead of a hardcoded repo:

```elixir
# In each resource's `postgres do` block:
repo &EvilEngine.Persistence.RepoRouter.repo/2
```

The router dispatches based on the Ash operation type:

| Operation type | Target repo |
|----------------|-------------|
| `:read` | `EvilEngine.Persistence.ReadRepo` |
| `:mutate` | `EvilEngine.Persistence.Repo` |

This means GraphQL queries, REST list/get endpoints, and any `Ash.read` call automatically use the read pool, while `Ash.create`, `Ash.update`, and `Ash.destroy` use the write pool.

**Test mode:** In `MIX_ENV=test`, `RepoRouter` routes all operations to `Repo` because `Ecto.Adapters.SQL.Sandbox` uses per-repo transaction isolation — data written through `Repo` would be invisible to `ReadRepo` within the same test.

**Defense-in-depth:** `ReadRepo` overrides `insert/2` and `insert!/2` to raise `RuntimeError` at runtime, preventing accidental direct writes that bypass the Ash routing layer. Ecto's compile-time `read_only: true` cannot be used because AshPostgres assumes write functions are defined by `Ecto.Repo`.

`mix ecto.migrate` requires a migrations directory for every repo in `ecto_repos`. `priv/read_repo/migrations/` exists empty (`.gitkeep` only) so Mix does not error; DDL lives only under `priv/repo/migrations/`. `Release.migrate/0` treats a missing read-repo directory as zero pending migrations, but Mix does not.

### Default sizing

| Pool | Env var | Default | Rationale |
|------|---------|---------|-----------|
| Write | `EVIL_DB_POOL_SIZE` | 100 | Execution writes are individually fast but massively concurrent |
| Read | `EVIL_DB_READ_POOL_SIZE` | 50 | GraphQL queries are heavier but far less frequent |
| Total | — | 150 | 2:1 write-to-read ratio reflects workload asymmetry |

Size Postgres with `max_connections >= (write + read) * engine_nodes + 20`. Production defaults (100 + 50) already exceed Postgres's default `max_connections` of 100; a single-node install needs at least 170 (recommend 200). `config/dev.exs` and `config/test.exs` keep smaller local/sandbox pools.

### Queue tuning (CoDel)

Both pools use DBConnection's CoDel algorithm for overload shedding:

| Parameter | Env var | Default | Description |
|-----------|---------|---------|-------------|
| Queue target | `EVIL_DB_QUEUE_TARGET` | 100ms | CoDel target latency |
| Queue interval | `EVIL_DB_QUEUE_INTERVAL` | 2000ms | CoDel measurement interval |
| Checkout timeout | `EVIL_DB_CHECKOUT_TIMEOUT` | 15,000ms | Max wait for a connection |
| Checkout retries | `EVIL_DB_CHECKOUT_RETRIES` | 3 | DBConnection Layer 1 retries |

These parameters are applied to both repos via the `db_pool_tuning` config block in `config/runtime.exs`.

## Persistence Retry

All persistence adapter calls are wrapped with `PersistenceRetry.with_retry/3`, which provides bounded exponential backoff on top of DBConnection's checkout retries.

| Parameter | Default | Env var |
|-----------|---------|---------|
| Max attempts | 5 | `EVIL_PERSISTENCE_RETRY_MAX_ATTEMPTS` |
| Initial backoff | 100ms | `EVIL_PERSISTENCE_RETRY_INITIAL_BACKOFF_MS` |

Coverage includes PI/FNI lifecycle, boundary orchestration, resume reads, retry orchestration, and message/signal persistence adapters. See `docs/architecture/execution.md` for the full call-site table.

## Telemetry

### Query metrics

`EvilEngine.Telemetry.DbQueryHandler` attaches to Ecto query telemetry events from both repos and re-emits standardized metrics:

| Metric | Type | Tags |
|--------|------|------|
| `evil_engine.db.query.queue_time_ms` | distribution | `repo` |
| `evil_engine.db.query.total_time_ms` | distribution | `repo` |
| `evil_engine.db.query.count` | counter | `repo` |

A warning log is emitted when `queue_time` exceeds the configurable threshold (`EVIL_DB_QUEUE_TIME_WARNING_MS`, default 500ms).

### Pool metrics

Sampled every 10s by the telemetry poller via `EvilEngine.Telemetry.Measurements.db_pool_stats/0`:

| Metric | Type | Tags |
|--------|------|------|
| `evil_engine.db.pool.size` | last_value | `repo` |
| `evil_engine.db.pool.checked_out` | last_value | `repo` |
| `evil_engine.db.pool.idle` | last_value | `repo` |

### Stats endpoint

`GET /stats` (auth-gated) includes a `dbPools` section with pool sizes per repo:

```json
{
  "dbPools": {
    "write": { "poolSize": 20 },
    "read": { "poolSize": 10 }
  }
}
```

`GET /health` remains a lightweight 204 No Content liveness probe.

## File map

| Module | Path |
|--------|------|
| `EvilEngine.Persistence.Repo` | `apps/peripheral_persistence/lib/evil_engine/persistence/repo.ex` |
| `EvilEngine.Persistence.ReadRepo` | `apps/peripheral_persistence/lib/evil_engine/persistence/read_repo.ex` |
| Write-schema migrations | `apps/peripheral_persistence/priv/repo/migrations/` |
| ReadRepo Mix placeholder (empty) | `apps/peripheral_persistence/priv/read_repo/migrations/` |
| `EvilEngine.Persistence.RepoRouter` | `apps/peripheral_persistence/lib/evil_engine/persistence/repo_router.ex` |
| `EvilEngine.Persistence.ExecutionAdapter` | `apps/peripheral_persistence/lib/evil_engine/persistence/execution_adapter.ex` |
| `EvilEngine.Persistence.ProcessInstancePurge` | `apps/peripheral_persistence/lib/evil_engine/persistence/process_instance_purge.ex` — Mix/eval PI-tree hard-delete; retry cascade |
| `EvilEngine.Persistence.Release` | `apps/peripheral_persistence/lib/evil_engine/persistence/release.ex` — migrate / ensure_partitions / purge_retention |
| `mix evil.retention.purge` | `apps/peripheral_persistence/lib/mix/tasks/evil.retention.purge.ex` |
| `EvilEngine.Persistence.MessagePersistenceAdapter` | `apps/peripheral_persistence/lib/evil_engine/persistence/message_persistence_adapter.ex` |
| `EvilEngine.Persistence.SignalPersistenceAdapter` | `apps/peripheral_persistence/lib/evil_engine/persistence/signal_persistence_adapter.ex` |
| `EvilEngine.Execution.PersistenceRetry` | `apps/core_execution/lib/evil_engine/execution/persistence_retry.ex` |
| `EvilEngine.Telemetry.DbQueryHandler` | `apps/peripheral_telemetry/lib/evil_engine/telemetry/db_query_handler.ex` |

## Replica readiness

The dual-repo architecture is designed to be replica-ready. When a physical read replica is introduced:

1. Point `ReadRepo` at the replica's connection string via a separate `EVIL_DB_READ_URL` env var
2. All read traffic (GraphQL, REST list/get) automatically routes to the replica
3. Write traffic continues using the primary via `Repo`

No code changes are needed — only configuration.
