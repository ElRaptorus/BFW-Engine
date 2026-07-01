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

### Sidecar Plugins

Sidecar plugins run as separate OS processes communicating via gRPC over Unix-domain sockets. They are naturally isolated:

- Memory faults in a sidecar do not affect the engine
- The gRPC interface limits what a sidecar can access
- Failed sidecars are restarted with backoff up to `EVIL_PLUGINS_SIDECAR_RECONNECT_LIMIT` (default 5)

## Authorization

Claim-based authorization controls which operations a JWT holder can perform. See [Authentication](../api/authentication.md) for the claim dictionary (`deploy_bpmn`, `delete_process_instance`, `purge_audit_data`, `lane:*`, etc.).

Plugins bypass claim checks (they are within the operator's trust boundary) but are fully audited.

## Telemetry Security

No `EVIL_OTEL_*` or `EVIL_PROMETHEUS_*` variables exist in v1. Telemetry is engine-internal only (`:telemetry` events feeding `/stats`).

## Related

- [Authentication](../api/authentication.md) -- complete JWT and claim reference
- [Deployment](deployment.md) -- production environment setup
- [Observability](observability.md) -- monitoring without external telemetry
