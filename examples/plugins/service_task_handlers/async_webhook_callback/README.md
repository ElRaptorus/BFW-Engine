# Webhook Callback Service Task — Example Plugin

Demonstrates the Service Task async pattern: `handle_enter/3` returns
`{:async, flow_node_instance_id}`, which parks the Flow Node Instance until your
integration calls `facade.service_tasks.finish_async/2` or `fail_async/3`.
All Service Task handlers follow this async-only contract.

## Agent pattern

`WebhookCallbackPlugin` stores the same `EngineFacade` struct you get in `on_load/1`
inside `WebhookCallbackFacadeStore`. Supervised HTTP handlers (or the sample
`WebhookCallbackReceiver`) can later read that struct and invoke the async closures
without reaching into engine internals.

## Further reading

- [`BfwEngine.Plugin.ServiceTaskHandler`](../../../../apps/engine_sdk/lib/bfw_engine/plugin/service_task_handler.ex)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
