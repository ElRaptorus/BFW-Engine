# Implementing Service Task Handlers

A Service Task handler processes automated tasks dispatched by the engine based on the standard BPMN `implementation` attribute on a Service Task.

## Async-Only Contract

All Service Task handlers are **asynchronous**. `handle_enter/3` must return `{:async, ref}` and complete the FNI later through the engine facade. Synchronous `{:ok, ...}` returns are not supported.

This is a deliberate design choice: Service Tasks represent external delegation to remote systems. The async contract enforces this boundary. If your work is local, synchronous computation, use a **Script Task** with a Named Script plugin instead — see `EvilEngine.Plugin.NamedScript`.

## Behaviour

```elixir
@behaviour EvilEngine.Plugin.ServiceTaskHandler

@callback handle_enter(
  flow_node :: struct(),
  token :: struct(),
  handler_context :: struct()
) :: {:async, String.t()} | {:error, term()}
```

## Arguments

| Argument | Contents |
|----------|----------|
| `flow_node` | The parsed BPMN flow node definition, including `type_data` with extension elements |
| `token` | Current token with `payload` map |
| `handler_context` | `%HandlerContext{}` with `flow_node_instance_id`, `process_instance_id`, `identity`, `process`, `process_instance`, `data_objects` |

The `handler_context` provides everything needed to evaluate [FEEL expressions](../handbook/expressions.md) and correlate async completions.

## Return Shapes

| Return | FNI State | Description |
|--------|-----------|-------------|
| `{:async, ref}` | `waiting` | Parks the FNI; complete later via the facade |
| `{:error, reason}` | `fatal` | Unrecoverable error (caught by boundary events if attached) |

## Registration

In your plugin's `on_load`:

```elixir
def on_load(facade) do
  MyPlugin.FacadeStore.put(facade)
  facade.register_service_task_handler.("my_crm", MyPlugin.CrmHandler)
  :ok
end
```

In BPMN:

```xml
<bpmn:serviceTask id="update_crm" implementation="my_crm">
</bpmn:serviceTask>
```

Duplicate `implementation` registration is an error (not a crash).

## Handler Example

The pattern for all Service Task handlers: validate synchronously, spawn async work, return `{:async, ref}`.

```elixir
defmodule MyPlugin.CrmHandler do
  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = MyPlugin.FacadeStore.get()

    Task.start(fn ->
      case MyPlugin.CRM.update_contact(token.payload) do
        {:ok, result} ->
          facade.service_tasks.finish_async.(flow_node_instance_id, result)

        {:error, reason} ->
          facade.service_tasks.fail_async.(
            flow_node_instance_id,
            "CRM_UPDATE_FAILED",
            inspect(reason)
          )
      end
    end)

    {:async, flow_node_instance_id}
  end
end
```

## Webhook / External Completion Example

For long-running external processes (approval workflows, third-party integrations), store the `flow_node_instance_id` and complete when the callback arrives:

```elixir
defmodule MyPlugin.ExternalApprovalHandler do
  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, token, context) do
    flow_node_instance_id = context.flow_node_instance_id

    MyPlugin.ApprovalService.request_async(
      flow_node_instance_id,
      token.payload
    )

    {:async, flow_node_instance_id}
  end
end

# When the external service responds (e.g., via a webhook handler in your plugin):
def handle_webhook(%{"flow_node_instance_id" => flow_node_instance_id, "approved" => approved}) do
  facade = MyPlugin.FacadeStore.get()

  if approved do
    facade.service_tasks.finish_async.(flow_node_instance_id, %{"approved" => true})
  else
    facade.service_tasks.fail_async.(flow_node_instance_id, "REJECTED", "Approval denied")
  end
end
```

See [Engine Facade Reference](engine-facade.md) for the async completion API.

## Facade Store Pattern

Every async Service Task handler needs access to the engine facade for completion. The recommended pattern is an Agent-backed store initialized in `on_load`:

```elixir
defmodule MyPlugin.FacadeStore do
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  def put(facade) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> facade end)
  end

  def get do
    Agent.get(__MODULE__, & &1)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end
end
```

## Payload Cap

Handler output (passed to `finish_async`) is checked against `EVIL_TOKEN_MAX_BYTES` during the output pipeline. Oversized output causes the FNI to transition to `fatal`. See [Error Handling](../handbook/error-handling.md).

## Related

- [Service Tasks](../handbook/service-tasks.md) -- user-facing guide
- [Script Tasks / Named Scripts](../handbook/script-tasks.md) -- for local, synchronous computation
- [Built-in Plugins](builtin-plugins.md) -- HTTP handler as reference implementation
- [Engine Facade Reference](engine-facade.md) -- async completion API
- [FEEL Expressions](../handbook/expressions.md) -- expression context in handlers
