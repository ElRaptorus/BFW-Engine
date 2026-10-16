defmodule BfwEngine.Test.ExamplePlugin do
  @moduledoc """
  Fixture plugin for integration tests. Implements the full
  `BfwEngine.Plugin` lifecycle and registers Service Task handlers
  and Named Script handlers:

  Service Task handlers (all async ):
  - `echo` — async handler that echoes the input token via immediate completion
  - `async_echo` — async handler that parks then completes via facade after a delay
  - `async_fail` — async handler that parks then fails via facade
  - `early_completion` — completes (or, with `"fail" => true` in the input,
    fails) its task before `handle_enter/3` returns; see its moduledoc for
    the `"then_fail"` and `"nested"` inputs
  - `raising` — raises from `handle_enter/3`

  Named Script handlers:
  - `test_validator` — synchronous script that adds a `validated` flag
  - `exiting_script` — exits from `handle_enter/3`
  """

  @behaviour BfwEngine.Plugin

  @impl true
  def on_load(facade) do
    BfwEngine.Test.ExamplePlugin.FacadeStore.put(facade)

    facade.register_service_task_handler.("echo", BfwEngine.Test.ExamplePlugin.EchoHandler)
    facade.register_service_task_handler.("async_echo", BfwEngine.Test.ExamplePlugin.AsyncEchoHandler)
    facade.register_service_task_handler.("async_fail", BfwEngine.Test.ExamplePlugin.AsyncFailHandler)
    facade.register_service_task_handler.("async_park", BfwEngine.Test.ExamplePlugin.AsyncParkHandler)

    facade.register_service_task_handler.(
      "early_completion",
      BfwEngine.Test.ExamplePlugin.EarlyCompletionHandler
    )

    facade.register_service_task_handler.("raising", BfwEngine.Test.ExamplePlugin.RaisingHandler)
    facade.register_named_script.("test_validator", BfwEngine.Test.ExamplePlugin.TestValidatorScript)
    facade.register_named_script.("exiting_script", BfwEngine.Test.ExamplePlugin.ExitingScript)

    :ok
  end

  @impl true
  def on_ready(_facade), do: :ok
end

defmodule BfwEngine.Test.ExamplePlugin.FacadeStore do
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

