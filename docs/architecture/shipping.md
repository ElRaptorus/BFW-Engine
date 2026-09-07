# Shipping

Docker image layout and local compose. Operator how-to: [deployment.md](../guides/operations/deployment.md). Env vars, linter gate, and retention: [configuration.md](configuration.md).

## Docker

The production image is `docker/Dockerfile`.

- **Base / run stage**: `debian:bookworm-slim` plus the OTP release, openssl, ncurses.
- **Build stage**: `hexpm/elixir` (currently Elixir 1.19.5 / OTP 28.5 on bookworm) → `mix release`. Local development uses `.tool-versions` (Elixir 1.20.3 / OTP 29.0.5).
- Healthcheck: `curl -f http://localhost:4000/health` expects **HTTP 204**, empty body.
- Size target: ≤ 120 MB compressed.

## docker-compose (local dev)

Two services:

- `engine` (image built from the repo)
- `postgres:16` with a volume, started as `postgres -c max_connections=200`

Production pool defaults (`TDE_DB_POOL_SIZE` 100 + `TDE_DB_READ_POOL_SIZE` 50) exceed Postgres's default `max_connections` of 100. Both compose files raise the limit; CI Docker smoke does the same. Do not start a production-pool engine against an unmodified `postgres:16-alpine`.

There is no tracing sidecar and no metrics sidecar. Prometheus scrape is the engine's own `GET /metrics`.

## Zero-downtime deploy

- **Blue/green** (recommended): run two engines on different ports, swap the reverse-proxy. Stop the old engine from accepting new process instances, let live ones finish, then exit.
- **Hot-code-upgrade**: OTP release upgrades via `:appup`/`:relup`. Advanced; requires discipline per migration.

---

## See also

- [configuration.md](configuration.md) — env vars, linter-score deploy gate, database housekeeping
- [security.md](security.md) — transport security (TLS termination at the reverse proxy)
- [deployment.md](../guides/operations/deployment.md) — release build, plugin bundling, cron
