defmodule EvilEngine.Integration.Execution.UserTaskExecutionTest do
  @moduledoc "Integration tests for User Task execution (waiting, finish, contract violation)."
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  describe "simple user task (no contract)" do
    test "PI pauses at user task, finish call completes the PI", %{collector: collector} do
      {201, _} = http_deploy("user_task_simple.bpmn")

      {201, body} =
        http_start("UserTaskSimple", %{"payload" => %{"input" => "data"}})

      process_instance_id = body["processInstanceId"]

      Process.sleep(200)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      user_task_fni = Enum.find(flow_node_instances, &(&1.flow_node_type == "user_task"))
      assert user_task_fni != nil
      assert user_task_fni.state == "waiting"
      assert user_task_fni.type_properties != nil

      events_before = EventCollector.get_events(collector)
      ut_created = Enum.find(events_before, &match?(%Event.UserTaskCreated{}, &1))
      assert ut_created != nil
      assert ut_created.flow_node_id == "UserTask_1"

      result = %{"approved" => true}
      {204, _} = http_finish_user_task(user_task_fni.id, result)

      wait_for_process_instance(process_instance_id)

      process_instance = assert_pi_state!(process_instance_id, "finished")
      assert process_instance.finished_at != nil

      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")

      finished_ut = Enum.find(flow_node_instances, &(&1.flow_node_type == "user_task"))
      assert finished_ut.state == "finished"
      assert finished_ut.output_token == %{"approved" => true}

      events = EventCollector.await_events(collector, 10, 2_000)

      ut_finished = Enum.find(events, &match?(%Event.UserTaskFinished{}, &1))
      assert ut_finished != nil
      assert ut_finished.outcome == :completed
    end
  end

  describe "user task with result contract" do
    test "finishing with valid payload completes the PI" do
      {201, _} = http_deploy("user_task_with_contract.bpmn")

      {201, body} = http_start("UserTaskWithContract")
      process_instance_id = body["processInstanceId"]

      Process.sleep(200)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      user_task_fni = Enum.find(flow_node_instances, &(&1.flow_node_type == "user_task"))
      assert user_task_fni != nil
      assert user_task_fni.state == "waiting"

      result = %{"approved" => true}
      {204, _} = http_finish_user_task(user_task_fni.id, result)

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "finishing with invalid payload is rejected but PI stays running" do
      {201, _} = http_deploy("user_task_with_contract.bpmn")

      {201, body} = http_start("UserTaskWithContract")
      process_instance_id = body["processInstanceId"]

      Process.sleep(200)

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      user_task_fni = Enum.find(flow_node_instances, &(&1.flow_node_type == "user_task"))
      assert user_task_fni != nil
      assert user_task_fni.state == "waiting"

      invalid_result = %{"wrong_field" => "no approved key"}
      {422, err_body} = http_finish_user_task(user_task_fni.id, invalid_result)
      assert err_body["error"] == "contract_violation"

      assert_pi_state!(process_instance_id, "running")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      user_task_fni = Enum.find(flow_node_instances, &(&1.id == user_task_fni.id))
      assert user_task_fni.state == "waiting"

      valid_result = %{"approved" => true}
      {204, _} = http_finish_user_task(user_task_fni.id, valid_result)

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end
end
