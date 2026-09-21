# LDAP Auth Provider — Example Plugin

This is a **contract tutorial**, not a production LDAP client. Token verification
is stubbed (`valid-ldap-{id}`). Replace `ldap_bind_and_lookup/1` with `:eldap` or
`exldap` before using it against a real directory.

Ready-to-copy starting point for building an LDAP-based `AuthProvider` for
Bifrost Forge World Engine.

## What it does

1. Receives a raw bearer token on every authenticated request.
2. Verifies the token against an LDAP directory (stubbed in this example).
3. Maps the LDAP user record to `%BfwEngine.Types.Identity{}`.

## Usage

1. Copy `lib/ldap_auth_provider.ex` and `lib/ldap_plugin.ex` into your own
   OTP application.
2. Replace the stubbed `ldap_bind_and_lookup/1` with real LDAP calls (e.g.
   using the `:eldap` module or a library like `exldap`).
3. Set `:plugin_module` in your OTP app's application env:

   ```elixir
   config :my_company_plugin, :plugin_module, MyCompany.LdapPlugin
   ```

4. Add your plugin's OTP app name to `BFE_PLUGINS_INBEAM`:

   ```
   BFE_PLUGINS_INBEAM=my_company_plugin
   ```

## Configuration

Configure LDAP connection details in `config/runtime.exs`:

```elixir
config :my_company_plugin, :ldap,
  host: System.get_env("LDAP_HOST", "ldap.corp.example.com"),
  port: String.to_integer(System.get_env("LDAP_PORT", "636")),
  base_dn: System.get_env("LDAP_BASE_DN", "dc=corp,dc=example,dc=com")
```

## Identity mapping

| LDAP attribute | Identity field |
|---------------|----------------|
| `uid` | `id` |
| `memberOf` groups | `roles`, `groups` |
| All raw attributes | `claims["ldap_attrs"]` |

## Further reading

- [Getting Started](../../../../docs/guides/plugins/getting-started.md) — plugin lifecycle and `BFE_PLUGINS_INBEAM`
- [`BfwEngine.Plugin.AuthProvider`](../../../../apps/engine_sdk/lib/bfw_engine/plugin/auth_provider.ex)
  — the behaviour your provider must implement.
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md) — full
  plugin system documentation.
