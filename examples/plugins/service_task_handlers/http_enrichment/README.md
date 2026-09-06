# HTTP Enrichment Service Task — Example Plugin

Demonstrates a **custom Elixir** Service Task that performs outbound HTTP work and
merges JSON into the token, contrasted with the built-in `implementation="http"`
handler that reads URL, verb, and FEEL expressions from BPMN extensions.

## Async contract

`handle_enter/3` validates inputs synchronously (returns `{:error, ...}` for
missing URL), then spawns a Task for the HTTP call and returns
`{:async, flow_node_instance_id}`. The spawned Task completes or fails the
FNI through the engine facade.

## Prerequisites

- For the default code path, Erlang `:httpc` needs `:inets` started in your release
  (`:inets.start()` or include `:inets` in extra applications).

- Tests use a process-dictionary stub so they stay hermetic; production code can
  rely on `:httpc` or swap in Finch, Req, Mint, or similar inside
  `request_http_get/1`.

## Usage

Copy `lib/` into your OTP app, register the plugin module under `:plugin_module`,
and list the app in `TDE_PLUGINS_INBEAM`. Populate earlier nodes so the token
carries `"enrichment_url"` before this task runs.

## Further reading

- [`EvilEngine.Plugin.ServiceTaskHandler`](../../../../apps/engine_sdk/lib/evil_engine/plugin/service_task_handler.ex)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
