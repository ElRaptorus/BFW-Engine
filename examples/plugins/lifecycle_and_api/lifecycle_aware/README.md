# Lifecycle-aware plugin (`on_load` / `on_ready`)

This starter highlights the ordering guarantees described in [`docs/guides/plugins/getting-started.md`](https://github.com/ElRaptorus/BFW-Engine/blob/main/docs/guides/plugins/getting-started.md).

## Phases

| Callback | When it runs | Typical work |
|----------|--------------|--------------|
| `on_load/1` | Core is steady, API sockets are **not** open yet | Register handlers, sinks, timers; read `facade.get_config/1` |
| `on_ready/1` | Every plugin finished `on_load/1` **and** HTTP/WebSocket ports are accepting traffic | Dial partners, confirm catalog rows, warm caches |

## Ordering guarantees

`on_load/1` callbacks run **sequentially** in registration order. The engine waits for each return before moving on. `on_ready/1` executes once **all** `on_load/1` calls have returned, so cross-plugin dependencies see a complete registry.

## Configuration access

`facade.get_config/1` delegates to `Application.get_env(:peripheral_plugins, key)` inside the bundled loader. Set `config :peripheral_plugins, :lifecycle_demo_setting, ...` to provide data you read during `on_load/1`.

## Where to register what

* **Synchronous capabilities** (`register_named_script/2`, `register_service_task_handler/2`, …) belong in `on_load/1` so the registry is complete before traffic arrives.
* **Outbound connectivity checks** (REST pings, file system checks that assume the working directory used by HTTP uploads, etc.) belong in `on_ready/1`.

## Source modules

* [`BfwEngine.Plugin`](https://github.com/ElRaptorus/BFW-Engine/blob/main/apps/engine_sdk/lib/bfw_engine/plugin.ex)
* [`BfwEngine.Plugin.EventSink`](https://github.com/ElRaptorus/BFW-Engine/blob/main/apps/engine_sdk/lib/bfw_engine/plugin/event_sink.ex)

## Tests

Add the modules to an OTP application that depends on `engine_sdk`, then run `mix test test/lifecycle_plugin_test.exs`.
