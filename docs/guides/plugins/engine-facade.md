# Engine Facade Reference

The `%EvilEngine.EngineFacade{}` struct is passed to every plugin's `on_load/1` and `on_ready/1` callbacks. It provides a stable, read-only surface for plugins to interact with the engine without reaching into internal modules.

PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities **do not exist** — do not register them.

## Fields

### Read-Only Identity

| Field | Type | Description |
|-------|------|-------------|
| `engine_id` | `String.t()` | Value of `TDE_ENGINE_ID` |
| `engine_name` | `String.t()` | Value of `TDE_ENGINE_NAME` |
| `version` | `String.t()` | Release version string |

### Capability Registration

Each function registers a specific capability type in the Plugin Registry. Registration closures return `registration_result()` (`:ok | {:error, :conflict, incumbent} | {:error, :invalid_handler, msg} | {:error, :module_not_loaded, msg} | {:error, :reserved_prefix}`).

| Field | Signature | Description |
|-------|-----------|-------------|
| `register_service_task_handler` | `(implementation :: String.t(), handler :: module()) -> registration_result()` | Registers a Service Task handler keyed by implementation string |
| `register_named_script` | `(script_key :: String.t(), handler :: module()) -> registration_result()` | Registers a Named Script handler keyed by script key |
| `register_rest_api_extension` | `(prefix :: String.t(), handler :: module()) -> registration_result()` | Registers a REST API extension keyed by URL prefix |
| `register_auth_provider` | `(handler :: module()) -> registration_result()` | Registers an Auth Provider (unique, first-writer wins) |
| `register_event_sink` | `(name :: String.t(), module(), keyword()) -> :ok \| {:error, term()}` | Registers an Event Sink with the EngineEventBus |

### Infrastructure

| Field | Signature | Description |
|-------|-----------|-------------|
| `publish_event` | `(Event.t()) -> :ok` | Publish a typed event to the `EngineEventBus` |
| `get_config` | `(atom()) -> term()` | Read `Application.get_env(:peripheral_plugins, key)` only |

### Resource-Scoped Runtime Namespaces

Runtime operations are grouped by the resource they operate on. Each namespace is a sub-struct with typed closures wired to `EvilEngine.Api` functions (`skip_claims: true`).

| Namespace | Type | Description |
|-----------|------|-------------|
| `processes` | `EngineFacade.Processes.t()` | Catalog reads + writes for Process Models / Versions |
| `process_instances` | `EngineFacade.ProcessInstances.t()` | Runtime commands on Process Instances |
| `user_tasks` | `EngineFacade.UserTasks.t()` | User Task finish / cancel |
| `service_tasks` | `EngineFacade.ServiceTasks.t()` | Async Service Task complete / fail |
| `flow_node_instances` | `EngineFacade.FlowNodeInstances.t()` | Flow Node Instance reads |
| `data_objects` | `EngineFacade.DataObjects.t()` | Data Object reads + history |
| `decisions` | `EngineFacade.Decisions.t()` | Decision Model catalog + evaluation |
| `messages` | `EngineFacade.Messages.t()` | Message publish |
| `signals` | `EngineFacade.Signals.t()` | Signal broadcast (no payload, no correlation) |
| `escalations` | `EngineFacade.Escalations.t()` | Escalation inject into waiting catchers |
| `adhoc_subprocesses` | `EngineFacade.AdhocSubprocesses.t()` | Ad-hoc subprocess control |
| `timers` | `EngineFacade.Timers.t()` | Timer event trigger + cycle schedule list/enable/disable |
| `graphql` | `EngineFacade.Graphql.t()` | Raw GraphQL query execution (query-only) |

#### `facade.processes`

| Function | Signature | Description |
|----------|-----------|-------------|
| `list` | `() -> {:ok, list()} \| {:error, term()}` | List all process definitions |
| `get` | `(String.t()) -> {:ok, struct()} \| :not_found` | Get a process by model ID |
| `get_latest_version` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Get the latest version for a process model |
| `deploy` | `([map()]) -> {:ok, [map()]} \| {:error, term()}` | Deploy parsed BPMN sources |
| `enable` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Enable a process |
| `disable` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Disable a process |
| `delete_version` | `(String.t(), String.t()) -> {:ok, struct()} \| {:error, term()}` | Soft-delete a specific version |
| `undeploy` | `(String.t()) -> :ok \| {:error, term()}` | Soft-delete all versions of a process |
| `start` | `(keyword()) -> {:ok, String.t()} \| {:error, term()}` | Start a new process instance |

#### `facade.process_instances`

