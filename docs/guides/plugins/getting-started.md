# Plugin Development -- Getting Started

The engine is extensible through a behaviour-based plugin system. This guide covers the plugin lifecycle, loading model, and available extension points.

## The SDK

The `engine_sdk` OTP application re-exports all plugin behaviours and types. Plugin authors depend on this package only — no direct dependency on Core or Peripheral apps.

## Plugin Lifecycle

Every plugin implements `@behaviour EvilEngine.Plugin` and receives two engine-driven callbacks:

| Phase | When | What You May Do |
|-------|------|-----------------|
| `on_load(facade)` | After core is ready, before API sockets open | Register handlers, subscribe to events, read engine info |
| `on_ready(facade)` | After all `on_load` calls complete and API is listening | Work that requires full engine reachability |

`on_load` is invoked **sequentially** in registration order. The engine waits for each plugin's `on_load` to return before proceeding to the next.

### Failure Handling

- Raising in `on_load` or `on_ready` quarantines the plugin
- Returning `{:error, reason}` also quarantines
- An `Event.PluginQuarantined` is emitted to all sinks
- Engine boot continues with remaining plugins
- Quarantined plugins do not auto-revive — restart the engine

## Minimal Example

```elixir
defmodule MyPlugin do
  @behaviour EvilEngine.Plugin

  @impl true
  def on_load(facade) do
    facade.register_event_sink.("my-metrics", MyPlugin.MetricsSink, api_key: "...")
    :ok
  end

  @impl true
  def on_ready(_facade), do: :ok
end
```

## Loading Model

### In-BEAM Plugins

Highest performance. The plugin is an OTP application bundled into the engine release:

1. Add your plugin as a dependency of the engine release
2. Set the plugin module in application env: `config :my_plugin, :plugin_module, MyPlugin`
3. Add the OTP app name to `EVIL_PLUGINS_INBEAM`: `EVIL_PLUGINS_INBEAM=my_plugin`

The plugin's `Application.start/2` should be a no-op stub. Registration happens exclusively through `on_load`.

### Sidecar Plugins

Language-agnostic. The engine discovers plugins in `EVIL_PLUGINS_SIDECAR_DIR` (default `~/.evil/engine/plugins`). Each subdirectory contains a `plugin.toml` manifest:

```toml
name       = "my_datadog_sink"
version    = "1.2.0"
exec       = "./my-datadog-sink"
categories = ["event_sink"]
```

The engine spawns the binary and communicates via gRPC.

### Include / Exclude Lists

| Env Var | Purpose |
|---------|---------|
| `EVIL_PLUGINS_INCLUDE` | Only load listed plugins |
| `EVIL_PLUGINS_EXCLUDE` | Never load listed plugins (wins on conflict) |

## Available Behaviours

| Behaviour | Page |
|-----------|------|
| `EvilEngine.Plugin.ServiceTaskHandler` | [Service Task Handler](service-task-handler.md) |
| `EvilEngine.Plugin.EventSink` | [Event Sink](event-sink.md) |
| `EvilEngine.Plugin.RestApiExtension` | [REST API Extension](api-extension.md) |
| `EvilEngine.Plugin.PersistenceAdapter` | [Persistence Adapter](persistence-adapter.md) |
| `EvilEngine.Plugin.MonitoringPanel` | [Other Behaviours](other-behaviours.md) |
| `EvilEngine.Plugin.TimerSource` | [Other Behaviours](other-behaviours.md) |
| `EvilEngine.Plugin.DataStoreAdapter` | [Other Behaviours](other-behaviours.md) |
| `EvilEngine.Plugin.NamedScript` | [Other Behaviours](other-behaviours.md) |

## Related

- [Engine Facade Reference](engine-facade.md) -- the facade API available in `on_load` and `on_ready`
- [Built-in Plugins](builtin-plugins.md) -- reference implementations
