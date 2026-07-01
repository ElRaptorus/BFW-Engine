defmodule EvilEngine.Integration.Graphql.GraphqlSoftDeleteTest do
  @moduledoc """
  GraphQL integration tests for soft-delete invisibility.

  Verifies that soft-deleted ProcessVersion, FlowNodeInstance, and
  DecisionVersion records are invisible through both list and get queries.
  (ProcessInstance soft-delete is already tested in `soft_delete_security_test.exs`.)
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  alias EvilEngine.Persistence.Resources

  defp soft_delete_record(resource, record_id) do
    {:ok, record} = Ash.get(resource, record_id, authorize?: false)

    record
    |> Ash.Changeset.for_update(:soft_delete, %{
      deleted: true,
      deleted_at: DateTime.utc_now(),
      deleted_by: %{"id" => "test-admin", "name" => "Soft-delete test"}
    })
    |> Ash.update!(authorize?: false)
  end

  describe "soft-deleted ProcessVersion" do
    test "invisible in processVersions list and getProcessVersion" do
      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      list_query = """
      { processVersions { results { id version } } }
      """

      {200, list_before} = http_graphql(list_query, %{}, @admin_claims)
      results_before = list_before["data"]["processVersions"]["results"]

      version_record =
        Enum.find(results_before, &(&1["version"] == deployed["version"]))

      assert version_record != nil
      version_id = version_record["id"]

      get_query = """
      query GetPV($id: ID!) { getProcessVersion(id: $id) { id version } }
      """

      {200, get_before} = http_graphql(get_query, %{"id" => version_id}, @admin_claims)
      assert get_before["data"]["getProcessVersion"] != nil

      soft_delete_record(Resources.ProcessVersion, version_id)

      {200, list_after} = http_graphql(list_query, %{}, @admin_claims)
      results_after = list_after["data"]["processVersions"]["results"]
      ids_after = Enum.map(results_after, & &1["id"])
      refute version_id in ids_after

      {200, get_after} = http_graphql(get_query, %{"id" => version_id}, @admin_claims)
      assert get_after["data"]["getProcessVersion"] == nil
    end
  end

  describe "soft-deleted FlowNodeInstance" do
    test "invisible in flowNodeInstances list and getFlowNodeInstance" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")

      wait_for_process_instance(process_instance_id)

      list_query = """
      {
        flowNodeInstances(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results { id flowNodeId }
        }
      }
      """

      {200, list_before} = http_graphql(list_query, %{}, @admin_claims)
      results_before = list_before["data"]["flowNodeInstances"]["results"]
      assert length(results_before) == 2

      fni_to_delete = hd(results_before)
      fni_id = fni_to_delete["id"]

      get_query = """
      query GetFNI($id: ID!) { getFlowNodeInstance(id: $id) { id flowNodeId } }
      """

      {200, get_before} = http_graphql(get_query, %{"id" => fni_id}, @admin_claims)
      assert get_before["data"]["getFlowNodeInstance"] != nil

      soft_delete_record(Resources.FlowNodeInstance, fni_id)

      {200, list_after} = http_graphql(list_query, %{}, @admin_claims)
      results_after = list_after["data"]["flowNodeInstances"]["results"]
      ids_after = Enum.map(results_after, & &1["id"])
      refute fni_id in ids_after
      assert length(results_after) == 1

      {200, get_after} = http_graphql(get_query, %{"id" => fni_id}, @admin_claims)
      assert get_after["data"]["getFlowNodeInstance"] == nil
    end
  end

  describe "soft-deleted DecisionVersion" do
    test "invisible in decisionVersions list and getDecisionVersion" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]

      list_query = """
      { decisionVersions { results { id version } } }
      """

      {200, list_before} = http_graphql(list_query, %{}, @admin_claims)
      results_before = list_before["data"]["decisionVersions"]["results"]

      version_record =
        Enum.find(results_before, &(&1["version"] == deployed["version"]))

      assert version_record != nil
      version_id = version_record["id"]

      get_query = """
      query GetDV($id: ID!) { getDecisionVersion(id: $id) { id version } }
      """

      {200, get_before} = http_graphql(get_query, %{"id" => version_id}, @admin_claims)
      assert get_before["data"]["getDecisionVersion"] != nil

      soft_delete_record(Resources.DecisionVersion, version_id)

      {200, list_after} = http_graphql(list_query, %{}, @admin_claims)
      results_after = list_after["data"]["decisionVersions"]["results"]
      ids_after = Enum.map(results_after, & &1["id"])
      refute version_id in ids_after

      {200, get_after} = http_graphql(get_query, %{"id" => version_id}, @admin_claims)
      assert get_after["data"]["getDecisionVersion"] == nil
    end
  end
end
