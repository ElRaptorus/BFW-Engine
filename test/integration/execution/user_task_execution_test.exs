defmodule BfwEngine.Integration.Execution.UserTaskExecutionTest do
  @moduledoc "Integration tests for User Task execution (waiting, finish, contract violation)."
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event
  alias BfwEngine.Types.Identity

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
      assert finished_ut.output_token == %{"actionId" => nil, "values" => %{"approved" => true}}

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

  describe "finish body" do
    test "writes the action id and an empty values object when values are omitted" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, body} = http_start("UserTaskSimple")
      process_instance_id = body["processInstanceId"]
      Process.sleep(200)

      user_task_fni =
        Enum.find(
          fetch_flow_node_instances(process_instance_id),
          &(&1.flow_node_type == "user_task")
        )

      {204, _} = http_finish_user_task(user_task_fni.id, %{}, %{}, "confirm")

      wait_for_process_instance(process_instance_id)

      finished =
        Enum.find(fetch_flow_node_instances(process_instance_id), &(&1.id == user_task_fni.id))

      assert finished.output_token == %{"actionId" => "confirm", "values" => %{}}
    end

    test "rejects a non-object values field and a bad action id" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, body} = http_start("UserTaskSimple")
      process_instance_id = body["processInstanceId"]
      Process.sleep(200)

      user_task_fni =
        Enum.find(
          fetch_flow_node_instances(process_instance_id),
          &(&1.flow_node_type == "user_task")
        )

      assert {422, %{"error" => "invalid_values"}} =
               raw_finish(user_task_fni.id, %{"values" => "nope", "actionId" => "confirm"})

      assert {422, %{"error" => "invalid_values"}} =
               raw_finish(user_task_fni.id, %{"values" => [1], "actionId" => "confirm"})

      assert {422, %{"error" => "invalid_values"}} =
               raw_finish(user_task_fni.id, %{"values" => 1})

      assert {422, %{"error" => "invalid_action_id"}} =
               raw_finish(user_task_fni.id, %{"values" => %{}, "actionId" => 1})

      assert {422, %{"error" => "invalid_action_id"}} =
               raw_finish(user_task_fni.id, %{"values" => %{}, "actionId" => "   "})

      assert {422, %{"error" => "invalid_action_id"}} =
               raw_finish(user_task_fni.id, %{
                 "values" => %{},
                 "actionId" => String.duplicate("a", 256)
               })

      still_waiting =
        Enum.find(fetch_flow_node_instances(process_instance_id), &(&1.id == user_task_fni.id))

      assert still_waiting.state == "waiting"
    end

    test "rejects an oversized values object" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, body} = http_start("UserTaskSimple")
      process_instance_id = body["processInstanceId"]
      Process.sleep(200)

      user_task_fni =
        Enum.find(
          fetch_flow_node_instances(process_instance_id),
          &(&1.flow_node_type == "user_task")
        )

      {status, error_body} =
        raw_finish(user_task_fni.id, %{"values" => %{"note" => String.duplicate("x", 70_000)}})

      assert status == 413
      assert error_body["error"] == "payload_too_large"
      assert error_body["field"] == "values"

      still_waiting =
        Enum.find(fetch_flow_node_instances(process_instance_id), &(&1.id == user_task_fni.id))

      assert still_waiting.state == "waiting"
    end

    test "rejects an unauthenticated finish" do
      conn =
        Plug.Test.conn(:put, "/user-tasks/any-id/finish", Jason.encode!(%{"values" => %{}}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> route()

      assert conn.status == 401
    end
  end

  describe "plugin facade user_tasks namespace" do
    test "finish forwards the action id into the task token" do
      {process_instance_id, user_task_flow_node_instance} = start_waiting_user_task()
      facade = FacadeBuilder.build("test:user_tasks")

      assert :ok =
               facade.user_tasks.finish.(
                 user_task_flow_node_instance.id,
                 %{"approved" => true},
                 "approve",
                 %Identity{id: "plugin-user"}
               )

      wait_for_process_instance(process_instance_id)

      finished =
        Enum.find(
          fetch_flow_node_instances(process_instance_id),
          &(&1.id == user_task_flow_node_instance.id)
        )

      assert finished.output_token == %{"actionId" => "approve", "values" => %{"approved" => true}}
    end

    test "finish without an action id writes a nil actionId" do
      {process_instance_id, user_task_flow_node_instance} = start_waiting_user_task()
      facade = FacadeBuilder.build("test:user_tasks")

      assert :ok =
               facade.user_tasks.finish.(
                 user_task_flow_node_instance.id,
                 nil,
                 nil,
                 %Identity{id: "plugin-user"}
               )

      wait_for_process_instance(process_instance_id)

      finished =
        Enum.find(
          fetch_flow_node_instances(process_instance_id),
          &(&1.id == user_task_flow_node_instance.id)
        )

      assert finished.output_token == %{"actionId" => nil, "values" => %{}}
    end

    test "finish rejects an invalid action id" do
      {_process_instance_id, user_task_flow_node_instance} = start_waiting_user_task()
      facade = FacadeBuilder.build("test:user_tasks")

      assert {:error, :invalid_action_id} =
               facade.user_tasks.finish.(
                 user_task_flow_node_instance.id,
                 %{},
                 "   ",
                 %Identity{id: "plugin-user"}
               )
    end
  end

  defp start_waiting_user_task do
    process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")

    {:ok, user_task_flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "user_task")

    {process_instance_id, user_task_flow_node_instance}
  end

  defp raw_finish(flow_node_instance_id, body) do
    conn =
      Plug.Test.conn(
        :put,
        "/user-tasks/#{flow_node_instance_id}/finish",
        Jason.encode!(body)
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt()}")
      |> route()

    {conn.status, Jason.decode!(conn.resp_body)}
  end
end