| Function | Signature | Description |
|----------|-----------|-------------|
| `get` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Get a PI by ID |
| `abort` | `(String.t(), String.t() \| nil) -> :ok \| {:error, term()}` | Abort a running PI (tree-wide) |
| `retry` | `(String.t(), map()) -> :ok \| {:error, term()}` | Retry a terminal PI (`fatal`, `aborted`, or `error`) |
| `delete` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Soft-delete a PI and its FNIs |

#### `facade.user_tasks`

Elixir arity is `(flow_node_instance_id, result | reason, identity)` — there is no process-instance ID argument.

The TypeScript `EngineFacade.userTasks` methods still take `processInstanceId` as the first argument. That extra argument is a TypeScript client/SDK convention; the Elixir facade does not use it.

| Function | Signature | Description |
|----------|-----------|-------------|
| `finish` | `(flow_node_instance_id, result, identity) -> :ok \| {:error, term()}` | Finish a waiting User Task with a result payload |
| `cancel` | `(flow_node_instance_id, reason, identity) -> :ok \| {:error, term()}` | Cancel a waiting User Task |

#### `facade.service_tasks`

| Function | Signature | Description |
|----------|-----------|-------------|
| `finish_async` | `(fni_id, result) -> :ok \| {:error, term()}` | Complete a parked async Service Task FNI |
| `fail_async` | `(fni_id, error_code, error_message) -> :ok \| {:error, term()}` | Fail a parked async Service Task FNI |

#### `facade.flow_node_instances`

| Function | Signature | Description |
|----------|-----------|-------------|
| `get` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Get a single FNI by UUID |
| `list_for_process_instance` | `(String.t()) -> {:ok, list()} \| {:error, term()}` | List FNIs for a process instance |

#### `facade.data_objects`

| Function | Signature | Description |
|----------|-----------|-------------|
| `get` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Get a single Data Object value |
| `list_for_instance` | `(String.t()) -> {:ok, list()} \| {:error, term()}` | Current values for a PI |
| `history_for_instance` | `(String.t()) -> {:ok, list()} \| {:error, term()}` | Full audit trail for a PI |

#### `facade.decisions`

| Function | Signature | Description |
|----------|-----------|-------------|
| `list` | `() -> {:ok, list()} \| {:error, term()}` | List all decision definitions |
| `get` | `(String.t()) -> {:ok, struct()} \| :not_found` | Get a decision by model ID |
| `get_latest_version` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Latest non-deleted version |
| `validate` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Parse and validate DMN XML without persisting |
| `deploy` | `([String.t()]) -> {:ok, [map()]} \| {:error, term()}` | Deploy DMN XML sources |
| `evaluate` | `(model_id, input, opts) -> {:ok, struct()} \| {:error, term()}` | Evaluate a decision ad-hoc |
| `evaluate_by_version` | `(model_id, version, input, opts) -> {:ok, struct()} \| {:error, term()}` | Evaluate a specific version |
| `evaluate_service` | `(model_id, service_id, input, opts) -> {:ok, struct()} \| {:error, term()}` | Evaluate a Decision Service |
| `get_versions` | `(String.t()) -> {:ok, list()} \| {:error, term()}` | List versions |
| `get_xml` | `(String.t()) -> {:ok, String.t()} \| {:error, term()}` | Latest version XML |
| `enable` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Enable a definition |
| `disable` | `(String.t()) -> {:ok, struct()} \| {:error, term()}` | Disable a definition |
| `delete_version` | `(String.t(), String.t()) -> {:ok, struct()} \| {:error, term()}` | Soft-delete a version |
| `undeploy` | `(String.t()) -> :ok \| {:error, term()}` | Soft-delete all versions |

#### `facade.messages`

| Function | Signature | Description |
|----------|-----------|-------------|
| `publish` | `(message_name, correlation_value, payload) -> {:ok, map()} \| {:error, term()}` | Publish a named message through the correlation pipeline |

#### `facade.signals`

| Function | Signature | Description |
|----------|-----------|-------------|
| `publish` | `(signal_name) -> {:ok, map()} \| {:error, term()}` | Broadcast a named signal (no payload, no correlation) |

#### `facade.escalations`

| Function | Signature | Description |
|----------|-----------|-------------|
| `publish` | `(escalation_code) -> {:ok, map()} \| {:error, term()}` | Inject an escalation code into waiting catchers engine-wide. Empty deliveries is success. No payload, no pending. |

#### `facade.adhoc_subprocesses`

The process instance ID is the **child** PI spawned by the ad-hoc subprocess handler.

