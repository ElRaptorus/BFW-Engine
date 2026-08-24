# Security

This guide covers authentication, authorization, and trust boundaries for production deployments.

## JWT Configuration

See [Authentication](../api/authentication.md) for the full JWT setup including supported algorithms, claim dictionary, and dev token minting.

### Key Requirements

- **HS256:** `EVIL_JWT_HS256_SECRET` must be at least 32 bytes
- **JWKS:** `EVIL_JWT_JWKS_URL` for RS256/ES256 keys, auto-refreshed every `EVIL_JWKS_REFRESH_SECONDS` (default 3600)
- At least one key source must be configured unless `EVIL_AUTH_DISABLED=true`

### Key Rotation

JWKS keys are refreshed automatically. For HS256, rotate by updating `EVIL_JWT_HS256_SECRET` and restarting. During rotation, temporarily accept both old and new secrets by running two engine instances or using JWKS with both keys.

## Auth Disabled Mode

`EVIL_AUTH_DISABLED=true` disables all JWT verification. The engine logs a warning every 60 seconds. **Do not use in production** — all requests receive an anonymous identity with least-privilege defaults.

## Payload Cap

`EVIL_TOKEN_MAX_BYTES` (default 64 KiB) limits the size of every user-supplied payload. This protects against memory exhaustion from oversized request bodies. See [Error Handling](../handbook/error-handling.md) for the rejection behavior.

## Plugin Trust Boundary

### In-BEAM Plugins

In-BEAM plugins run in the same Erlang VM as the engine. They have unrestricted access to all BEAM processes and memory. **Only deploy plugins from trusted sources.**

The engine provides guardrails:

- Plugin workers run under a per-plugin supervisor inside `peripheral_plugins`
- `on_load` failures quarantine the plugin without crashing the engine
- CI lints prevent plugins from importing Core modules directly

### Sidecar Plugins — deferred (PLUG-D1)

v1 does **not** host sidecar plugins. Crash isolation is OTP-process isolation for in-BEAM plugins, which sit inside the trust boundary.

The post-v1 design (separate OS processes, gRPC over Unix-domain sockets, reconnect limit `EVIL_PLUGINS_SIDECAR_RECONNECT_LIMIT`) is documented in [plugins.md](../../architecture/plugins.md) §9.2.3. Those env vars are reserved no-ops today.

## Authorization

Claim-based authorization controls which operations a JWT holder can perform. See [Authentication](../api/authentication.md) for the claim dictionary (`deploy_bpmn`, `delete_process_instance`, `purge_audit_data`, `lane:*`, etc.).

Plugins bypass claim checks (they are within the operator's trust boundary) but are fully audited.

## Telemetry Security

`GET /metrics` is public Prometheus text, default **on** (`EVIL_METRICS_ENABLED=true`). The scrape is **unauthenticated**. Restrict it at the network edge (firewall, ingress, or bind the engine to a private network). Set `EVIL_METRICS_ENABLED=false` to disable the endpoint (404).

OpenTelemetry does **not** ship. There are no `EVIL_OTEL_*` variables. `/stats` remains JWT-gated.

## Related

- [Authentication](../api/authentication.md) -- complete JWT and claim reference
- [Deployment](deployment.md) -- production environment setup
- [Observability](observability.md) -- monitoring without external telemetry
