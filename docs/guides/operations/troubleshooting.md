# Troubleshooting

Common issues and their solutions.

## Engine Won't Start

**Symptom:** Boot crashes immediately.

**Checks:**
- `TDE_DATABASE_URL` (or individual DB vars) is set and the database is reachable
- `TDE_HTTP_SECRET_KEY_BASE` is set and at least 64 characters (generate with `mix phx.gen.secret`)
- At least one of `TDE_JWT_HS256_SECRET` or `TDE_JWT_JWKS_URL` is set (or `TDE_AUTH_DISABLED=true`)
- PostgreSQL version is 16+ (required for JSONB + LZ4)

## Authentication Failures (401)

**Checks:**
- JWT is not expired (`exp` claim)
- The signing key matches what the engine expects (`TDE_JWT_HS256_SECRET` or JWKS endpoint)
- `TDE_JWT_AUDIENCE` / `TDE_JWT_ISSUER` match the token's `aud` / `iss` if set
- `TDE_AUTH_DISABLED` is not accidentally `true` in production (check for the 60s warning log)

Mint a fresh token: `mix evil.mint_token` or `./scripts/mint-token.sh`.

## 413 Payload Too Large

**Cause:** Request payload exceeds `TDE_TOKEN_MAX_BYTES` (default 64 KiB).

**Fix:** If the payload size is legitimate, increase `TDE_TOKEN_MAX_BYTES`. The minimum is 1024 bytes; there is no maximum.

See [Error Handling](../handbook/error-handling.md) for the error response shape.

## Process Deploy Fails (422)

**Checks:**
- The BPMN file includes `<evil:version>` as an extension element inside `<bpmn:extensionElements>`
- Structural validation passes (valid XML, executable process, no dead ends)
- If `TDE_LINTER_GATE` is configured, check the `failures` array in the response for specific rule violations

See [Deploying Processes](../handbook/deploying-processes.md).

## User Task Completion Fails

**Checks:**
- The FNI is in `waiting` state (not already finished, aborted, or interrupted)
- If the task has an `evil:resultContract`, the result JSON matches the JSON Schema exactly
- The caller's JWT has the necessary claims for lane-based assignment

A `evil:resultContract` mismatch returns **HTTP 422** and the FNI stays in `waiting` — the process instance stays running. The caller can correct the payload and retry. See [User Tasks](../handbook/user-tasks.md).

## FNI in Fatal State

**Checks:**
- Review engine logs for the handler error (search for the `flow_node_instance_id`)
- For Service Tasks: check that the plugin handler is registered for the correct `implementation` key
- For HTTP Service Tasks: check that the target URL is reachable and the response is valid JSON

See [Service Tasks](../handbook/service-tasks.md).

## Event Sinks Not Receiving Events

**Checks:**
- Verify the sink's env var toggle is `on` (e.g., `TDE_EVENT_SINK_WEBSOCKET=on`)
- Check the min-severity setting — events below the floor are dropped
- Check `/stats` for `listeners.event_sinks_count` — it should match expected sink count (three built-in sinks: console, telemetry, websocket)

See [Observability](observability.md).

## Plugin Quarantined

**Symptom:** `/stats` shows a quarantined plugin.

**Checks:**
- Review logs for `PluginQuarantined` event with the failure reason
- `on_load` may have raised or returned `{:error, reason}`
- For in-BEAM: verify the OTP app is in the release and `:plugin_module` is set in app env
- Sidecar plugins are **not in v1** (PLUG-D1). `TDE_PLUGINS_SIDECAR_*` env vars do nothing; a missing sidecar binary is not a v1 failure mode.

Quarantined plugins do not auto-revive — restart the engine after fixing the issue.

## Database Connection Issues

**Checks:**
- `TDE_DATABASE_URL` or individual vars point to a running PostgreSQL instance
- `TDE_DB_POOL_SIZE` is appropriate for the workload (production default 100 write / 50 read)
- If using SSL, set `TDE_DB_SSL=true`
- Check PostgreSQL max connections setting

## Resume Not Working After Restart

The engine auto-resumes all `running` PIs at startup via `ResumeRunner`. If PIs are not resuming:

- Check that the persistence adapter is configured (`config :core_execution, :persistence_adapter`)
- Review logs for `ResumeRunner` errors
- Verify the database contains PI rows with `state = "running"`

## Related

- [Deployment](deployment.md) -- environment setup
- [Error Handling](../handbook/error-handling.md) -- error states and payload cap
- [Observability](observability.md) -- monitoring and event pipeline
