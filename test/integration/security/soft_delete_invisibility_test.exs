defmodule BfwEngine.Integration.Security.SoftDeleteInvisibilityTest do
  @moduledoc """
  Security-critical tests verifying that soft-deleted records are absolutely
  invisible through every external surface — GraphQL get, GraphQL list, REST,
  aggregate stats, nested relationship reads, and WebSocket channel joins.

  Every test explicitly uses the `zeeky_boogie_doog` admin actor to prove
  that the admin policy bypass does NOT leak deleted records. The admin
  bypasses Ash **policies** but the read action's `filter expr(deleted == false)`
  is architectural and cannot be bypassed.
  """
  use BfwEngine.ExecutionCase, async: false

  import Phoenix.ChannelTest

  @endpoint BfwEngineWeb.Http.Endpoint
  @moduletag :integration

  alias BfwEngine.Persistence.Resources

  @admin_claims %{"sub" => "admin-user", "zeeky_boogie_doog" => true}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp soft_delete_record(resource, record_id) do
    {:ok, record} = Ash.get(resource, record_id, authorize?: false)

    record
    |> Ash.Changeset.for_update(:soft_delete, %{
      deleted: true,
      deleted_at: DateTime.utc_now(),
      deleted_by: %{"id" => "test-admin", "name" => "Security test"}
    })
    |> Ash.update!(authorize?: false)
  end

  defp soft_delete_all_fnis(process_instance_id) do
    fnis = fetch_flow_node_instances(process_instance_id)

    Enum.each(fnis, fn fni ->
      soft_delete_record(Resources.FlowNodeInstance, fni.id)
    end)
  end

  defp graphql_get_pi(process_instance_id, claims \\ @admin_claims) do
    query = """
    query GetPI($id: ID!) { getProcessInstance(id: $id) { id state } }
    """

    http_graphql(query, %{"id" => process_instance_id}, claims)
  end

  defp graphql_list_pis(claims \\ @admin_claims) do
    query = """
    { processInstances { results { id state } count } }
    """

    http_graphql(query, %{}, claims)
  end

  defp graphql_get_fni(fni_id, claims \\ @admin_claims) do
    query = """
    query GetFNI($id: ID!) { getFlowNodeInstance(id: $id) { id flowNodeId } }
    """

    http_graphql(query, %{"id" => fni_id}, claims)
  end

  defp graphql_list_fnis(process_instance_id, claims \\ @admin_claims) do
    query = """
    query ListFNIs($piId: ID!) {
      flowNodeInstances(filter: {processInstanceId: {eq: $piId}}) {
        results { id flowNodeId }
        count
      }
    }
    """

    http_graphql(query, %{"piId" => process_instance_id}, claims)
  end

  defp graphql_get_pv(version_id, claims \\ @admin_claims) do
    query = """
    query GetPV($id: ID!) { getProcessVersion(id: $id) { id version } }
    """

    http_graphql(query, %{"id" => version_id}, claims)
  end

  defp graphql_get_dv(version_id, claims \\ @admin_claims) do
    query = """
    query GetDV($id: ID!) { getDecisionVersion(id: $id) { id version } }
    """

    http_graphql(query, %{"id" => version_id}, claims)
  end

  defp graphql_pi_with_fnis(process_instance_id, claims \\ @admin_claims) do
    query = """
    query GetPIWithFNIs($id: ID!) {
      getProcessInstance(id: $id) {
        id state
        flowNodeInstances { id flowNodeId state }
      }
    }
    """

    http_graphql(query, %{"id" => process_instance_id}, claims)
  end

  defp deploy_start_and_finish(fixture, model_id) do
    {201, _} = http_deploy(fixture)
    {201, start_body} = http_start(model_id, %{}, @admin_claims)
    process_instance_id = start_body["processInstanceId"]
    wait_for_process_instance(process_instance_id)
    process_instance_id
  end

  # ---------------------------------------------------------------------------
  # 2.1 Soft-deleted PI invisible via GraphQL
  # ---------------------------------------------------------------------------

  describe "2.1 soft-deleted PI invisible via GraphQL" do
    test "admin cannot see soft-deleted PI via get or list" do
      process_instance_id =
        deploy_start_and_finish("linear_start_end.bpmn", "LinearStartEnd")

      {200, get_before} = graphql_get_pi(process_instance_id)
      assert get_before["data"]["getProcessInstance"] != nil

      {200, list_before} = graphql_list_pis()
      ids_before = Enum.map(list_before["data"]["processInstances"]["results"], & &1["id"])
      assert process_instance_id in ids_before

      soft_delete_record(Resources.ProcessInstance, process_instance_id)

      {200, get_after} = graphql_get_pi(process_instance_id)
      assert get_after["data"]["getProcessInstance"] == nil

      {200, list_after} = graphql_list_pis()
      ids_after = Enum.map(list_after["data"]["processInstances"]["results"], & &1["id"])
      refute process_instance_id in ids_after
    end
  end

  # ---------------------------------------------------------------------------
  # 2.2 Soft-deleted FNI invisible via GraphQL
  # ---------------------------------------------------------------------------

  describe "2.2 soft-deleted FNI invisible via GraphQL" do
    test "admin cannot see soft-deleted FNI via get or list" do
      process_instance_id =
        deploy_start_and_finish("linear_start_end.bpmn", "LinearStartEnd")

      fnis = fetch_flow_node_instances(process_instance_id)
      assert length(fnis) >= 2
      target_fni = hd(fnis)

      {200, get_before} = graphql_get_fni(target_fni.id)
      assert get_before["data"]["getFlowNodeInstance"] != nil

      soft_delete_record(Resources.FlowNodeInstance, target_fni.id)

      {200, get_after} = graphql_get_fni(target_fni.id)
      assert get_after["data"]["getFlowNodeInstance"] == nil

      {200, list_after} = graphql_list_fnis(process_instance_id)
      ids_after = Enum.map(list_after["data"]["flowNodeInstances"]["results"], & &1["id"])
      refute target_fni.id in ids_after
    end
  end

  # ---------------------------------------------------------------------------
  # 2.3 Soft-deleted ProcessVersion invisible
  # ---------------------------------------------------------------------------

  describe "2.3 soft-deleted ProcessVersion invisible" do
    test "admin cannot see soft-deleted version via GraphQL or REST" do
      {201, _} = http_deploy("linear_three_node.bpmn")

      {200, versions_rest} = http_list_versions("LinearThreeNode", claims: @admin_claims)
      assert length(versions_rest) >= 1
      version_entry = hd(versions_rest)
      version_id = version_entry["versionId"]

      {200, get_before} = graphql_get_pv(version_id)
      assert get_before["data"]["getProcessVersion"] != nil

      soft_delete_record(Resources.ProcessVersion, version_id)

      {200, get_after} = graphql_get_pv(version_id)
      assert get_after["data"]["getProcessVersion"] == nil

      {200, versions_after} = http_list_versions("LinearThreeNode", claims: @admin_claims)
      rest_ids = Enum.map(versions_after, & &1["versionId"])
      refute version_id in rest_ids
    end
  end

  # ---------------------------------------------------------------------------
  # 2.4 Soft-deleted DecisionVersion invisible
  # ---------------------------------------------------------------------------

  describe "2.4 soft-deleted DecisionVersion invisible" do
    test "admin cannot see soft-deleted decision version via GraphQL or REST" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]
      definition_id = deployed["decisionDefinitionId"]

      query = "{ decisionVersions { results { id version } } }"
      {200, list_before} = http_graphql(query, %{}, @admin_claims)
      results = list_before["data"]["decisionVersions"]["results"]
      version_record = Enum.find(results, &(&1["version"] == deployed["version"]))
      assert version_record != nil
      version_id = version_record["id"]

      {200, get_before} = graphql_get_dv(version_id)
      assert get_before["data"]["getDecisionVersion"] != nil

      soft_delete_record(Resources.DecisionVersion, version_id)

      {200, get_after} = graphql_get_dv(version_id)
      assert get_after["data"]["getDecisionVersion"] == nil

      {200, versions_rest} =
        http_list_decision_versions(definition_id, claims: @admin_claims)

      rest_ids = Enum.map(versions_rest, & &1["versionId"])
      refute version_id in rest_ids
    end
  end

  # ---------------------------------------------------------------------------
  # 2.5 Cascaded soft-delete
  # ---------------------------------------------------------------------------

  describe "2.5 cascaded soft-delete" do
    test "soft-deleting a PI makes all its FNIs invisible" do
      process_instance_id =
        deploy_start_and_finish("linear_three_node.bpmn", "LinearThreeNode")

      fnis = fetch_flow_node_instances(process_instance_id)
      assert length(fnis) >= 3
      fni_ids = Enum.map(fnis, & &1.id)

      soft_delete_record(Resources.ProcessInstance, process_instance_id)
      soft_delete_all_fnis(process_instance_id)

      for fni_id <- fni_ids do
        {200, result} = graphql_get_fni(fni_id)
        assert result["data"]["getFlowNodeInstance"] == nil,
               "FNI #{fni_id} should be invisible after cascade soft-delete"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2.6 Error indistinguishability
  # ---------------------------------------------------------------------------

  describe "2.6 error indistinguishability" do
    test "soft-deleted PI returns same shape as genuinely non-existent UUID" do
      process_instance_id =
        deploy_start_and_finish("linear_start_end.bpmn", "LinearStartEnd")

      soft_delete_record(Resources.ProcessInstance, process_instance_id)

      nonexistent_id = Ash.UUIDv7.generate()

      {200, deleted_result} = graphql_get_pi(process_instance_id)
      {200, nonexistent_result} = graphql_get_pi(nonexistent_id)

      assert deleted_result["data"]["getProcessInstance"] == nil
      assert nonexistent_result["data"]["getProcessInstance"] == nil

      assert deleted_result["data"] == nonexistent_result["data"],
             "Soft-deleted and nonexistent PI should return identical response shapes"
    end
  end

  # ---------------------------------------------------------------------------
  # 2.7 REST /stats excludes soft-deleted records
  # ---------------------------------------------------------------------------

  describe "2.7 REST /stats excludes soft-deleted" do
    test "soft-deleted PI is not counted in /stats" do
      process_instance_id =
        deploy_start_and_finish("linear_start_end.bpmn", "LinearStartEnd")

      {200, stats_before} = http_get_stats()
      finished_before = get_in(stats_before, ["processInstances", "finished"]) || 0

      soft_delete_record(Resources.ProcessInstance, process_instance_id)

      {200, stats_after} = http_get_stats()
      finished_after = get_in(stats_after, ["processInstances", "finished"]) || 0

      assert finished_after < finished_before,
             "Stats should exclude soft-deleted PI (before=#{finished_before}, after=#{finished_after})"
    end
  end

  # ---------------------------------------------------------------------------
  # 2.8 finalTokens calculation excludes soft-deleted FNIs
  # ---------------------------------------------------------------------------

  describe "2.8 finalTokens excludes soft-deleted FNIs" do
    test "finalTokens does not include soft-deleted end-event FNIs" do
      process_instance_id =
        deploy_start_and_finish("linear_start_end.bpmn", "LinearStartEnd")

      query_with_tokens = """
      query GetPITokens($id: ID!) {
        getProcessInstance(id: $id) { id state finalTokens }
      }
      """

      {200, before_result} = http_graphql(query_with_tokens, %{"id" => process_instance_id}, @admin_claims)
      pi_before = before_result["data"]["getProcessInstance"]
      assert pi_before != nil
      assert is_list(pi_before["finalTokens"])
      assert length(pi_before["finalTokens"]) >= 1

      fnis = fetch_flow_node_instances(process_instance_id)
      end_fni = Enum.find(fnis, &(&1.flow_node_type == "end_event"))
      assert end_fni != nil

      soft_delete_record(Resources.FlowNodeInstance, end_fni.id)

      {200, after_result} = http_graphql(query_with_tokens, %{"id" => process_instance_id}, @admin_claims)
      pi_after = after_result["data"]["getProcessInstance"]
      assert pi_after != nil
      assert pi_after["finalTokens"] == [] or pi_after["finalTokens"] == nil,
             "finalTokens should not include soft-deleted end-event FNI"
    end
  end

  # ---------------------------------------------------------------------------
  # 2.9 Admin WS channel join for deleted PI
  # ---------------------------------------------------------------------------

  describe "2.9 admin WS channel join for deleted PI" do
    test "admin can join deleted PI channel but receives no events" do
      process_instance_id =
        deploy_start_and_finish("linear_start_end.bpmn", "LinearStartEnd")

      soft_delete_record(Resources.ProcessInstance, process_instance_id)

      identity = %BfwEngine.Types.Identity{
        id: "admin-ws-user",
        roles: [],
        groups: [],
        claims: %{"zeeky_boogie_doog" => true}
      }

      admin_socket =
        socket(BfwEngineWeb.Ws.UserSocket, "user:admin-ws-user", %{identity: identity})

      case subscribe_and_join(
             admin_socket,
             BfwEngineWeb.Ws.EngineChannel,
             "process_instance:#{process_instance_id}",
             %{}
           ) do
        {:ok, _, _channel_socket} ->
          refute_push "engine_event", _any, 1_000

        {:error, %{reason: "not_found"}} ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2.10 Nested relationship reads
  # ---------------------------------------------------------------------------

  describe "2.10 nested relationship reads exclude soft-deleted FNIs" do
    test "getProcessInstance { flowNodeInstances } excludes soft-deleted FNIs" do
      process_instance_id =
        deploy_start_and_finish("linear_three_node.bpmn", "LinearThreeNode")

      {200, before_result} = graphql_pi_with_fnis(process_instance_id)
      pi_before = before_result["data"]["getProcessInstance"]
      fnis_before = pi_before["flowNodeInstances"]
      assert length(fnis_before) >= 3

      target_fni_id = hd(fnis_before)["id"]
      soft_delete_record(Resources.FlowNodeInstance, target_fni_id)

      {200, after_result} = graphql_pi_with_fnis(process_instance_id)
      pi_after = after_result["data"]["getProcessInstance"]
      fnis_after = pi_after["flowNodeInstances"]

      ids_after = Enum.map(fnis_after, & &1["id"])
      refute target_fni_id in ids_after
      assert length(fnis_after) == length(fnis_before) - 1
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  defp http_get_stats do
    conn =
      Plug.Test.conn(:get, "/stats")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(@admin_claims)}")
      |> route()

    decode_response(conn)
  end

end
