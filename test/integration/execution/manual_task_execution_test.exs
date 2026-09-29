defmodule BfwEngine.Integration.Execution.ManualTaskExecutionTest do
  @moduledoc """
  Integration tests for Manual Task execution with requireConfirmation and
  the `PUT /manual-tasks/:fni_id/confirm` and `/cancel` endpoints.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Plugins.Loader
  alias BfwEngine.Types.Identity

  @entered_payload %{"step" => "pack"}

  defp start_confirming_manual_task do
    {201, _} = http_deploy("manual_task_confirm.bpmn")
    {201, body} = http_start("ManualTaskConfirm", %{"payload" => @entered_payload})
    process_instance_id = body["processInstanceId"]

    {:ok, manual_task_flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "manual_task")

    {process_instance_id, manual_task_flow_node_instance}
  end

  defp start_waiting_user_task do
    process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")

    {:ok, user_task_flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "user_task")

    {process_instance_id, user_task_flow_node_instance}
  end

  defp finished_flow_node_instance(process_instance_id, flow_node_instance_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.find(&(&1.id == flow_node_instance_id))
  end

  describe "PUT /manual-tasks/:fni_id/confirm" do
    test "confirms the waiting manual task and the entered token passes through" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()
      assert manual_task_flow_node_instance.state == "waiting"

      {204, nil} = http_confirm_manual_task(manual_task_flow_node_instance.id)

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")

      finished_manual_task =
        finished_flow_node_instance(process_instance_id, manual_task_flow_node_instance.id)

      assert finished_manual_task.finished_at != nil
      assert finished_manual_task.output_token == @entered_payload
    end

    test "ignores a request body and keeps the entered token" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      conn =
        Plug.Test.conn(
          :put,
          "/manual-tasks/#{manual_task_flow_node_instance.id}/confirm",
          Jason.encode!(%{"result" => %{"confirmed" => true}, "step" => "overwritten"})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt()}")
        |> route()

      assert conn.status == 204

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")

      finished_manual_task =
        finished_flow_node_instance(process_instance_id, manual_task_flow_node_instance.id)

      assert finished_manual_task.output_token == @entered_payload
    end

    test "ignores an oversized result body and keeps the entered token" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      conn =
        Plug.Test.conn(
          :put,
          "/manual-tasks/#{manual_task_flow_node_instance.id}/confirm",
          Jason.encode!(%{"result" => String.duplicate("x", 70_000)})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt()}")
        |> route()

      assert conn.status == 204

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")

      finished_manual_task =
        finished_flow_node_instance(process_instance_id, manual_task_flow_node_instance.id)

      assert finished_manual_task.output_token == @entered_payload
    end

    test "returns 404 for a waiting user task" do
      {process_instance_id, user_task_flow_node_instance} = start_waiting_user_task()

      {404, body} = http_confirm_manual_task(user_task_flow_node_instance.id)
      assert body["error"] == "not_found"

      assert_pi_state!(process_instance_id, "running")
    end

    test "returns 404 for a non-existent flow node instance" do
      {404, body} = http_confirm_manual_task(Ash.UUIDv7.generate())
      assert body["error"] == "not_found"
    end

    test "returns 403 when the caller has only read access to the task lane" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {403, body} =
        http_confirm_manual_task(manual_task_flow_node_instance.id, %{
          "sub" => "reader",
          "lane:default" => "read"
        })

      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:default"
      assert body["requiredValue"] == "write"
      assert_pi_state!(process_instance_id, "running")
    end

    test "returns 404 when the caller has no access to the task lane" do
      {_process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {404, body} =
        http_confirm_manual_task(manual_task_flow_node_instance.id, %{
          "sub" => "no-lane-user",
          "lane:default" => nil
        })

      assert body["error"] == "not_found"
    end

    test "returns 422 for an already-confirmed manual task" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {204, nil} = http_confirm_manual_task(manual_task_flow_node_instance.id)
      wait_for_process_instance(process_instance_id)

      {422, body} = http_confirm_manual_task(manual_task_flow_node_instance.id)
      assert body["error"] in ["fni_already_finished", "fni_not_waiting"]
    end

    test "returns 404 when a caller who cannot observe the lane confirms or cancels an already-confirmed manual task" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()
      claims_without_lane = %{"sub" => "no-lane-user", "lane:default" => nil}

      {204, nil} = http_confirm_manual_task(manual_task_flow_node_instance.id)
      wait_for_process_instance(process_instance_id)

      {404, confirm_body} =
        http_confirm_manual_task(manual_task_flow_node_instance.id, claims_without_lane)

      assert confirm_body["error"] == "not_found"

      {404, cancel_body} =
        http_cancel_manual_task(manual_task_flow_node_instance.id, "reason", claims_without_lane)

      assert cancel_body["error"] == "not_found"
      assert_pi_state!(process_instance_id, "finished")
    end

    test "returns 401 without a bearer token" do
      {_process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      conn =
        Plug.Test.conn(:put, "/manual-tasks/#{manual_task_flow_node_instance.id}/confirm")
        |> route()

      assert conn.status == 401
    end
  end

  describe "PUT /manual-tasks/:fni_id/cancel" do
    test "cancels the waiting manual task and aborts the process instance" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {204, nil} = http_cancel_manual_task(manual_task_flow_node_instance.id, "no longer needed")

      assert_pi_state!(process_instance_id, "aborted")

      aborted_manual_task =
        finished_flow_node_instance(process_instance_id, manual_task_flow_node_instance.id)

      assert aborted_manual_task.state == "aborted"
    end

    test "returns 404 for a waiting user task" do
      {process_instance_id, user_task_flow_node_instance} = start_waiting_user_task()

      {404, body} = http_cancel_manual_task(user_task_flow_node_instance.id, "reason")
      assert body["error"] == "not_found"

      assert_pi_state!(process_instance_id, "running")
    end

    test "returns 404 for a non-existent flow node instance" do
      {404, body} = http_cancel_manual_task(Ash.UUIDv7.generate(), "reason")
      assert body["error"] == "not_found"
    end

    test "returns 403 when the caller has only read access to the task lane" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {403, body} =
        http_cancel_manual_task(manual_task_flow_node_instance.id, "reason", %{
          "sub" => "reader",
          "lane:default" => "read"
        })

      assert body["error"] == "forbidden"
      assert_pi_state!(process_instance_id, "running")
    end

    test "returns 422 for an already-confirmed manual task" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {204, nil} = http_confirm_manual_task(manual_task_flow_node_instance.id)
      wait_for_process_instance(process_instance_id)

      {422, body} = http_cancel_manual_task(manual_task_flow_node_instance.id, "reason")
      assert body["error"] in ["fni_already_finished", "fni_not_waiting"]
    end
  end

  describe "BfwEngine.Api task type checks" do
    test "confirm_manual_task rejects a user task with :not_a_manual_task" do
      {_process_instance_id, user_task_flow_node_instance} = start_waiting_user_task()

      assert {:error, :not_a_manual_task} =
               BfwEngine.Api.confirm_manual_task(
                 user_task_flow_node_instance.id,
                 %Identity{id: "api-user"},
                 skip_claims: true
               )

      assert {:error, :not_a_manual_task} =
               BfwEngine.Api.cancel_manual_task(
                 user_task_flow_node_instance.id,
                 "reason",
                 %Identity{id: "api-user"},
                 skip_claims: true
               )
    end

    test "finish_user_task and cancel_user_task reject a manual task with :not_a_user_task" do
      {_process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      assert {:error, :not_a_user_task} =
               BfwEngine.Api.finish_user_task(
                 manual_task_flow_node_instance.id,
                 %{},
                 %Identity{id: "api-user"},
                 skip_claims: true
               )

      assert {:error, :not_a_user_task} =
               BfwEngine.Api.cancel_user_task(
                 manual_task_flow_node_instance.id,
                 "reason",
                 %Identity{id: "api-user"},
                 skip_claims: true
               )
    end

    test "confirm_manual_task returns :not_found for an unknown flow node instance" do
      assert {:error, :not_found} =
               BfwEngine.Api.confirm_manual_task(
                 Ash.UUIDv7.generate(),
                 %Identity{id: "api-user"},
                 skip_claims: true
               )
    end
  end

  describe "plugin facade manual_tasks namespace" do
    test "confirm finishes the manual task with the entered token" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()
      facade = Loader.facade_for_plugin("test:manual_tasks")

      assert :ok =
               facade.manual_tasks.confirm.(
                 manual_task_flow_node_instance.id,
                 %Identity{id: "plugin-user"}
               )

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")

      finished_manual_task =
        finished_flow_node_instance(process_instance_id, manual_task_flow_node_instance.id)

      assert finished_manual_task.output_token == @entered_payload
    end

    test "cancel aborts the process instance" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()
      facade = Loader.facade_for_plugin("test:manual_tasks")

      assert :ok =
               facade.manual_tasks.cancel.(
                 manual_task_flow_node_instance.id,
                 "plugin cancel",
                 %Identity{id: "plugin-user"}
               )

      assert_pi_state!(process_instance_id, "aborted")
    end
  end

  describe "user task endpoints reject manual tasks" do
    test "PUT /user-tasks/:fni_id/finish returns 404 for a waiting manual task" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {404, body} = http_finish_user_task(manual_task_flow_node_instance.id, %{})
      assert body["error"] == "not_found"

      assert_pi_state!(process_instance_id, "running")
    end

    test "PUT /user-tasks/:fni_id/cancel returns 404 for a waiting manual task" do
      {process_instance_id, manual_task_flow_node_instance} = start_confirming_manual_task()

      {404, body} = http_cancel_user_task(manual_task_flow_node_instance.id, "reason")
      assert body["error"] == "not_found"

      assert_pi_state!(process_instance_id, "running")
    end
  end
end
