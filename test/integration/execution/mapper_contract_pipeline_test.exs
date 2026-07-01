defmodule EvilEngine.Integration.Execution.MapperContractPipelineTest do
  @moduledoc """
  Integration tests for the mapper/contract pipeline across ServiceTask,
  UserTask, and CallActivity. Each test deploys a real BPMN, starts a PI
  via HTTP, and asserts observable outcomes (PI state, FNI state,
  error_info, output tokens).

  Key principle: every failure path must produce an observable error —
  no silent swallowing.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.ExamplePlugin

  defp register_test_plugin do
    Application.put_env(:core_execution, :service_task_dispatch, EvilEngine.Plugins.RegistryDispatch)
    facade = Loader.facade_for_plugin("evil:test_mapper_contract")
    ExamplePlugin.on_load(facade)
  end

  # ===========================================================================
  # ServiceTask pipeline
  # ===========================================================================

  describe "ServiceTask — full mapper/contract pipeline" do
    setup do
      register_test_plugin()
      :ok
    end
    test "ST-1: full pipeline happy path (mapper + contract both sides)" do
      {201, _} = http_deploy("service_task_full_pipeline.bpmn")
      {201, body} = http_start("ServiceTaskFullPipeline", %{"payload" => %{"order_id" => "ORD-42"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert_all_fnis_state!(process_instance_id, "finished")

      service_fni = Enum.find(flow_node_instances, &(&1.flow_node_type == "service_task"))
      assert service_fni.error_info == nil
    end

    test "ST-2: corrupt input FEEL → PI fatal" do
      {201, _} = http_deploy("service_task_bad_input_feel.bpmn")
      {201, body} = http_start("ServiceTaskBadInputFeel", %{"payload" => %{"data" => "x"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" and &1.flow_node_type == "service_task"))
      assert fatal_fni != nil, "ServiceTask FNI should be in fatal state"
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info"
    end

    test "ST-5: output contract violation → PI fatal" do
      {201, _} = http_deploy("service_task_output_contract_violation.bpmn")
      {201, body} = http_start("ServiceTaskOutputContractViolation", %{"payload" => %{"data" => "x"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" and &1.flow_node_type == "service_task"))
      assert fatal_fni != nil, "ServiceTask FNI should be in fatal state"
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info for contract violation"
    end

    test "ST-6: mapper reshapes data to satisfy contract (proves ordering)" do
      {201, _} = http_deploy("service_task_mapper_reshapes.bpmn")

      {201, body} = http_start("ServiceTaskMapperReshapes", %{"payload" => %{"raw_id" => "ABC-123"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end
  end

  # ===========================================================================
  # UserTask pipeline
  # ===========================================================================

  describe "UserTask — full mapper/contract pipeline" do
    test "UT-1: full pipeline happy path (mapper + contract both sides)" do
      {201, _} = http_deploy("user_task_full_pipeline.bpmn")
      {201, body} = http_start("UserTaskFullPipeline", %{"payload" => %{"raw_name" => "Alice"}})
      process_instance_id = body["processInstanceId"]

      user_task_fni = poll_fni_state(process_instance_id, "user_task", "waiting")
      assert user_task_fni.error_info == nil

      {204, _} = http_finish_user_task(user_task_fni.id, %{"user_approved" => true})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end

    test "UT-3: input contract violation → FNI fatal (upstream bug)" do
      {201, _} = http_deploy("user_task_input_contract_violation.bpmn")
      {201, body} = http_start("UserTaskInputContractViolation", %{"payload" => %{"wrong" => "data"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" and &1.flow_node_type == "user_task"))
      assert fatal_fni != nil, "UserTask FNI should be fatal for input contract violation"
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info"
    end

    test "UT-2: corrupt input FEEL → FNI fatal" do
      {201, _} = http_deploy("user_task_bad_input_feel.bpmn")
      {201, body} = http_start("UserTaskBadInputFeel", %{"payload" => %{"data" => "x"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" and &1.flow_node_type == "user_task"))
      assert fatal_fni != nil, "UserTask FNI should be fatal for corrupt input FEEL"
      assert fatal_fni.error_info != nil
    end

    test "UT-5/7: output contract violation → stays waiting, retry succeeds" do
      {201, _} = http_deploy("user_task_with_contract.bpmn")
      {201, body} = http_start("UserTaskWithContract")
      process_instance_id = body["processInstanceId"]

      user_task_fni = poll_fni_state(process_instance_id, "user_task", "waiting")

      {422, err_body} = http_finish_user_task(user_task_fni.id, %{"wrong_field" => "no approved key"})
      assert err_body["error"] == "contract_violation"

      assert_pi_state!(process_instance_id, "running")
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      still_waiting = Enum.find(flow_node_instances, &(&1.id == user_task_fni.id))
      assert still_waiting.state == "waiting"

      {204, _} = http_finish_user_task(user_task_fni.id, %{"approved" => true})
      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "UT-6: output mapper reshapes user submission to satisfy contract" do
      {201, _} = http_deploy("user_task_output_mapper_reshapes.bpmn")
      {201, body} = http_start("UserTaskOutputMapperReshapes", %{"payload" => %{"data" => "x"}})
      process_instance_id = body["processInstanceId"]

      user_task_fni = poll_fni_state(process_instance_id, "user_task", "waiting")

      {204, _} = http_finish_user_task(user_task_fni.id, %{"is_approved" => true})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")
    end
  end

  # ===========================================================================
  # CallActivity pipeline
  # ===========================================================================

  describe "CallActivity — mapper failure paths" do
    setup do
      original_resolver = Application.get_env(:core_execution, :called_element_resolver)

      Application.put_env(
        :core_execution,
        :called_element_resolver,
        EvilEngine.Persistence.CalledElementResolverImpl
      )

      on_exit(fn ->
        if original_resolver do
          Application.put_env(:core_execution, :called_element_resolver, original_resolver)
        else
          Application.delete_env(:core_execution, :called_element_resolver)
        end
      end)

      :ok
    end

    test "CA-2: corrupt input mapping → parent PI fatal" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy("call_activity_bad_input_mapping.bpmn")

      {201, body} = http_start("CallActivityBadInputMapping", %{"payload" => %{"data" => "x"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" and &1.flow_node_type == "call_activity"))
      assert fatal_fni != nil, "CallActivity FNI should be fatal for corrupt input mapping"
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info"
    end

    test "CA-3: corrupt output mapping → parent PI fatal" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy("call_activity_bad_output_mapping.bpmn")

      {201, body} = http_start("CallActivityBadOutputMapping", %{"payload" => %{"data" => "x"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "fatal")
      assert_no_running_fnis!(process_instance_id)
      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      fatal_fni = Enum.find(flow_node_instances, &(&1.state == "fatal" and &1.flow_node_type == "call_activity"))
      assert fatal_fni != nil, "CallActivity FNI should be fatal for corrupt output mapping"
      assert fatal_fni.error_info != nil, "Fatal FNI should have error_info"
    end
  end
end