defmodule BfwEngine.Test.ExamplePlugin.EchoHandler do
  @moduledoc """
  Async Service Task handler that echoes the input token (all
  Service Task handlers are async-only). Spawns a task that immediately
  completes the FNI via `finish_async_service_task`.
  """
  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(flow_node, token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = BfwEngine.Test.ExamplePlugin.FacadeStore.get()

    spawn(fn ->
      facade.service_tasks.finish_async.(flow_node_instance_id, %{
        "handled_by" => "echo",
        "flow_node_id" => flow_node.id,
        "input" => token.payload
      })
    end)

    {:async, flow_node_instance_id}
  end
end

defmodule BfwEngine.Test.ExamplePlugin.AsyncEchoHandler do
  @moduledoc """
  Async Service Task handler that parks the FNI, then completes it
  via the `EngineFacade` after a brief delay — proving the full
  plugin-driven async lifecycle works end-to-end.
  """
  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = BfwEngine.Test.ExamplePlugin.FacadeStore.get()

    spawn(fn ->
      facade.service_tasks.finish_async.(flow_node_instance_id, %{
        "handled_by" => "async_echo",
        "async" => true,
        "input" => token.payload
      })
    end)

    {:async, flow_node_instance_id}
  end
end

defmodule BfwEngine.Test.ExamplePlugin.EarlyCompletionHandler do
  @moduledoc """
  Async Service Task handler that completes its task before `handle_enter/3`
  returns: a separate process calls `finish_async` (`fail_async` with code
  `EARLY_FAILURE` when the input has `"fail" => true`), and the handler
  returns only once that process has sent the call.

  The handler returns `{:async, id}`, or `{:error, "handler gave up"}` when the
  input has `"then_fail" => true`. With `"nested" => true` the completion is
  made by a `Task` the handler awaits instead, before it returns `{:async, id}`.

  The call's result is sent as `{:early_completion_result, flow_node_instance_id, result}`
  to the process registered as `BfwEngine.Test.ExamplePlugin.EarlyCompletionHandler`,
  when one is registered.
  """
  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, %{payload: %{"nested" => true} = payload}, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = BfwEngine.Test.ExamplePlugin.FacadeStore.get()

    result =
      fn -> complete(facade, flow_node_instance_id, payload) end
      |> Task.async()
      |> Task.await()

    report(flow_node_instance_id, result)
    {:async, flow_node_instance_id}
  end

  def handle_enter(_flow_node, token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = BfwEngine.Test.ExamplePlugin.FacadeStore.get()

    run_until_call_sent(fn ->
      result = complete(facade, flow_node_instance_id, token.payload)
      report(flow_node_instance_id, result)
    end)

    case token.payload do
      %{"then_fail" => true} -> {:error, "handler gave up"}
      _payload -> {:async, flow_node_instance_id}
    end
  end

  defp complete(facade, flow_node_instance_id, %{"fail" => true}) do
    facade.service_tasks.fail_async.(
      flow_node_instance_id,
      "EARLY_FAILURE",
      "failed before handle_enter returned"
    )
  end

  defp complete(facade, flow_node_instance_id, payload) do
    facade.service_tasks.finish_async.(flow_node_instance_id, %{"early" => true, "input" => payload})
  end

  defp report(flow_node_instance_id, result) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      observer -> send(observer, {:early_completion_result, flow_node_instance_id, result})
    end
  end

  # The handler traces the caller's sends and returns once the caller has sent
  # its `gen_statem` call, so the call reaches the instance before the result.
  defp run_until_call_sent(completion) do
    caller =
      spawn(fn ->
        receive do
          :start -> completion.()
        end
      end)

    monitor_reference = Process.monitor(caller)
    _traced_count = :erlang.trace(caller, true, [:send])
    send(caller, :start)

    receive do
      {:trace, ^caller, :send, {:"$gen_call", _from, _request}, _instance} -> :ok
      {:DOWN, ^monitor_reference, :process, ^caller, _reason} -> :ok
    end

    Process.demonitor(monitor_reference, [:flush])
  end
end

defmodule BfwEngine.Test.ExamplePlugin.RaisingHandler do
  @moduledoc """
  Service Task handler whose `handle_enter/3` raises.
  """
  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, _token, _context) do
    raise "deliberate handler failure"
  end
end

defmodule BfwEngine.Test.ExamplePlugin.ExitingScript do
  @moduledoc """
  Named script whose `handle_enter/3` exits with a reason that carries a
  payload value (`"never in a message"`).
  """
  @behaviour BfwEngine.Plugin.NamedScript

  @impl true
  def handle_enter(_flow_node, _payload, _context) do
    exit({:deliberate_script_exit, %{"secret" => "never in a message"}})
  end
end

defmodule BfwEngine.Test.ExamplePlugin.AsyncParkHandler do
  @moduledoc """
  Async Service Task handler that parks the FNI indefinitely.
  The test must explicitly complete or fail it via the Execution API.

  `handle_resume/2` leaves the task waiting and sends
  `{:service_task_resumed, resume_input}` to the process registered as
  `BfwEngine.Test.ExamplePlugin.AsyncParkHandler`, when one is registered.
  """
  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, token, context) do
    BfwEngine.Test.ExamplePlugin.AsyncParkPayloads.record(token.payload)
    {:async, context.flow_node_instance_id}
  end

  @impl true
  def handle_resume(resume_input, _context) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      observer -> send(observer, {:service_task_resumed, resume_input})
    end
  end
end

defmodule BfwEngine.Test.ExamplePlugin.AsyncParkPayloads do
  @moduledoc false
  use Agent

  def start_link(_options \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def reset do
    ensure_started()
    Agent.update(__MODULE__, fn _payloads -> [] end)
  end

  def record(payload) do
    ensure_started()
    Agent.update(__MODULE__, fn payloads -> payloads ++ [payload] end)
  end

  def list do
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

defmodule BfwEngine.Test.ExamplePlugin.AsyncFailHandler do
  @moduledoc """
  Async Service Task handler that parks the FNI, then fails it
  via the `EngineFacade` — proving the async failure path works.
  """
  @behaviour BfwEngine.Plugin.ServiceTaskHandler

  @impl true
  def handle_enter(_flow_node, _token, context) do
    flow_node_instance_id = context.flow_node_instance_id
    facade = BfwEngine.Test.ExamplePlugin.FacadeStore.get()

    spawn(fn ->
      Process.sleep(100)
      facade.service_tasks.fail_async.(flow_node_instance_id, "PLUGIN_ERROR", "deliberate test failure")
    end)

    {:async, flow_node_instance_id}
  end
end

defmodule BfwEngine.Test.ExamplePlugin.TestValidatorScript do
  @moduledoc """
  Named script handler for integration tests. Adds a `validated` flag
  to the payload, proving that scriptRef dispatch works end-to-end.
  """
  @behaviour BfwEngine.Plugin.NamedScript

  @impl true
  def handle_enter(_flow_node, payload, _context) do
    {:ok, Map.put(payload, "validated", true)}
  end
end
