defmodule BfwEngine.Integration.Auth.ObserveAllAuthorizationTest do
  @moduledoc """
  Live authorization matrix for `observe_all`.

  `observe_all: true` grants unbounded read/observe (GraphQL PI visibility,
  WS join). It never grants write: start, finish, cancel, timer trigger,
  deploy, and abort stay 403. Soft-deleted PIs remain invisible.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @get_pi_query """
  query GetProcessInstance($id: ID!) {
    getProcessInstance(id: $id) {
      id
      state
    }
  }
  """

  defp observer_claims(extra \\ %{}) do
    Map.merge(
      %{"sub" => "observer", "observe_all" => true, "lane:default" => nil},
      extra
    )
  end

  defp start_laned_user_task do
    {201, _} = http_deploy("user_task_with_lane.bpmn")

    {201, body} =
      http_start("LanedUserTask", %{}, %{
        "sub" => "starter-user",
        "lane:Management" => "write"
      })

    process_instance_id = body["processInstanceId"]
    Process.sleep(200)
    process_instance_id
  end

  defp waiting_user_task_fni!(process_instance_id) do
    flow_node_instance =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.find(fn flow_node_instance ->
        flow_node_instance.flow_node_type == "user_task" and
          flow_node_instance.state in ["waiting", "active"]
      end)

    assert flow_node_instance != nil,
           "Expected a waiting user task FNI for PI #{process_instance_id}"

    flow_node_instance
  end

  describe "observe_all cannot act" do
    test "start on a laned process returns 403" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      {403, body} = http_start("LanedUserTask", %{}, observer_claims())
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:Management"
      assert body["requiredValue"] == "write"
    end

    test "start on the default lane returns 403 when default write is stripped" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {403, body} = http_start("LinearStartEnd", %{}, observer_claims())
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:default"
      assert body["requiredValue"] == "write"
    end

    test "finish user task returns 403" do
      process_instance_id = start_laned_user_task()
      flow_node_instance = waiting_user_task_fni!(process_instance_id)

      {403, body} = http_finish_user_task(flow_node_instance.id, %{}, observer_claims())
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:#{flow_node_instance.lane_name}"
      assert body["requiredValue"] == "write"
    end

    test "cancel user task returns 403" do
      process_instance_id = start_laned_user_task()
      flow_node_instance = waiting_user_task_fni!(process_instance_id)

      {403, body} = http_cancel_user_task(flow_node_instance.id, "nope", observer_claims())
      assert body["error"] == "forbidden"
    end

    test "deploy remains 403" do
      {403, body} =
        http_deploy("linear_start_end.bpmn", observer_claims(%{"deploy_bpmn" => false}))

      assert body["error"] == "forbidden"
    end

    test "abort remains 403" do
      process_instance_id = start_laned_user_task()

      {403, body} = http_abort_process_instance(process_instance_id, "stop", observer_claims())
      assert body["error"] == "forbidden"
    end
  end

  describe "observe_all can observe" do
    test "GraphQL getProcessInstance returns a foreign-lane PI" do
      process_instance_id = start_laned_user_task()

      {200, body} =
        http_graphql(@get_pi_query, %{"id" => process_instance_id}, observer_claims())

      assert body["data"]["getProcessInstance"]["id"] == process_instance_id
    end

    test "soft-deleted process instance stays invisible" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {201, body} =
        http_start("LinearStartEnd", %{}, %{
          "sub" => "starter-user",
          "lane:default" => "write"
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      {204, _} =
        http_delete_process_instance(process_instance_id, %{
          "sub" => "cleaner",
          "delete_process_instance" => "all"
        })

      {200, body} =
        http_graphql(@get_pi_query, %{"id" => process_instance_id}, observer_claims())

      assert body["data"]["getProcessInstance"] == nil
    end
  end

  describe "observe_all composed with a write lane" do
    test "finish succeeds on the writable lane" do
      process_instance_id = start_laned_user_task()
      flow_node_instance = waiting_user_task_fni!(process_instance_id)

      {204, nil} =
        http_finish_user_task(
          flow_node_instance.id,
          %{},
          observer_claims(%{"lane:Management" => "write"})
        )
    end

    test "start still 403 on a lane the observer cannot write" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      {403, body} =
        http_start(
          "LanedUserTask",
          %{},
          observer_claims(%{"lane:Engineering" => "write"})
        )

      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:Management"
      assert body["requiredValue"] == "write"
    end
  end
end
