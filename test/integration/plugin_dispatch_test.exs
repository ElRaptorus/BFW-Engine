defmodule BfwEngine.Integration.PluginDispatchTest do
  @moduledoc """
  Full-stack integration tests that verify the plugin dispatch
  mechanism end-to-end:

  - `RegistryDispatch` adapter resolves handlers by **implementation** (dispatch key)
  - PI dispatches to plugin handler → FNI finishes → PI completes
  - async contract: handler returns `{:async, flow_node_instance_id}`, then the
    plugin itself completes/fails the FNI via the `EngineFacade` it
    received during `on_load/1`
  - Error paths: unknown implementation → FNI fatal
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Plugins.Loader
  alias BfwEngine.Plugins.Registry
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Test.ExamplePlugin
  alias BfwEngine.Types.Event

  setup %{collector: _} = context do
    Application.put_env(
      :core_execution,
      :service_task_dispatch,
      BfwEngine.Plugins.RegistryDispatch
    )

    load_example_plugin_via_facade()

    version_id_echo = gen_version_id()
    version_id_async = gen_version_id()
    version_id_async_fail = gen_version_id()
    version_id_unknown = gen_version_id()

    deploy_fixture("service_task_echo.bpmn", version_id_echo)
    deploy_fixture("service_task_async.bpmn", version_id_async)
    deploy_fixture("service_task_async_fail.bpmn", version_id_async_fail)
    deploy_fixture("service_task_unknown_type.bpmn", version_id_unknown)

    on_exit(fn ->
      Application.put_env(
        :core_execution,
        :service_task_dispatch,
        BfwEngine.Execution.ServiceTaskDispatch.NoOp
      )
    end)

    {:ok,
     Map.merge(context, %{
       version_id_echo: version_id_echo,
       version_id_async: version_id_async,
       version_id_async_fail: version_id_async_fail,
       version_id_unknown: version_id_unknown
     })}
  end

  defp load_example_plugin_via_facade do
    facade = Loader.facade_for_plugin("evil:test_example")
    ExamplePlugin.on_load(facade)
  end

  # ----- Echo Service Task dispatch (async ) -------------------------

  describe "echo Service Task dispatch via plugin (async)" do
    test "Start → ServiceTask(echo) → End: PI completes with echo result", %{
      collector: collector,
      version_id_echo: version
    } do
      {:ok, pid, process_instance_id} = start_process(version, payload: %{"greeting" => "hello"})
      wait_for_stop(pid)

      assert_pi_state!(process_instance_id, "finished")
      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 3)

      service_fni = Enum.find(flow_node_instances, &(&1.flow_node_type == "service_task"))
      assert service_fni.state == "finished"

      assert service_fni.output_token["handled_by"] == "echo"
      assert service_fni.output_token["flow_node_id"] == "ServiceTask_1"
      assert service_fni.output_token["input"]["greeting"] == "hello"

      events = EventCollector.await_events(collector, 8)
      process_instance_state_change_events = Enum.filter(events, &match?(%Event.ProcessInstanceStateChanged{}, &1))
      assert length(process_instance_state_change_events) == 2
    end
  end

  # ----- Plugin-driven async Service Task ----------------------------

  describe "async Service Task — plugin completes via EngineFacade" do
    test "plugin handler parks FNI, then completes it autonomously", %{
      collector: collector,
      version_id_async: version
    } do
      {:ok, pid, process_instance_id} = start_process(version, payload: %{"data" => "async_test"})

      wait_for_stop(pid)

      assert_pi_state!(process_instance_id, "finished")
      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 3)

      service_fni = Enum.find(flow_node_instances, &(&1.flow_node_type == "service_task"))
      assert service_fni.state == "finished"
      assert service_fni.output_token["handled_by"] == "async_echo"
      assert service_fni.output_token["async"] == true
      assert service_fni.output_token["input"]["data"] == "async_test"

      events = EventCollector.await_events(collector, 8)
      process_instance_state_change_events = Enum.filter(events, &match?(%Event.ProcessInstanceStateChanged{}, &1))
      assert length(process_instance_state_change_events) == 2
    end

    test "plugin handler parks FNI, then fails it autonomously → PI fatal", %{
      version_id_async_fail: version
    } do
      {:ok, pid, process_instance_id} = start_process(version)

      wait_for_stop(pid)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
    end
  end

  # ----- Async error paths (called externally) ----------------------------

  describe "async FNI error paths" do
    test "complete on non-existent FNI returns error" do
      assert {:error, :process_instance_not_found} =
               Execution.finish_async_service_task("nonexistent-fni", %{})
    end

    test "fail on non-existent FNI returns error" do
      assert {:error, :process_instance_not_found} =
               Execution.fail_async_service_task("nonexistent-fni", "ERR", "msg")
    end
  end

  # ----- Dispatch error paths ---------------------------------------------

  describe "Service Task dispatch error paths" do
    test "unknown implementation causes fatal PI", %{version_id_unknown: version} do
      {:ok, pid, process_instance_id} = start_process(version)

      wait_for_stop(pid)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
    end
  end

  # ----- Plugin lifecycle -------------------------------------------------

  describe "plugin lifecycle via Loader" do
    test "facade capabilities are wired — register, publish, complete all work" do
      facade = Loader.facade_for_plugin("lifecycle_test")

      assert is_binary(facade.engine_id)
      assert is_binary(facade.engine_name)
      assert is_binary(facade.version)

      result = facade.register_service_task_handler.("test_cap", BfwEngine.Test.ExamplePlugin.EchoHandler)

      assert result == :ok

      caps = Registry.list_capabilities(:service_task_handler)
      assert Enum.any?(caps, fn c -> c.descriptor.implementation == "test_cap" end)
    end
  end

  # ----- Plugin-originated message delivery --------------------------------

  describe "plugin facade publishes message to waiting catch event" do
    test "facade.messages.publish delivers to active subscriber" do
      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, body} = http_start("MessageCatchSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, _fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      facade = Loader.facade_for_plugin("msg_test_plugin")

      {:ok, result} = facade.messages.publish.("test-message", nil, %{"from" => "plugin"})

      assert length(result.deliveries) >= 1
      assert Enum.any?(result.deliveries, fn delivery ->
        delivery.process_instance_id == process_instance_id
      end)

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ----- Plugin-originated signal delivery --------------------------------

  describe "plugin facade publishes signal to waiting catch event" do
    test "facade.signals.publish delivers to active subscriber" do
      {201, _} = http_deploy("signal_catch_simple.bpmn")
      {201, body} = http_start("SignalCatchSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, _fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      facade = Loader.facade_for_plugin("sig_test_plugin")

      {:ok, result} = facade.signals.publish.("test-signal")

      assert length(result.deliveries) >= 1
      assert Enum.any?(result.deliveries, fn delivery ->
        delivery.process_instance_id == process_instance_id
      end)

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ----- Helpers ----------------------------------------------------------

  defp wait_for_stop(pid, timeout \\ 3_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> flunk("PI did not stop within #{timeout}ms")
    end
  end
end
