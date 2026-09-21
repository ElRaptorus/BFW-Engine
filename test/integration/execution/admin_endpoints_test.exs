defmodule BfwEngine.Integration.Execution.AdminEndpointsTest do
  @moduledoc """
  Integration tests for the REST admin endpoints:
  - PUT /user-tasks/:fni_id/finish
  - PUT /user-tasks/:fni_id/cancel
  - PUT /process-instances/:id/abort
  - DELETE /process-instances/:id

  All tests are strictly black-box (HTTP round-trips only).
  """
  use BfwEngine.ExecutionCase, async: false

  # ===========================================================================
  # Finish User Task
  # ===========================================================================

  describe "PUT /user-tasks/:fni_id/finish" do
    test "finishes a waiting user task and completes the PI" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)

      {204, nil} = http_finish_user_task(flow_node_instance.id, %{"approved" => true})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "returns 404 for non-existent FNI" do
      {404, body} = http_finish_user_task(Ash.UUIDv7.generate(), %{})
      assert body["error"] == "not_found"
    end

    test "returns 422 for already-finished FNI" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)

      {204, _} = http_finish_user_task(flow_node_instance.id, %{"approved" => true})
      wait_for_process_instance(process_instance_id)

      {422, body} = http_finish_user_task(flow_node_instance.id, %{"approved" => true})
      assert body["error"] in ["fni_already_finished", "fni_not_waiting"]
    end
  end

  # ===========================================================================
  # Cancel User Task
  # ===========================================================================

  describe "PUT /user-tasks/:fni_id/cancel" do
    test "cancels a waiting user task and aborts the PI" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)

      {204, nil} = http_cancel_user_task(flow_node_instance.id, "no longer needed")

      assert_pi_state!(process_instance_id, "aborted")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      aborted_fni = Enum.find(flow_node_instances, &(&1.id == flow_node_instance.id))
      assert aborted_fni.state == "aborted"
    end

    test "returns 404 for non-existent FNI" do
      {404, body} = http_cancel_user_task(Ash.UUIDv7.generate(), "reason")
      assert body["error"] == "not_found"
    end
  end

  # ===========================================================================
  # Abort Process Instance
  # ===========================================================================

  describe "PUT /process-instances/:id/abort" do
    test "aborts a running process instance" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      claims = %{"abort_process_instance" => "all"}
      {204, nil} = http_abort_process_instance(process_instance_id, "testing abort", claims)

      assert_pi_state!(process_instance_id, "aborted")
    end

    test "returns 404 for non-existent PI" do
      claims = %{"abort_process_instance" => "all"}
      {404, body} = http_abort_process_instance(Ash.UUIDv7.generate(), nil, claims)
      assert body["error"] == "not_found"
    end
  end

  # ===========================================================================
  # Authorization — Abort
  # ===========================================================================

  describe "abort authorization" do
    test "403 when abort_process_instance claim is absent" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      {403, body} = http_abort_process_instance(process_instance_id)
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "abort_process_instance"
    end

    test "403 when abort_process_instance=none" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      claims = %{"abort_process_instance" => "none"}
      {403, body} = http_abort_process_instance(process_instance_id, nil, claims)
      assert body["error"] == "forbidden"
    end

    test "403 when abort_process_instance=own but PI started by different user" do
      other_user_claims = %{"sub" => "other-user"}
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, start_body} = http_start("UserTaskSimple", %{}, other_user_claims)
      process_instance_id = start_body["processInstanceId"]
      Process.sleep(200)

      abort_claims = %{"sub" => "attacker", "abort_process_instance" => "own"}
      {403, body} = http_abort_process_instance(process_instance_id, nil, abort_claims)
      assert body["error"] == "forbidden"
    end

    test "204 when abort_process_instance=own and PI started by same user" do
      user_claims = %{"sub" => "owner-user"}
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, start_body} = http_start("UserTaskSimple", %{}, user_claims)
      process_instance_id = start_body["processInstanceId"]
      Process.sleep(200)

      abort_claims = %{"sub" => "owner-user", "abort_process_instance" => "own"}
      {204, nil} = http_abort_process_instance(process_instance_id, nil, abort_claims)
      assert_pi_state!(process_instance_id, "aborted")
    end

    test "204 when abort_process_instance=all regardless of starter" do
      other_user_claims = %{"sub" => "someone-else"}
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, start_body} = http_start("UserTaskSimple", %{}, other_user_claims)
      process_instance_id = start_body["processInstanceId"]
      Process.sleep(200)

      admin_claims = %{"sub" => "admin", "abort_process_instance" => "all"}
      {204, _} = http_abort_process_instance(process_instance_id, nil, admin_claims)
      assert_pi_state!(process_instance_id, "aborted")
    end
  end

  # ===========================================================================
  # Authorization — User Task finish/cancel (lane visibility)
  # ===========================================================================

  describe "user task authorization (lane visibility)" do
    test "404 when caller lacks the lane claim for a laned user task" do
      process_instance_id = deploy_and_start_laned_user_task()
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)
      assert flow_node_instance.lane_name != nil

      claims_without_lane = %{"sub" => "no-lane-user"}
      {404, body} = http_finish_user_task(flow_node_instance.id, %{}, claims_without_lane)
      assert body["error"] == "not_found"
    end

    test "204 when caller has the correct lane claim" do
      process_instance_id = deploy_and_start_laned_user_task()
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)
      lane_name = flow_node_instance.lane_name

      claims_with_lane = %{"sub" => "lane-user", "lane:#{lane_name}" => "write"}
      {204, nil} = http_finish_user_task(flow_node_instance.id, %{}, claims_with_lane)
    end

    test "403 when caller has a read claim on the task lane" do
      process_instance_id = deploy_and_start_laned_user_task()
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)
      lane_name = flow_node_instance.lane_name

      {403, body} =
        http_finish_user_task(flow_node_instance.id, %{}, %{
          "sub" => "reader",
          "lane:#{lane_name}" => "read"
        })

      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:#{lane_name}"
      assert body["requiredValue"] == "write"
    end

    test "404 when leftover boolean true is not a write alias" do
      process_instance_id = deploy_and_start_laned_user_task()
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)
      lane_name = flow_node_instance.lane_name

      {404, body} =
        http_finish_user_task(flow_node_instance.id, %{}, %{
          "sub" => "legacy-true",
          "lane:#{lane_name}" => true
        })

      assert body["error"] == "not_found"
    end

    test "204 when caller has matching default lane claim" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)
      assert flow_node_instance.lane_name == "default"

      {204, nil} = http_finish_user_task(flow_node_instance.id, %{"done" => true})
    end

    test "cancel returns 403 when caller has a read claim on the task lane" do
      process_instance_id = deploy_and_start_laned_user_task()
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)
      lane_name = flow_node_instance.lane_name

      {403, body} =
        http_cancel_user_task(flow_node_instance.id, "reason", %{
          "sub" => "reader",
          "lane:#{lane_name}" => "read"
        })

      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:#{lane_name}"
      assert body["requiredValue"] == "write"
    end

    test "cancel returns 404 when caller lacks lane claim" do
      process_instance_id = deploy_and_start_laned_user_task()
      Process.sleep(200)

      flow_node_instance = waiting_user_task_fni!(process_instance_id)

      claims_without_lane = %{"sub" => "no-lane-user"}
      {404, body} = http_cancel_user_task(flow_node_instance.id, "reason", claims_without_lane)
      assert body["error"] == "not_found"
    end
  end

  # ===========================================================================
  # Delete Process Instance
  # ===========================================================================

  describe "DELETE /process-instances/:id" do
    test "deletes a terminal PI and cascades to FNIs" do
      process_instance_id = http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")
      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")

      fni_count_before = length(fetch_flow_node_instances(process_instance_id))
      assert fni_count_before > 0

      {204, nil} = http_delete_process_instance(process_instance_id)

      assert fetch_process_instance(process_instance_id) == nil
      assert fetch_flow_node_instances(process_instance_id) == []
    end

    test "returns 422 for a running PI" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")
      Process.sleep(200)

      {422, body} = http_delete_process_instance(process_instance_id)
      assert body["error"] == "process_instance_not_terminal"
    end

    test "returns 404 for an already-deleted PI (prevents existence probing)" do
      process_instance_id = http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")
      wait_for_process_instance(process_instance_id)

      {204, _} = http_delete_process_instance(process_instance_id)
      {404, body} = http_delete_process_instance(process_instance_id)
      assert body["error"] == "not_found"
    end

    test "returns 404 for non-existent PI" do
      {404, body} = http_delete_process_instance(Ash.UUIDv7.generate())
      assert body["error"] == "not_found"
    end
  end

  # ===========================================================================
  # Authorization — Delete
  # ===========================================================================

  describe "delete authorization" do
    test "403 when delete_process_instance claim is absent" do
      process_instance_id = http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")
      wait_for_process_instance(process_instance_id)

      {403, body} =
        http_delete_process_instance(process_instance_id, %{"delete_process_instance" => "none"})

      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "delete_process_instance"
    end

    test "403 when delete_process_instance=own but PI started by different user" do
      other_user_claims = %{"sub" => "other-user"}
      {201, _} = http_deploy("linear_start_end.bpmn")
      {201, start_body} = http_start("LinearStartEnd", %{}, other_user_claims)
      process_instance_id = start_body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      delete_claims = %{"sub" => "attacker", "delete_process_instance" => "own"}
      {403, body} = http_delete_process_instance(process_instance_id, delete_claims)
      assert body["error"] == "forbidden"
    end

    test "204 when delete_process_instance=own and PI started by same user" do
      user_claims = %{"sub" => "owner-user"}
      {201, _} = http_deploy("linear_start_end.bpmn")
      {201, start_body} = http_start("LinearStartEnd", %{}, user_claims)
      process_instance_id = start_body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      delete_claims = %{"sub" => "owner-user", "delete_process_instance" => "own"}
      {204, nil} = http_delete_process_instance(process_instance_id, delete_claims)
    end

    test "204 when delete_process_instance=all regardless of starter" do
      other_user_claims = %{"sub" => "someone-else"}
      {201, _} = http_deploy("linear_start_end.bpmn")
      {201, start_body} = http_start("LinearStartEnd", %{}, other_user_claims)
      process_instance_id = start_body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      admin_claims = %{"sub" => "admin", "delete_process_instance" => "all"}
      {204, _} = http_delete_process_instance(process_instance_id, admin_claims)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp waiting_user_task_fni!(process_instance_id) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    flow_node_instance =
      Enum.find(flow_node_instances, fn flow_node_instance_candidate ->
        flow_node_instance_candidate.flow_node_type in ["user_task", "manual_task"] and
          flow_node_instance_candidate.state == "waiting"
      end)

    assert flow_node_instance != nil,
           "Expected a waiting user/manual task FNI for PI #{process_instance_id}"

    flow_node_instance
  end

  defp deploy_and_start_laned_user_task do
    {201, _} = http_deploy("user_task_with_lane.bpmn")
    {201, body} = http_start("LanedUserTask", %{}, %{"lane:Management" => "write"})
    body["processInstanceId"]
  end
end
