# Authentication

The engine uses JWT (JSON Web Token) bearer authentication. All authenticated endpoints require an `Authorization: Bearer <token>` header.

## Supported Algorithms

| Algorithm | Config | Use Case |
|-----------|--------|----------|
| HS256 | `EVIL_JWT_HS256_SECRET` | Symmetric, shared secret (min 32 bytes) |
| RS256 / ES256 | `EVIL_JWT_JWKS_URL` | Asymmetric, JWKS endpoint |

Both can coexist — the engine tries JWKS first, then falls back to HS256.

At least one key source must be configured unless `EVIL_AUTH_DISABLED=true`. The engine refuses to start otherwise.

## Configuration

| Env Var | Purpose | Default |
|---------|---------|---------|
| `EVIL_JWT_HS256_SECRET` | Shared secret for HS256 (min 32 bytes) | -- |
| `EVIL_JWT_JWKS_URL` | JWKS endpoint for RS256/ES256 | -- |
| `EVIL_JWKS_REFRESH_SECONDS` | JWKS key refresh interval | `3600` |
| `EVIL_JWT_AUDIENCE` | Expected `aud` claim (optional) | -- |
| `EVIL_JWT_ISSUER` | Expected `iss` claim (optional) | -- |
| `EVIL_AUTH_DISABLED` | Disable JWT verification entirely | `false` |

## Auth Disabled Mode

Setting `EVIL_AUTH_DISABLED=true` disables JWT verification. All requests receive a synthetic anonymous identity with least-privilege defaults. The engine logs a warning every 60 seconds while this mode is active.

**Not suitable for production.**

## Minting Dev Tokens

Two tools are provided for local development:

### Mix Task

```bash
mix evil.mint_token
mix evil.mint_token --sub operator-1 --roles admin,viewer --exp 3600
mix evil.mint_token --claim tenant_id=acme --claim env=staging

# Use with curl
curl -H "Authorization: Bearer $(mix evil.mint_token)" http://localhost:4000/stats
```

### Shell Script (no Elixir needed)

```bash
./scripts/mint-token.sh
./scripts/mint-token.sh '{"sub":"operator-1","roles":["admin","viewer"]}'
```

Both use the same default secret as `docker-compose.yml`.

## JWT Claims

Standard claims:

| Claim | Purpose |
|-------|---------|
| `sub` | Subject identifier (user ID). Falls back to `client_id` or `"unknown"` if absent. |
| `exp` | Expiration time |
| `aud` | Audience (validated if `EVIL_JWT_AUDIENCE` is set) |
| `iss` | Issuer (validated if `EVIL_JWT_ISSUER` is set) |

Engine-specific claims:

| Claim | Values | Purpose |
|-------|--------|---------|
| `deploy_bpmn` | `true` | Permission to deploy BPMN processes via `POST /processes`, enable/disable via `PUT` |
| `delete_bpmn` | `true` | Permission to delete process versions via `DELETE /processes/{model_id}/versions/{ver}` |
| `abort_process_instance` | `"none"`, `"own"`, `"all"` | Scope for aborting process instances |
| `retry_process_instance` | `"none"`, `"own"`, `"all"` | Scope for retrying terminal process instances via `PUT /process-instances/{id}/retry` |
| `delete_process_instance` | `"none"`, `"own"`, `"all"` | Scope for soft-deleting terminal process instances via `DELETE /process-instances/{id}` |
| `lane:<name>` | `true` | Lane-scoped access. Grants visibility to user tasks and FNIs on that lane. Example: `"lane:accounting": true` |
| `zeeky_boogie_doog` | `true` | Admin override — bypasses all visibility and lane restrictions |
| `roles` | `[string]` | Role list (reserved for future use) |
| `groups` | `[string]` | Group memberships (extracted from JWT) |

### Lane Claims

Lane claims follow the pattern `lane:<lane_name>` with a boolean `true` value. They control:

- **User Task visibility** — only tasks on a lane the caller holds appear in queries and can be finished/cancelled (invisible tasks return `404`)
- **Start Event authorization** — starting a process requires a lane claim matching the start event's lane (if laned)
- **Process Instance visibility** — in GraphQL and WebSocket channels, PIs are visible if the caller has lane access to at least one FNI within, or started the PI
- **WebSocket event filtering** — events on `process_instance:*` channels are filtered by lane

See [Authorization Architecture](../../architecture/authorization.md) for the full specification.

## Auth Provider Pluggability

The engine's authentication mechanism is pluggable. By default, the built-in JWT verifier handles all authentication. A plugin can replace it with a custom identity resolution strategy (e.g., an enterprise identity provider, LDAP, or a custom token format).

### How It Works

A plugin implements `EvilEngine.Plugin.AuthProvider` and registers via `facade.register_auth_provider.(module)` during `on_load/1`. The custom provider receives the raw bearer token and returns an `Identity` struct or an error:

```elixir
@behaviour EvilEngine.Plugin.AuthProvider

@impl true
def verify_and_resolve(token) do
  case MyCompanyGraph.validate(token) do
    {:ok, user} ->
      {:ok, %EvilEngine.Types.Identity{
        id: user.id,
        roles: user.roles,
        groups: user.groups,
        claims: %{"sub" => user.id, "deploy_bpmn" => user.can_deploy?}
      }}
    {:error, _reason} ->
      {:error, :invalid_token}
  end
end
```

### Configuration

| Env Var | Values | Default | Description |
|---------|--------|---------|-------------|
| `EVIL_AUTH_PROVIDER` | `builtin`, `plugin` | `builtin` | `builtin` uses the JWT verifier. `plugin` requires a plugin to register a provider; the engine refuses to start if none does. |

Only one auth provider can be active at a time. If multiple plugins register providers, the last one wins. When no plugin registers a provider and `EVIL_AUTH_PROVIDER=builtin`, the built-in JWT provider is used.

See [Plugin Development](../plugins/getting-started.md) for the full plugin lifecycle.

## Retry Claim

The `retry_process_instance` claim controls who can retry failed or aborted PIs via `PUT /process-instances/{id}/retry`:

| Claim Value | Scope |
|-------------|-------|
| `"none"` | Cannot retry any PI (default when claim is absent) |
| `"own"` | Can retry PIs the caller originally started |
| `"all"` | Can retry any PI |

See [Retry and Restart](../handbook/retry-restart.md) for full endpoint documentation.

## Related

- [Security](../operations/security.md) -- production JWT configuration and key rotation
- [User Tasks](../handbook/user-tasks.md) -- assignee claims and lane authorization
- [Retry and Restart](../handbook/retry-restart.md) -- PI retry authorization
- [REST API Reference](rest-reference.md) -- endpoints requiring authentication
- [WebSocket API](websocket.md) -- channel authentication and authorization
- [Plugin Development](../plugins/getting-started.md) -- implementing a custom Auth Provider
