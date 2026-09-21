# Back-Pressure & Capacity Management

The Engine provides three layered defenses against overload.
Each layer is independent and can be enabled or disabled separately.

## Layer 1 — PI Admission Control

Caps the number of concurrent (in-memory) process instances **for new starts
via the public API**. When the cap is reached, new `POST /processes/:model_id/start`
requests receive **503 Service Unavailable** with a `Retry-After: 5` header.

The cap is enforced as a soft pre-check inside `Execution.start_process_instance/1`,
not on the underlying `DynamicSupervisor`. This has two practical consequences:

- **Resume bypasses the cap.** At engine startup, `ResumeRunner` brings every
  `:running` PI back online regardless of `BFE_MAX_CONCURRENT_PIS`. The cap may
  briefly be exceeded while resume is in progress and immediately after; new
  starts via the public API are then rejected until enough PIs terminate to
  bring the active count back below the limit. This is a deliberate v1 choice —
  predictable resume is more valuable than strict cap enforcement during the
  transient boot window.
- **The cap is "soft" under concurrent starts.** Between the active-count check
  and the actual start, a concurrent start can push the count one slot over the
  cap. For v1 PoC scale this overshoot is acceptable.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `BFE_MAX_CONCURRENT_PIS` | `infinity` | Maximum number of concurrent PIs **accepted via new starts**. Set to a positive integer (≥ 1) to enable. The engine refuses to start if the value is ≤ 0. Resume is unaffected by this setting. |

### Sizing guidance

The PI cap should be tuned relative to your DB connection pools and available
memory.

**Dual-pool model:** The engine uses separate connection pools for writes
(`BFE_DB_POOL_SIZE`, production default 100) and reads (`BFE_DB_READ_POOL_SIZE`, production default 50).
Execution writes (PI/FNI lifecycle, message/signal persistence) use the write pool.
GraphQL queries and REST list/get endpoints use the read pool. This prevents heavy
queries from starving execution writes.

- **Write pool `×` 5** — each PI holds a write connection only during
  persistence flushes, so a 100-connection write pool can sustain ~500
  concurrent PIs with headroom.
- **Read pool** — sized for the expected number of concurrent Studio users.
  The default 2:1 write-to-read ratio (100 write / 50 read) reflects the
  typical workload asymmetry. Adjust `BFE_DB_READ_POOL_SIZE` if many
  users query simultaneously.
- **Total connections** — size Postgres with
  `max_connections >= (write + read) * engine_nodes + 20`. Production
  defaults already exceed Postgres's default `max_connections` of 100;
  a single-node install needs at least 170 (recommend 200).
- **Memory** — each PI consumes ~50–200 KB of BEAM heap depending on token
  size and flow complexity. At 1 GB available heap, 5000 PIs is a safe
  upper bound.

### Error response

When capacity is reached, the API returns:

```json
{
  "error": "engine_at_capacity",
  "message": "Maximum concurrent process instances reached",
  "active": 100,
  "limit": 100,
  "retry_after_seconds": 5
}
```

## Layer 2 — Start Rate Limiting

ETS-based token bucket that limits the rate of `POST /processes/:model_id/start`
requests within a sliding window. When the bucket is empty, the API returns
**429 Too Many Requests** with a `Retry-After` header.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `BFE_PI_START_RATE_LIMIT` | `0` (disabled) | Maximum starts per window. Set to a positive integer to enable. |
| `BFE_PI_START_RATE_WINDOW_MS` | `1000` | Window duration in milliseconds. |

The rate limit is **global** (not per-client) and applies only to the start
endpoint. All other routes are unaffected.

### Error response

```json
{
  "error": "rate_limited",
  "message": "Start rate limit exceeded",
  "retry_after_seconds": 1
}
```

## Layer 3 — Overload Signaling

When a PI cap is configured (Layer 1), the engine computes a load level
every 10 seconds:

| Ratio (`active / limit`) | Level | Description |
|---|---|---|
| `< 0.70` | `normal` | Healthy headroom |
| `0.70 – 0.89` | `elevated` | Nearing capacity |
| `≥ 0.90` | `critical` | Near or at capacity |

## Health endpoint

`GET /health` returns **204 No Content**. It does not include a `load` field.

Read load from **`GET /stats`**: `engine.load` is `"normal"`, `"elevated"`, or `"critical"`. When `BFE_MAX_CONCURRENT_PIS` is `infinity` (default), `load` is always `"normal"`.

### EngineOverloaded / EngineRecovered events

On threshold **crossings** (not every tick), the engine publishes events
via the EngineEventBus. These reach all registered event sinks (WebSocket,
console, telemetry, plugins).

**`%Event.EngineOverloaded{}`** — emitted on *upward* transitions
(normal→elevated, elevated→critical, normal→critical):

- `level` — `:elevated` or `:critical`
- `active_process_instances` — current count
- `limit` — configured cap
- `occurred_at` — UTC timestamp

**`%Event.EngineRecovered{}`** — emitted when the load drops back to
`:normal` (elevated→normal, critical→normal). Consumers can use this to
release back-pressure:

- `previous_level` — `:elevated` or `:critical`
- `active_process_instances` — current count
- `limit` — configured cap
- `occurred_at` — UTC timestamp

### Prometheus gauge

The `bfw_engine.process_instance.capacity.ratio` gauge (a value between 0.0 and 1.0)
is emitted every poller tick. Use it for Alertmanager rules:

```yaml
groups:
  - name: bfw-engine
    rules:
      - alert: EngineCapacityHigh
        expr: bfw_engine_pi_capacity_ratio > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Engine PI capacity above 80%"
```

## Combining layers

All three layers compose naturally:

1. Rate limiter fires first (Plug pipeline) — rejects bursts.
2. If a start passes the rate limiter, admission control checks the DynamicSupervisor cap.
3. Overload signaling runs independently on a 10s poller — it signals but never rejects.

Each layer can be configured independently. For example, you might enable
only rate limiting (Layer 2) without a hard cap, or enable the cap without
rate limiting.
