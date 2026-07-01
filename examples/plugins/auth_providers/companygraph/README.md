# CompanyGraph Auth Provider — Example Plugin

Ready-to-copy starting point for building a CompanyGraph-based auth provider
for ThomasTheDaemonEngine.

## What it does

1. **Auth provider** (`on_load`) — Receives a raw bearer token on every
   authenticated request, validates it against the CompanyGraph API (stubbed),
   and maps the CompanyGraph user profile to `%EvilEngine.Types.Identity{}`,
   including engine-specific authorization claims.
2. **Permission seeding** (`on_ready`) — Registers the tool name and a
   permission catalog with CompanyGraph at startup (stubbed), mirroring the
   pattern used by real CompanyGraph integrations.

## Stub token profiles

The stub recognises three token prefixes, each producing a different engine
authorization profile:

| Token prefix | CG role | Engine authorization |
|---|---|---|
| `cg-admin-{id}` | `admin` | Full admin: deploy BPMN/DMN, all lanes, abort/retry all PIs, admin override |
| `cg-deployer-{id}` | `deployer` | Can deploy BPMN/DMN, `lane:Engineering`, abort own PIs |
| `cg-viewer-{id}` | `viewer` | `lane:Operations` only (read-only lane access) |

Any other token is rejected with `{:error, :invalid_token}`.

## CG role → engine claim mapping

| Engine claim | `admin` | `deployer` | `viewer` |
|---|---|---|---|
| `deploy_bpmn` | `true` | `true` | — |
| `deploy_dmn` | `true` | `true` | — |
| `delete_dmn` | `true` | — | — |
| `abort_process_instance` | `"all"` | `"own"` | `"none"` |
| `retry_process_instance` | `"all"` | `"none"` | `"none"` |
| `zeeky_boogie_doog` | `true` | — | — |
| `lane:Engineering` | `true` | `true` | — |
| `lane:Operations` | `true` | — | `true` |
| `lane:Management` | `true` | — | — |

## Permission seeding

Real CompanyGraph integrations register their tool identity and permission
catalog during startup. The example seeds two simple boolean permissions:

| Permission | Meaning |
|---|---|
| `can_deploy_processes` | User may deploy/enable/disable BPMN processes |
| `can_view_instances` | User may view process instance data |

In production, these would be submitted via `POST /api/tools/{tool}/berechtigungen`.
The stub logs the registration and returns `:ok`.

## Usage

1. Copy `lib/companygraph_auth_provider.ex` and `lib/companygraph_plugin.ex`
   into your own OTP application.
2. Replace the stubbed `fetch_companygraph_user/1` with real HTTP calls to
   the CompanyGraph API (or use the `companygraph-elixir` SDK).
3. Replace the stubbed registration functions in `companygraph_plugin.ex`
   with real HTTP calls using an OAuth2 service token.
4. Set `:plugin_module` in your OTP app's application env:

   ```elixir
   config :my_company_plugin, :plugin_module, MyCompany.CompanyGraphPlugin
   ```

5. Add your plugin's OTP app name to `EVIL_PLUGINS_INBEAM`:

   ```
   EVIL_PLUGINS_INBEAM=my_company_plugin
   ```

## Configuration

Configure CompanyGraph connection details in `config/runtime.exs`:

```elixir
config :my_company_plugin, :companygraph,
  api_url: System.get_env("COMPANYGRAPH_API_URL", "https://api.companygraph.com"),
  tenant_id: System.get_env("COMPANYGRAPH_TENANT_ID"),
  service_token: System.get_env("COMPANYGRAPH_SERVICE_TOKEN")
```

## Identity mapping

| CompanyGraph field | Identity field | Notes |
|---|---|---|
| `employee_id` | `id` | Unique user identifier |
| `teams` | `groups` | Used for `<evil:assignees>` matching |
| `roles` | `roles` | Drives engine claim derivation (see table above) |
| `email`, `display_name`, `org_unit` | `claims["email"]`, `claims["name"]`, `claims["org_unit"]` | Informational |
| `custom_attrs` | `claims["companygraph"]` | Passthrough for custom CG attributes |

## Further reading

- [`EvilEngine.Plugin.AuthProvider`](../../../../apps/engine_sdk/lib/evil_engine/plugin/auth_provider.ex)
  — the behaviour your provider must implement.
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md) — full
  plugin system documentation.
- [`docs/architecture/authorization.md`](../../../../docs/architecture/authorization.md) — engine
  authorization model and claim reference.
