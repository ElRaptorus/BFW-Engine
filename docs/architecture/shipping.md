---
title: "Evil Engine — Shipping & Deployment"
parent_document: "../ImplementationPlan.md"
---

<!--
  Split from packaging.md (ImplementationPlan.md §14).
  For configuration (env vars, linter gate, retention), see configuration.md.
-->

## 14.1 Docker

- **Base**: `debian:12-slim`.
- **Build stage**: `hexpm/elixir:1.17.x-erlang-27.x-debian-bookworm-slim` → `mix release`.
- **Run stage**: debian-slim + release artifact + runtime deps (openssl, ncurses).
- Healthcheck: `curl -f http://localhost:4000/health || exit 1`.
- Size target: ≤ 120 MB compressed.

## 14.2 docker-compose (local dev)

Two services only:

- `engine` service (image built from repo)
- `postgres:16` with volume

No tracing / metrics sidecars in v1.

## 14.4 Zero-downtime deploy options

- **Blue/green** (recommended): run two engines on different ports, swap reverse-proxy. Old engine drains PIs via `Abort(drain: true)` is not used — instead old engine stops accepting new PIs, finishes live ones, then exits.
- **Hot-code-upgrade**: OTP release upgrades via `:appup`/`:relup`. Documented but treated as advanced (requires discipline per migration).

---

## See also

- [configuration.md](configuration.md) — env vars table, linter-score deploy gate, database housekeeping and retention
- [security.md](security.md) — transport security (TLS termination at reverse-proxy level)
