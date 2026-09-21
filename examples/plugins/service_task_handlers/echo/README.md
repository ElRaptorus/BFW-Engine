# Echo Service Task — Example Plugin

Ready-to-copy Service Task handler that returns the token payload inside
the output map under `"input"`.

## Async contract

All Service Task handlers must return `{:async, flow_node_instance_id}`.
This example demonstrates the simplest possible pattern: spawn a Task that
immediately completes the FNI via the engine facade.

## Usage

1. Copy `lib/` into your OTP application and depend on the engine packages.
2. Set `:plugin_module` in application env:

   ```elixir
   config :my_plugin, :plugin_module, Examples.ServiceTaskHandlers.Echo.EchoPlugin
   ```

3. Add your OTP app name to `BFE_PLUGINS_INBEAM`.

## Lifecycle

`on_load/1` stores the facade in `EchoFacadeStore` (for async completion)
and registers the handler under the `"echo"` implementation key.
`on_ready/1` runs after every plugin has finished `on_load/1` and the API
tier is listening.

## BPMN dispatch

The engine reads the standard `implementation` attribute on `<bpmn:serviceTask>`.
The value must match the key used to register the handler in the plugin registry.

## Redis

An in-memory map (or Agent) is **not** a Redis example. If you need Redis, use a
real client in your OTP app. Do not copy a dictionary and call it Redis.

## Further reading

- [Service Task Handler guide](../../../../docs/guides/plugins/service-task-handler.md)
- [`BfwEngine.Plugin.ServiceTaskHandler`](../../../../apps/engine_sdk/lib/bfw_engine/plugin/service_task_handler.ex)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
