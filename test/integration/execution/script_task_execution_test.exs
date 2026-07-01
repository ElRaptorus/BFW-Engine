defmodule EvilEngine.Integration.Execution.ScriptTaskExecutionTest do
  @moduledoc """
  Integration tests for ScriptTask execution. Each test deploys a real
  BPMN, starts a PI via HTTP, and asserts observable outcomes.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.ExamplePlugin

  defp register_test_plugin do
    Application.put_env(:core_execution, :service_task_dispatch, EvilEngine.Plugins.RegistryDispatch)
    Application.put_env(:core_execution, :script_dispatch, EvilEngine.Plugins.ScriptRegistryDispatch)
    facade = Loader.facade_for_plugin("evil:test_script_task")
    ExamplePlugin.on_load(facade)
  end

  describe "ScriptTask — inline FEEL" do
    test "SCR-I1: inline FEEL script completes PI successfully" do
      {201, _} = http_deploy("script_task_inline_feel.bpmn")
      {201, body} = http_start("ScriptTaskInlineFeel", %{"payload" => %{"amount" => 10}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end

    test "SCR-I2: corrupt FEEL script causes PI fatal" do
      {201, _} = http_deploy("script_task_corrupt_feel.bpmn")
      {201, body} = http_start("ScriptTaskCorruptFeel", %{"payload" => %{"data" => "x"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" and &1.flow_node_type == "script_task"))
      assert fatal_fni != nil, "ScriptTask FNI should be in fatal state"
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info"
    end
  end

  describe "ScriptTask — plugin dispatch via scriptRef" do
    setup do
      register_test_plugin()
      :ok
    end

    test "SCR-I3: scriptRef dispatches to registered named script handler" do
      {201, _} = http_deploy("script_task_named_ref.bpmn")
      {201, body} = http_start("ScriptTaskNamedRef", %{"payload" => %{"data" => "test"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end
  end

  describe "ScriptTask — full data pipeline" do
    test "SCR-I4: mappers + contracts + inline script completes successfully" do
      {201, _} = http_deploy("script_task_full_pipeline.bpmn")
      {201, body} = http_start("ScriptTaskFullPipeline", %{"payload" => %{"raw_amount" => 10}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end
  end
end
