# Plugin Development -- Getting Started

The engine is extensible through a behaviour-based plugin system. This guide covers the plugin lifecycle, loading model, and available extension points.

## The SDK

The `engine_sdk` OTP application re-exports all plugin behaviours and types. Plugin authors depend on this package only — no direct dependency on Core or Peripheral apps.

## Plugin Lifecycle

Every plugin implements `@behaviour BfwEngine.Plugin` and receives two engine-driven callbacks:

| Phase | When | What You May Do |
|-------|------|-----------------|
| `on_load(facade)` | After core is ready, before API sockets open | Register handlers, subscribe to events, read engine info |
| `on_ready(facade)` | After all `on_load` calls complete and API is listening | Work that requires full engine reachability |

`on_load` is invoked **sequentially** in registration order. The engine waits for each plugin's `on_load` to return before proceeding to the next.

### Failure Handling

Copy `examples/plugins/lifecycle_and_api/quarantine_demo/` for the author-facing demonstration.

- Raising in `on_load` or `on_ready` quarantines the plugin
- Returning `{:error, reason}` also quarantines (`quarantine_demo` returns `{:error, :intentional_quarantine}` from `on_load` and registers nothing)
- An `Event.PluginQuarantined` is emitted to all sinks (including the SSE cookbook sink)
- Engine boot continues with remaining plugins
- Quarantined plugins do not auto-revive — restart the engine
- `on_ready` failure also calls `BfwEngine.Plugins.Registry.unregister_plugin_capabilities/1` (unlike `on_load` failure)

## Minimal Example

```elixir
defmodule MyPlugin do
  @behaviour BfwEngine.Plugin

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

From the Engine repository root:

```bash
mix bfw.gen.plugin sample_plugin
```

That writes `plugins/sample_plugin` and runs `mix bfw.plugin.add`, which edits `host/mix.exs` and `config/config.exs`. The task prints `BFE_PLUGINS_INBEAM=sample_plugin`. Set that variable before starting the release. The plugin is not started until the variable is set.

`mix bfw.plugin.add --path plugins/sample_plugin` wires an existing plugin the same way. Both tasks require `igniter`.

The generated `Application.start/2` only stores `:plugin_module` and starts an empty supervisor. Registration happens exclusively through `on_load`. After a restart, `handle_enter/3` is not called again for a parked Service Task. Call `facade.service_tasks.list_waiting.(["your_implementation"])` from `on_ready` and finish or fail each row yourself.

### Other languages

For non-Elixir work, use:

- the built-in HTTP Service Task,
- the public REST / GraphQL / WebSocket API, or
- an in-BEAM plugin that execs a local interpreter (`python_script` / `node_script` under `examples/plugins/service_task_handlers/`).

### Include / Exclude Lists

| Env Var | Purpose |
|---------|---------|
| `BFE_PLUGINS_INCLUDE` | Only load listed plugins |
| `BFE_PLUGINS_EXCLUDE` | Never load listed plugins (wins on conflict; a name in both lists is rejected as `:ambiguous_policy`) |

## Available Behaviours

| Behaviour | Page |
|-----------|------|
| `BfwEngine.Plugin.ServiceTaskHandler` | [Service Task Handler](service-task-handler.md) |
| `BfwEngine.Plugin.EventSink` | [Event Sink](event-sink.md) |
| `BfwEngine.Plugin.RestApiExtension` | [REST API Extension](api-extension.md) |
| `BfwEngine.Plugin.NamedScript` | [Other Behaviours](other-behaviours.md) |
| `BfwEngine.Plugin.AuthProvider` | [Other Behaviours](other-behaviours.md) |

## Related

- [Engine Facade Reference](engine-facade.md) -- the facade API available in `on_load` and `on_ready`
- [Built-in Plugins](builtin-plugins.md) -- reference implementations
- Cookbook: `echo`, `structured_logger`, `sse`, `quarantine_demo`, `python_script`, `node_script` — see `examples/plugins/`
