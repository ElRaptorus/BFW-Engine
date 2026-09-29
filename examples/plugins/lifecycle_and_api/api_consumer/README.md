# API consumer plugin (facade orchestration)

This example mirrors [`test/support/example_plugin.ex`](https://github.com/ElRaptorus/BFW-Engine/blob/main/test/support/example_plugin.ex): stash the `BfwEngine.EngineFacade` in an Agent during `on_load/1`, then spawn asynchronous work from `on_ready/1` when every registration and socket is ready.

The worker code is intentionally verbose. It logs each phase of a plugin-driven deploy/start/query/finish loop using only namespaces from [`BfwEngine.EngineFacade`](https://github.com/ElRaptorus/BFW-Engine/blob/main/apps/engine_sdk/lib/bfw_engine/engine_facade.ex):

| Namespace | Representative calls |
|-----------|----------------------|
| `facade.processes.deploy/1` | Atomic BPMN batch upload (`[%{process_model_id:, version:, xml:, definitions:}, ...]`) |
| `facade.processes.get_latest_version/1` | Resolve the newest `process_version_id` after deploy |
| `facade.processes.start/1` | Keyword list matching `BfwEngine.Execution.ProcessInstance.start_opts/0` |
| `facade.process_instances.get/1` | Inspect PI snapshot (repeat after mutations) |
| `facade.user_tasks.finish/4` | `(flow_node_instance_id, values map, action_id or nil, %Identity{})` — User Tasks only |
| `facade.manual_tasks.confirm/2` | `(flow_node_instance_id, %Identity{})` — no payload; the entered token passes through |
| `facade.service_tasks.finish_async/2` | (Not shown here — see `ExamplePlugin.AsyncEchoHandler`) |
| `facade.flow_node_instances.get/1` | Inspect specific FNIs |
| `facade.data_objects.get/1` | Read DOA state |
| `facade.graphql` | Raw GraphQL escape hatch (unused in this sample) |

Production plugins normally discover the waiting task via `UserTaskCreated` (`flow_node_type` is `user_task` or `manual_task`) and call the matching namespace. This sample finishes a User Task only when:

* you pass `demo_user_task_flow_node_instance_id: ...` to `Worker.start_link/1`, **or**
* you export `API_CONSUMER_DEMO_USER_TASK_FNI_ID` in the shell before boot.

It confirms a Manual Task only when:

* you pass `demo_manual_task_flow_node_instance_id: ...`, **or**
* you export `API_CONSUMER_DEMO_MANUAL_TASK_FNI_ID`.

## Modules

| File | Responsibility |
|------|------------------|
| [`lib/api_consumer_plugin.ex`](lib/api_consumer_plugin.ex) | `on_load/1` + `on_ready/1` |
| [`lib/facade_store.ex`](lib/facade_store.ex) | Agent storing the façade |
| [`lib/api_consumer_worker.ex`](lib/api_consumer_worker.ex) | GenServer demo sequence |

Bundled BPMN lives in [`bpmn/api_demo_process.bpmn`](bpmn/api_demo_process.bpmn).

## Dependencies

`ApiConsumer.Worker` calls `BfwEngine.BPMN.parse_and_validate/1`, so the hosting OTP app must depend on `core_bpmn` in addition to `engine_sdk`.

## Tests

`test/api_consumer_worker_test.exs` stubs every façade closure to avoid needing Ash, PostgreSQL, or a live engine. Copy the tree into an umbrella app before running `mix test`.
