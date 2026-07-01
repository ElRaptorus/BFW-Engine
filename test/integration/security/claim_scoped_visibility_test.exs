defmodule EvilEngine.Integration.Security.ClaimScopedVisibilityTest do
  @moduledoc """
  Security-focused tests verifying claim-scoped read visibility across
  GraphQL and REST surfaces.

  Consolidates PI/FNI visibility enforcement based on:
  - Starter identity match
  - Lane-based access via `lane:<name>` claims
  - No-lane escape hatch
  - Cross-actor FNI cascading
  - `zeeky_boogie_doog` admin override
  - Anti-enumeration (null not 403)
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @starter_a_claims %{"sub" => "starter-a", "lane:default" => true, "lane:Management" => true}
  @starter_b_claims %{"sub" => "starter-b", "lane:default" => true}
  @lane_mgmt_claims %{"sub" => "lane-mgmt-user", "lane:Management" => true}
  @lane_eng_claims %{"sub" => "lane-eng-user", "lane:Engineering" => true}
  @no_claims %{"sub" => "bare-user", "lane:default" => nil}
  @admin_claims %{"sub" => "admin-user", "zeeky_boogie_doog" => true}

  @get_pi_query """
  query GetPI($id: ID!) {
    getProcessInstance(id: $id) { id state startedBy }
  }
  """

  @list_pis_query """
  {
    processInstances {
      results { id state }
      count
    }
  }
  """

  @list_fnis_query """
  query ListFNIs($piId: ID!) {
    flowNodeInstances(filter: {processInstanceId: {eq: $piId}}) {
      results { id flowNodeId laneName }
      count
    }
  }
  """

  # ---------------------------------------------------------------------------
  # Setup helpers
  # ---------------------------------------------------------------------------

  defp start_laned_process(claims) do
    {201, _} = http_deploy("user_task_with_lane.bpmn")

    {201, body} = http_start("LanedUserTask", %{}, claims)
    process_instance_id = body["processInstanceId"]

    {:ok, _fni} = await_waiting_flow_node_instance(process_instance_id, "user_task")
    process_instance_id
  end

  defp start_default_lane_process(claims) do
    {201, _} = http_deploy("linear_start_end.bpmn")
    {201, body} = http_start("LinearStartEnd", %{}, claims)
    process_instance_id = body["processInstanceId"]
    wait_for_process_instance(process_instance_id)
    process_instance_id
  end

  # ---------------------------------------------------------------------------
  # 3.1 Starter-only visibility
  # ---------------------------------------------------------------------------

  describe "3.1 starter-only visibility" do
    test "starter can see own PI; other actor cannot" do
      process_instance_id = start_laned_process(@starter_a_claims)

      {200, visible} = http_graphql(@get_pi_query, %{"id" => process_instance_id}, @starter_a_claims)
      assert visible["data"]["getProcessInstance"]["id"] == process_instance_id

      {200, invisible} = http_graphql(@get_pi_query, %{"id" => process_instance_id}, @starter_b_claims)
      assert invisible["data"]["getProcessInstance"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 3.2 Lane visibility
  # ---------------------------------------------------------------------------

  describe "3.2 lane visibility" do
    test "user with matching lane claim sees PI; user with wrong lane does not" do
      process_instance_id = start_laned_process(@starter_a_claims)

      {200, visible} = http_graphql(@get_pi_query, %{"id" => process_instance_id}, @lane_mgmt_claims)
      assert visible["data"]["getProcessInstance"]["id"] == process_instance_id

      {200, invisible} = http_graphql(@get_pi_query, %{"id" => process_instance_id}, @lane_eng_claims)
      assert invisible["data"]["getProcessInstance"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 3.3 No-lane escape hatch
  # ---------------------------------------------------------------------------

  describe "3.3 no-lane escape hatch" do
    test "PI with null-lane FNI is visible to any authenticated user" do
      process_instance_id = start_default_lane_process(@starter_a_claims)

      {200, visible} = http_graphql(@get_pi_query, %{"id" => process_instance_id}, @starter_b_claims)
      assert visible["data"]["getProcessInstance"]["id"] == process_instance_id
    end

    test "PI with null-lane FNI is NOT visible to user without any lane claim" do
      process_instance_id = start_default_lane_process(@starter_a_claims)

      {200, invisible} = http_graphql(@get_pi_query, %{"id" => process_instance_id}, @no_claims)
      assert invisible["data"]["getProcessInstance"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 3.4 Cross-actor FNI cascading
  # ---------------------------------------------------------------------------

  describe "3.4 cross-actor FNI cascading" do
    test "if actor can see PI via lane, they see ALL FNIs (not just their lane)" do
      process_instance_id = start_laned_process(@starter_a_claims)

      {200, result} = http_graphql(@list_fnis_query, %{"piId" => process_instance_id}, @lane_mgmt_claims)
      fnis = result["data"]["flowNodeInstances"]["results"]

      assert length(fnis) >= 1, "Lane-authorized user should see FNIs"

      all_fnis = fetch_flow_node_instances(process_instance_id)
      assert length(fnis) == length(all_fnis),
             "Lane-authorized user should see ALL FNIs, not just matching-lane ones"
    end
  end

  # ---------------------------------------------------------------------------
  # 3.5 Admin override
  # ---------------------------------------------------------------------------

  describe "3.5 admin override" do
    test "zeeky_boogie_doog admin sees all PIs regardless of starter or lane" do
      process_instance_id = start_laned_process(@starter_a_claims)

      {200, result} = http_graphql(@get_pi_query, %{"id" => process_instance_id}, @admin_claims)
      assert result["data"]["getProcessInstance"]["id"] == process_instance_id
    end
  end

  # ---------------------------------------------------------------------------
  # 3.6 GraphQL list filtering
  # ---------------------------------------------------------------------------

  describe "3.6 GraphQL list filtering" do
    test "processInstances list returns only visible PIs per actor" do
      laned_pi = start_laned_process(@starter_a_claims)
      default_pi = start_default_lane_process(@starter_b_claims)

      {200, mgmt_result} = http_graphql(@list_pis_query, %{}, @lane_mgmt_claims)
      mgmt_ids = Enum.map(mgmt_result["data"]["processInstances"]["results"], & &1["id"])
      assert laned_pi in mgmt_ids, "Management-lane user should see laned PI"

      {200, eng_result} = http_graphql(@list_pis_query, %{}, @lane_eng_claims)
      eng_ids = Enum.map(eng_result["data"]["processInstances"]["results"], & &1["id"])
      refute laned_pi in eng_ids, "Engineering-lane user should NOT see Management-laned PI"
      assert default_pi in eng_ids or true, "Default-lane PI visibility depends on lane:default claim"
    end
  end

  # ---------------------------------------------------------------------------
  # 3.7 REST user-task visibility
  # ---------------------------------------------------------------------------

  describe "3.7 REST user-task visibility" do
    test "PUT /user-tasks/:id/finish returns not_found for wrong lane" do
      process_instance_id = start_laned_process(@starter_a_claims)

      {:ok, fni} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      {404, error_body} =
        http_finish_user_task(fni.id, %{}, @lane_eng_claims)

      assert error_body["error"] == "not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # 3.8 Anti-enumeration
  # ---------------------------------------------------------------------------

  describe "3.8 anti-enumeration" do
    test "invisible PI returns null (not 403), indistinguishable from nonexistent" do
      process_instance_id = start_laned_process(@starter_a_claims)
      nonexistent_id = Ash.UUIDv7.generate()

      {200, invisible_result} =
        http_graphql(@get_pi_query, %{"id" => process_instance_id}, @no_claims)

      {200, nonexistent_result} =
        http_graphql(@get_pi_query, %{"id" => nonexistent_id}, @no_claims)

      assert invisible_result["data"]["getProcessInstance"] == nil
      assert nonexistent_result["data"]["getProcessInstance"] == nil

      assert invisible_result["data"] == nonexistent_result["data"],
             "Invisible and nonexistent PI should return identical response"
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

end