| Function | Signature | Description |
|----------|-----------|-------------|
| `get_enabled_activities` | `(process_instance_id) -> {:ok, [map()]} \| {:error, term()}` | List enabled/performed inner activities |
| `activate_activity` | `(process_instance_id, flow_node_id) -> {:ok, map()} \| {:error, term()}` | Activate an inner activity |
| `complete` | `(process_instance_id) -> :ok \| {:error, term()}` | Signal completion |
| `get_status` | `(process_instance_id) -> {:ok, map()} \| {:error, term()}` | Query runtime status |

#### `facade.timers`

| Function | Signature | Description |
|----------|-----------|-------------|
| `trigger_event` | `(flow_node_instance_id) -> :ok \| {:error, term()}` | Manually fire a waiting timer FNI |
| `list_schedules` | `(keyword()) -> {:ok, list()} \| {:error, term()}` | List Timer Start Event cycle schedules |
| `get_schedule` | `(String.t()) -> {:ok, map()} \| {:error, term()}` | Get one schedule by id |
| `enable_schedule` | `(String.t()) -> {:ok, map()} \| {:error, term()}` | Re-enable a disabled cycle schedule |
| `disable_schedule` | `(String.t()) -> {:ok, map()} \| {:error, term()}` | Disable an enabled cycle schedule |

#### `facade.graphql`

GraphQL is **query-only**. `facade.graphql.query/2` runs a raw query string through `Absinthe.run/3` with the plugin identity as actor context. There are no mutations.

| Function | Signature | Description |
|----------|-----------|-------------|
| `query` | `(String.t(), map()) -> {:ok, map()} \| {:error, term()}` | Execute a raw GraphQL query with plugin identity |

### Registration Validation (in-BEAM only)

When a capability is registered with an atom handler module (in-BEAM plugins), the Registry validates at registration time that the module:

1. Can be loaded into the BEAM (`Code.ensure_loaded/1`).
2. Declares `@behaviour` for the expected plugin behaviour (e.g. `EvilEngine.Plugin.ServiceTaskHandler` for service task handlers).

If validation fails, the registration function returns `{:error, :invalid_handler, message}` or `{:error, :module_not_loaded, message}`, a `PluginQuarantined` event is emitted, and the capability is **not** registered. The Loader also logs a warning for visibility.

String handler references are not used. The engine loads in-BEAM plugins only.

## Usage Examples

### Registration (during `on_load`)

```elixir
def on_load(facade) do
  IO.puts("Engine: #{facade.engine_name} v#{facade.version}")

  facade.register_service_task_handler.("my_handler", MyPlugin.Handler)

  facade.register_event_sink.("my-sink", MyPlugin.Sink, buffer_size: 50)

  :ok
end
```

### Process Operations

```elixir
{:ok, process} = facade.processes.get.("my-process-model-id")

{:ok, version} = facade.processes.get_latest_version.("my-process-model-id")

{:ok, pi_id} = facade.processes.start.(process_model_id: "my-process-model-id", payload: %{"key" => "value"})
```

### User Task Control

```elixir
facade.user_tasks.finish.("fni-uuid-456", %{"approved" => true}, identity)

facade.user_tasks.cancel.("fni-uuid-456", "User withdrew request", identity)
```

### Async Service Task Completion

```elixir
facade.service_tasks.finish_async.("fni-uuid-123", %{"status" => "done"})

facade.service_tasks.fail_async.("fni-uuid-123", "TIMEOUT", "Service did not respond in time")
```

### GraphQL Queries

```elixir
{:ok, result} = facade.graphql.query.(
  "query { processModels { id processModelId name } }",
  %{}
)
```

## Access Rules

- **Do not** call `EvilEngine.Plugins.Registry` directly — it is private to `peripheral_plugins`
- **Do not** reach into `core_execution`, `core_events`, or `peripheral_persistence` modules for command operations
- Use the facade namespace closures for all runtime operations
- In-BEAM plugins technically *can* reach internal modules; the contract forbids it and CI lints against it. That is a contract, not an isolation boundary.

## Plugin Identity

Every plugin receives a synthetic identity: `%Identity{id: "plugin:<name>", roles: []}`. This identity:

- **Bypasses** claim-based authorization checks (plugins are inside the operator's trust boundary; Loader wires `skip_claims: true`)
- **Is fully audited** — every action taken through the facade is recorded with the plugin identity
- **Is auto-injected** by the Loader when wiring namespace closures that require an identity (abort, retry, delete, deploy)

User Task functions (`finish`/`cancel`) accept an explicit `identity` parameter because the plugin may be acting on behalf of a specific user.

## Related

- [Getting Started](getting-started.md) -- plugin lifecycle
- [Service Task Handler](service-task-handler.md) -- async completion patterns
- [Event Sink](event-sink.md) -- event registration
