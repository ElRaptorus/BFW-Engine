defmodule EvilEngine.Test.ExamplePlugin do
  @moduledoc """
  Fixture plugin for integration tests. Implements the full
  `EvilEngine.Plugin` lifecycle and registers Service Task handlers
  and Named Script handlers:

  Service Task handlers (all async ):
  - `echo` — async handler that echoes the input token via immediate completion
  - `async_echo` — async handler that parks then completes via facade after a delay
  - `async_fail` — async handler that parks then fails via facade

  Named Script handlers:
  - `test_validator` — synchronous script that adds a `validated` flag
  """

  @behaviour EvilEngine.Plugin

  @impl true
  def on_load(facade) do
    EvilEngine.Test.ExamplePlugin.FacadeStore.put(facade)

    facade.register_service_task_handler.("echo", EvilEngine.Test.ExamplePlugin.EchoHandler)
    facade.register_service_task_handler.("async_echo", EvilEngine.Test.ExamplePlugin.AsyncEchoHandler)
    facade.register_service_task_handler.("async_fail", EvilEngine.Test.ExamplePlugin.AsyncFailHandler)
    facade.register_service_task_handler.("async_park", EvilEngine.Test.ExamplePlugin.AsyncParkHandler)
    facade.register_named_script.("test_validator", EvilEngine.Test.ExamplePlugin.TestValidatorScript)

    :ok
  end

  @impl true
  def on_ready(_facade), do: :ok
end

defmodule EvilEngine.Test.ExamplePlugin.FacadeStore do
  @moduledoc false
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  def put(facade) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> facade end)
  end

  def get do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end
end

defmodule EvilEngine.Test.ExamplePlugin.EchoHandler do
  @moduledoc """
  Async Service Task handler that echoes the input token (all
  Service Task handlers are async-only). Spawns a task that immediately
  completes the FNI via `finish_async_service_task`.
  """
  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(flow_node, token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = EvilEngine.Test.ExamplePlugin.FacadeStore.get()

    spawn(fn ->
      Process.sleep(50)

      facade.service_tasks.finish_async.(flow_node_instance_id, %{
        "handled_by" => "echo",
        "flow_node_id" => flow_node.id,
        "input" => token.payload
      })
    end)

    {:async, flow_node_instance_id}
  end
end

defmodule EvilEngine.Test.ExamplePlugin.AsyncEchoHandler do
  @moduledoc """
  Async Service Task handler that parks the FNI, then completes it
  via the `EngineFacade` after a brief delay — proving the full
  plugin-driven async lifecycle works end-to-end.
  """
  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = EvilEngine.Test.ExamplePlugin.FacadeStore.get()

    spawn(fn ->
      Process.sleep(100)

      facade.service_tasks.finish_async.(flow_node_instance_id, %{
        "handled_by" => "async_echo",
        "async" => true,
        "input" => token.payload
      })
    end)

    {:async, flow_node_instance_id}
  end
end

defmodule EvilEngine.Test.ExamplePlugin.AsyncParkHandler do
  @moduledoc """
  Async Service Task handler that parks the FNI indefinitely.
  The test must explicitly complete or fail it via the Execution API.
  """
  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, _token, context) do
    {:async, context.flow_node_instance_id}
  end
end

defmodule EvilEngine.Test.ExamplePlugin.AsyncFailHandler do
  @moduledoc """
  Async Service Task handler that parks the FNI, then fails it
  via the `EngineFacade` — proving the async failure path works.
  """
  @behaviour EvilEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, _token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = EvilEngine.Test.ExamplePlugin.FacadeStore.get()

    spawn(fn ->
      Process.sleep(100)
      facade.service_tasks.fail_async.(flow_node_instance_id, "PLUGIN_ERROR", "deliberate test failure")
    end)

    {:async, flow_node_instance_id}
  end
end

defmodule EvilEngine.Test.ExamplePlugin.TestValidatorScript do
  @moduledoc """
  Named script handler for integration tests. Adds a `validated` flag
  to the payload, proving that scriptRef dispatch works end-to-end.
  """
  @behaviour EvilEngine.Plugin.NamedScript

  @impl true
  def handle_enter(_flow_node, payload, _context) do
    {:ok, Map.put(payload, "validated", true)}
  end
end
