# Quarantine demo

Author-facing demonstration of plugin quarantine ([plugins.md](../../../../docs/architecture/plugins.md) §9.3,
[getting-started Failure Handling](../../../../docs/guides/plugins/getting-started.md)).

Engine unit tests already cover Loader quarantine (`L-7`/`L-8` in
`apps/peripheral_plugins/test/evil_engine/plugins/loader_test.exs`). This cookbook
is what plugin authors copy.

## What `on_load` failure does

`QuarantineDemoPlugin.on_load/1` returns `{:error, :intentional_quarantine}` and
registers **nothing** first.

Loader `run_on_load`:

1. `{:error, reason}` → `quarantine/2`
2. Structured log `Plugin <name> quarantined`
3. `Event.PluginQuarantined` (`plugin_name`, `tier: :inbeam`,
   `reason: {:on_load_failed, :intentional_quarantine}`) to every EventSink
   (including [`event_sinks/sse`](../../event_sinks/sse/))
4. Engine boot **continues**
5. No auto-revive — restart the engine after fixing the plugin

Do **not** register a handler and then fail `on_load`. Loader does **not** call
`Registry.unregister_plugin_capabilities/1` on `on_load` failure. Only `on_ready`
failure unregisters capabilities and then quarantines.

## The `on_ready` path (documented, not a second executable plugin)

Successful `on_load` then `on_ready` → `{:error, _}`:

1. `Registry.unregister_plugin_capabilities/1`
2. quarantine
3. `Event.PluginQuarantined` with `{:on_ready_failed, reason}`

See `loader_test.exs` `on_ready` cases.

## Operator surfaces

| Surface | What you see |
|---------|----------------|
| Log | `Plugin <name> quarantined: ...` |
| `Loader.quarantined_plugins/0` | In-memory list (this process) |
| `GET /stats` | plugins block |
| EventSinks | `Event.PluginQuarantined` |

## Usage

This example is intentionally **not** a successful registration. Point
`:plugin_module` at `Examples.Plugins.QuarantineDemo.QuarantineDemoPlugin` and add
the OTP app to `EVIL_PLUGINS_INBEAM` only when you want to watch quarantine on a
scratch engine.

```elixir
config :my_plugin, :plugin_module, Examples.Plugins.QuarantineDemo.QuarantineDemoPlugin
```

## Further reading

- [Getting started — Failure Handling](../../../../docs/guides/plugins/getting-started.md)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md) §9.3
