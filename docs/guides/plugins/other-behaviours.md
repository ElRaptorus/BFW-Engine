# Additional Plugin Behaviours

Beyond Service Task handlers, Event Sinks, and REST API extensions, the engine ships two more live capability types: **NamedScript** and **AuthProvider**.

PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities **do not exist** — do not register them. Execution persistence is `EvilEngine.Execution.Persistence` (config `:core_execution, :persistence_adapter`). BPMN DataStores are a parser no-op.

## NamedScript

Handles `<evil:scriptRef>` execution for a specific script key. Unique by key. The engine dispatches to the registered module when a Script Task has a matching `evil:scriptRef` value. Scripts are always synchronous — no handler parking.

```elixir
@behaviour EvilEngine.Plugin.NamedScript

@callback handle_enter(flow_node :: map(), payload :: map(), context :: map()) ::
            {:ok, map()} | {:error, term()}
```

The `flow_node` map includes `type_data` with `script_format`, `script`, `script_ref`, and other Script Task fields. The `payload` is the token payload after input mappings have been applied. The `context` contains the standard handler context (process model, identity, data objects, etc.).

Registration:

```elixir
facade.register_named_script.("my_validation", MyPlugin.CustomScript)
```

## AuthProvider

Replaces the built-in JWT verifier. Unique (singleton, first-writer wins). A second plugin that registers another provider receives `{:error, :conflict, incumbent_plugin_name}` and is quarantined. If no plugin registers a provider, the built-in JWT provider in `api_auth` is used.

```elixir
@behaviour EvilEngine.Plugin.AuthProvider

@callback verify_and_resolve(token :: String.t()) ::
            {:ok, EvilEngine.Types.Identity.t()} | {:error, term()}
```

Called on every authenticated HTTP request and WebSocket connection. Must be reasonably fast and must not have side effects.

Registration:

```elixir
def on_load(facade) do
  facade.register_auth_provider.(MyPlugin.CompanyGraphAuth)
  :ok
end
```

See `examples/plugins/auth_providers/` for LDAP and CompanyGraph starting points.

## Related

- [Getting Started](getting-started.md) -- plugin lifecycle and loading
- [Engine Facade Reference](engine-facade.md) -- registration API
