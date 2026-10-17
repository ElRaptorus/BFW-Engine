defmodule BfwEngine.Integration.Auth.GraphqlVisibilityTest do
  @moduledoc """
  GraphQL visibility tests for PI/FNI authorization.

  Verifies that Ash policies correctly filter ProcessInstances and
  FlowNodeInstances based on:
  - Starter identity match
  - Lane-based access via `lane:<name>` claims
  - Default-lane FNI visibility
  - Row-level FNI lane filtering: a non-starter sees only laneless FNIs and
    FNIs on lanes they can read; the starter sees every FNI of their instance
  - `zeeky_boogie_doog` admin override and `observe_all`
  """
  use BfwEngine.ExecutionCase, async: false

  @get_pi_query """
  query GetProcessInstance($id: ID!) {
    getProcessInstance(id: $id) {
      id
      state
      startedBy
    }
  }
  """

  @list_pis_query """
  query ListProcessInstances {
    processInstances {
      results {
        id
        state
      }
    }
  }
  """

  @get_fni_query """
  query GetFlowNodeInstance($id: ID!) {
    getFlowNodeInstance(id: $id) {
      id
      flowNodeId
      laneName
    }
  }
  """

  @list_fnis_query """
  query ListFlowNodeInstances {
    flowNodeInstances {
      results {
        id
        flowNodeId
        processInstanceId
        laneName
      }
    }
  }
  """

  @list_process_instance_flow_node_instances_query """
  query ListProcessInstanceFlowNodeInstances($processInstanceId: ID!) {
    flowNodeInstances(filter: {processInstanceId: {eq: $processInstanceId}}) {
      results {
        id
        flowNodeId
        laneName
      }
    }
  }
  """

  @get_process_instance_with_flow_node_instances_query """
  query GetProcessInstanceWithFlowNodeInstances($id: ID!) {
    getProcessInstance(id: $id) {
      id
      flowNodeInstances {
        id
        flowNodeId
        laneName
      }
    }
  }
  """

  @two_lane_starter_claims %{"sub" => "two-lane-starter"}
  @lane_a_reader_claims %{"sub" => "lane-a-reader", "lane:LaneA" => "read"}

  # -------------------------------------------------------------------------
  # Setup: deploy + start a laned process
  # -------------------------------------------------------------------------

  defp start_laned_process do
    {201, _} = http_deploy("user_task_with_lane.bpmn")

    {201, body} =
      http_start(
        "LanedUserTask",
        %{},
        %{"sub" => "starter-user", "lane:Management" => "write"}
      )

    process_instance_id = body["processInstanceId"]
    Process.sleep(200)

    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    {process_instance_id, flow_node_instances}
  end

  defp start_default_lane_process do
    {201, _} = http_deploy("linear_start_end.bpmn")
    {201, body} = http_start("LinearStartEnd", %{}, %{"sub" => "default-lane-starter"})
    process_instance_id = body["processInstanceId"]
    wait_for_process_instance(process_instance_id)
    process_instance_id
  end

  defp start_two_lane_process do
    {201, _} = http_deploy("lane_visibility_two_lanes.bpmn")
    {201, body} = http_start("LaneVisibilityTwoLanes", %{}, @two_lane_starter_claims)
    process_instance_id = body["processInstanceId"]

    {:ok, _} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_A")
    {:ok, lane_b_task} = await_waiting_fni_by_node_id(process_instance_id, "UserTask_B")
    {process_instance_id, lane_b_task}
  end

  defp list_two_lane_flow_node_ids(process_instance_id, claims) do
    {200, body} =
      http_graphql(
        @list_process_instance_flow_node_instances_query,
        %{"processInstanceId" => process_instance_id},
        claims
      )

    body["data"]["flowNodeInstances"]["results"]
    |> Enum.map(& &1["flowNodeId"])
    |> MapSet.new()
  end

  defp nested_flow_node_ids(process_instance_id, claims) do
    {200, body} =
      http_graphql(
        @get_process_instance_with_flow_node_instances_query,
        %{"id" => process_instance_id},
        claims
      )

    body["data"]["getProcessInstance"]["flowNodeInstances"]
    |> Enum.map(& &1["flowNodeId"])
    |> MapSet.new()
  end

  defp all_flow_node_ids(process_instance_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.map(& &1.flow_node_id)
    |> MapSet.new()
  end

  # -------------------------------------------------------------------------
  # PI visibility
  # -------------------------------------------------------------------------

  describe "PI visibility: starter match" do
    test "starter can see their own PI" do
      {process_instance_id, _} = start_laned_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "starter-user", "lane:Management" => "write"}
        )

      assert body["data"]["getProcessInstance"]["id"] == process_instance_id
    end

    test "non-starter without lane claim cannot see PI" do
      {process_instance_id, _} = start_laned_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "other-user"}
        )

      assert body["data"]["getProcessInstance"] == nil
    end
  end

  describe "PI visibility: lane-based access" do
    test "user with matching lane claim can see PI" do
      {process_instance_id, _} = start_laned_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "lane-user", "lane:Management" => "write"}
        )

      assert body["data"]["getProcessInstance"]["id"] == process_instance_id
    end

    test "user with read-only lane claim can see PI" do
      {process_instance_id, _} = start_laned_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "lane-reader", "lane:Management" => "read"}
        )

      assert body["data"]["getProcessInstance"]["id"] == process_instance_id
    end

    test "leftover boolean true lane claim cannot see PI" do
      {process_instance_id, _} = start_laned_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "legacy-true", "lane:Management" => true}
        )

      assert body["data"]["getProcessInstance"] == nil
    end

    test "garbage lane values cannot see PI" do
      {process_instance_id, _} = start_laned_process()

      for {label, garbage} <- [
            {"write-upper", "WRITE"},
            {"read-upper", "READ"},
            {"empty", ""},
            {"int", 1}
          ] do
        {200, body} =
          http_graphql(
            @get_pi_query,
            %{"id" => process_instance_id},
            %{"sub" => "garbage-#{label}", "lane:Management" => garbage}
          )

        assert body["data"]["getProcessInstance"] == nil
      end
    end

    test "user without matching lane claim cannot see PI (not starter either)" do
      {process_instance_id, _} = start_laned_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "wrong-lane-user", "lane:Engineering" => "write"}
        )

      assert body["data"]["getProcessInstance"] == nil
    end
  end

  describe "PI visibility: default lane" do
    test "user with default lane claim can see PI with default lane" do
      process_instance_id = start_default_lane_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "random-user"}
        )

      assert body["data"]["getProcessInstance"]["id"] == process_instance_id
    end

    test "user without any lane claim cannot see PI with default lane (not starter)" do
      process_instance_id = start_default_lane_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "no-claims-user", "lane:default" => nil}
        )

      assert body["data"]["getProcessInstance"] == nil
    end
  end

  describe "PI visibility: admin override" do
    test "zeeky_boogie_doog sees all PIs" do
      {process_instance_id, _} = start_laned_process()

      {200, body} =
        http_graphql(
          @get_pi_query,
          %{"id" => process_instance_id},
          %{"sub" => "admin-user", "zeeky_boogie_doog" => true}
        )

      assert body["data"]["getProcessInstance"]["id"] == process_instance_id
    end
  end

  describe "PI list filtering" do
    test "processInstances list only returns visible PIs" do
      {laned_process_instance_id, _} = start_laned_process()
      default_lane_process_instance_id = start_default_lane_process()

      {200, body} =
        http_graphql(
          @list_pis_query,
          %{},
          %{"sub" => "default-only-user"}
        )

      results = body["data"]["processInstances"]["results"]
      ids = Enum.map(results, & &1["id"])

      assert default_lane_process_instance_id in ids
      refute laned_process_instance_id in ids
    end
  end

  # -------------------------------------------------------------------------
  # FNI visibility (cascaded from PI)
  # -------------------------------------------------------------------------

  describe "FNI visibility: cascaded from PI" do
    test "FNI within visible PI is returned" do
      {_process_instance_id, flow_node_instances} = start_laned_process()
      flow_node_instance = hd(flow_node_instances)

      {200, body} =
        http_graphql(
          @get_fni_query,
          %{"id" => flow_node_instance.id},
          %{"sub" => "starter-user", "lane:Management" => "write"}
        )

      assert body["data"]["getFlowNodeInstance"]["id"] == flow_node_instance.id
    end

    test "FNI within invisible PI returns null" do
      {_process_instance_id, flow_node_instances} = start_laned_process()
      flow_node_instance = hd(flow_node_instances)

      {200, body} =
        http_graphql(
          @get_fni_query,
          %{"id" => flow_node_instance.id},
          %{"sub" => "other-user"}
        )

      assert body["data"]["getFlowNodeInstance"] == nil
    end
  end

  describe "FNI list filtering" do
    test "flowNodeInstances list filtered to visible PIs only" do
      {laned_process_instance_id, _} = start_laned_process()
      default_lane_process_instance_id = start_default_lane_process()

      {200, body} =
        http_graphql(
          @list_fnis_query,
          %{},
          %{"sub" => "default-only-user"}
        )

      results = body["data"]["flowNodeInstances"]["results"]
      process_instance_ids = results |> Enum.map(& &1["processInstanceId"]) |> MapSet.new()

      assert MapSet.member?(process_instance_ids, default_lane_process_instance_id)
      refute MapSet.member?(process_instance_ids, laned_process_instance_id)
    end
  end

  describe "FNI visibility: row-level lane filtering" do
    test "LaneA reader sees laneless and LaneA FNIs but not LaneB FNIs" do
      {process_instance_id, _lane_b_task} = start_two_lane_process()

      visible = list_two_lane_flow_node_ids(process_instance_id, @lane_a_reader_claims)

      assert MapSet.equal?(visible, MapSet.new(["StartEvent_1", "Gateway_Split", "UserTask_A"]))
      refute MapSet.member?(visible, "UserTask_B")
    end

    test "getFlowNodeInstance on a LaneB FNI returns null for a LaneA reader" do
      {_process_instance_id, lane_b_task} = start_two_lane_process()

      {200, body} =
        http_graphql(@get_fni_query, %{"id" => lane_b_task.id}, @lane_a_reader_claims)

      assert body["data"]["getFlowNodeInstance"] == nil
    end

    test "starter without lane claims sees every FNI of their instance" do
      {process_instance_id, _lane_b_task} = start_two_lane_process()

      visible = list_two_lane_flow_node_ids(process_instance_id, @two_lane_starter_claims)

      assert MapSet.equal?(visible, all_flow_node_ids(process_instance_id))
      assert MapSet.member?(visible, "UserTask_A")
      assert MapSet.member?(visible, "UserTask_B")
    end

    test "nested processInstance { flowNodeInstances } follows the row-level rule" do
      {process_instance_id, _lane_b_task} = start_two_lane_process()

      lane_a_visible = nested_flow_node_ids(process_instance_id, @lane_a_reader_claims)
      assert MapSet.member?(lane_a_visible, "UserTask_A")
      refute MapSet.member?(lane_a_visible, "UserTask_B")

      starter_visible = nested_flow_node_ids(process_instance_id, @two_lane_starter_claims)
      assert MapSet.equal?(starter_visible, all_flow_node_ids(process_instance_id))
    end

    test "observe_all sees every FNI of a foreign instance" do
      {process_instance_id, _lane_b_task} = start_two_lane_process()

      visible =
        list_two_lane_flow_node_ids(process_instance_id, %{
          "sub" => "observer",
          "observe_all" => true
        })

      assert MapSet.equal?(visible, all_flow_node_ids(process_instance_id))
    end
  end
end
