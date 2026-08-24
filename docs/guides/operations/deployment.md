# Deployment

This guide covers building and deploying the engine for production use.

## Release Build

```bash
MIX_ENV=prod mix release
```

The release is output to `_build/prod/rel/evil_engine/`. Start it with:

```bash
_build/prod/rel/evil_engine/bin/evil_engine start
```

## Docker

The `docker/Dockerfile` produces a `debian:12-slim` image. For local development:

```bash
docker compose up --build
```

- Engine (HTTP, GraphQL, WebSocket): `http://localhost:4000`
- PostgreSQL: `localhost:5432`

## Required Environment Variables

| Env Var | Description |
|---------|-------------|
| `EVIL_DATABASE_URL` | PostgreSQL connection string (or use individual `EVIL_DATABASE_*` vars) |
| `EVIL_HTTP_SECRET_KEY_BASE` | Phoenix secret (min 64 chars, generate with `mix phx.gen.secret`) |
| JWT key | At least one of `EVIL_JWT_HS256_SECRET` or `EVIL_JWT_JWKS_URL` (unless `EVIL_AUTH_DISABLED=true`) |

For the complete environment variable reference, see the copy-paste block in the architecture configuration documentation.

## Boot Sequence

1. **Migrations** -- apply pending database migrations
2. **Partitions** -- create missing audit table partitions
3. **Core startup** -- execution runtime, BPMN parser, event bus
4. **Plugin loading** -- sequential `on_load` for each registered plugin
5. **API sockets** -- HTTP and WebSocket listeners bind
6. **Plugin ready** -- `on_ready` for each plugin
7. **Resume** -- `ResumeRunner` restores all previously-running PIs

### Production Boot Commands

```bash
# Apply migrations
bin/evil_engine eval "EvilEngine.Persistence.Release.migrate()"

# Create partitions
bin/evil_engine eval "EvilEngine.Persistence.Release.ensure_partitions()"

# Start the engine
bin/evil_engine start
```

## Health Probes

`GET /health` requires no authentication and returns **204 No Content**. It is suitable for Kubernetes liveness/readiness probes (status code only). For load and pool stats, use authenticated `GET /stats`.

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 4000
readinessProbe:
  httpGet:
    path: /health
    port: 4000
```

## Seeding Directory

Set `EVIL_SEEDING_DIRECTORY` to auto-deploy `.bpmn` files at startup. Failing files are skipped without halting boot. See [Deploying Processes](../handbook/deploying-processes.md).

## Ports

| Env Var | Default | Purpose |
|---------|---------|---------|
| `EVIL_HTTP_PORT` | `4000` | HTTP, GraphQL, and WebSocket |

## FEEL NIF Scheduler Tuning

The FEEL expression engine runs as a Rust NIF. Precompiled expression
evaluation (`eval_compiled`) runs on normal BEAM schedulers. Expression
compilation and one-shot evaluation run on dirty CPU schedulers.

For DMN-heavy deployments (many concurrent Business Rule Task evaluations
or ad-hoc decision evaluations), consider tuning dirty scheduler counts
in `rel/vm.args.eex`:

```
+SDcpu 16:16   # Increase if `compile` calls saturate during deploy spikes
```

Monitor dirty scheduler utilization with `:recon.scheduler_usage/1` in a
remote console. See `docs/architecture/expressions.md` §8.3.1 for the
full NIF scheduling analysis including mutex contention behavior.

## Related

- [Database Administration](database.md) -- PostgreSQL setup and migrations
- [Security](security.md) -- JWT and authentication configuration
- [Observability](observability.md) -- monitoring and event sinks
- [Authentication](../api/authentication.md) -- JWT setup details
