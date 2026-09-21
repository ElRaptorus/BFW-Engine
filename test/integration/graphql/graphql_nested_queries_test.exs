defmodule BfwEngine.Integration.Graphql.GraphqlNestedQueriesTest do
  @moduledoc """
  GraphQL integration tests for nested relationship includes with filtering
  and sorting on nested associations.

  Covers Process → versions, DecisionDefinition → versions,
  ProcessInstance → flowNodeInstances, dataObjectValues, and
  dataObjectHistory nested queries.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @process_model_id "LinearStartEnd"
  @data_object_multi_write_process_model_id "DataObjectMultiWrite"
  @decision_definition_id "definitions_discount"
  @process_version_string "1.0.0"

  defp parse_started_at_values(results) do
    Enum.map(results, fn result ->
      {:ok, datetime, _offset} = DateTime.from_iso8601(result["startedAt"])
      datetime
    end)
  end

  describe "ProcessInstance → dataObjectHistory nested include" do
    test "returns write history entries with correct fields" do
      process_instance_id =
        http_deploy_and_start(
          "data_object_multi_write.bpmn",
          @data_object_multi_write_process_model_id,
          %{"payload" => %{"amount" => 5}}
        )

      wait_for_process_instance(process_instance_id)

      query = """
      query GetProcessInstanceDataObjectHistory($id: ID!) {
        getProcessInstance(id: $id) {
          id
          dataObjectHistory {
            dataObjectId
            value
            createdAt
          }
        }
      }
      """

      {200, body} =
        http_graphql(query, %{"id" => process_instance_id}, @admin_claims)

      refute Map.has_key?(body, "errors")

      process_instance = body["data"]["getProcessInstance"]
      assert process_instance["id"] == process_instance_id

      history = process_instance["dataObjectHistory"]
      assert length(history) == 2

      assert Enum.all?(history, fn entry ->
               entry["dataObjectId"] == "DO_1" and
                 is_map(entry["value"]) and
                 entry["createdAt"] != nil
             end)

      values = Enum.map(history, & &1["value"])
      assert Enum.any?(values, &(&1["step"] == 1 and &1["value"] == 5))
      assert Enum.any?(values, &(&1["step"] == 2 and &1["value"] == 50))
    end
  end

  describe "DecisionDefinition → versions nested include" do
    test "returns populated versions relationship" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]
      decision_definition_id = deployed["decisionDefinitionId"]

      query = """
      query DecisionDefinitionsWithVersions($decisionDefinitionId: String!) {
        decisionDefinitions(filter: {decisionDefinitionId: {eq: $decisionDefinitionId}}) {
          results {
            id
            decisionDefinitionId
            versions {
              id
              version
              deployedAt
            }
          }
        }
      }
      """

      {200, body} =
        http_graphql(
          query,
          %{"decisionDefinitionId" => decision_definition_id},
          @admin_claims
        )

      refute Map.has_key?(body, "errors")

      results = body["data"]["decisionDefinitions"]["results"]
      refute results == []

      decision_definition = hd(results)
      assert decision_definition["decisionDefinitionId"] == @decision_definition_id
      versions = decision_definition["versions"]
      assert is_list(versions)
      refute versions == []

      version =
        Enum.find(decision_definition["versions"], &(&1["version"] == deployed["version"]))

      assert version != nil
      assert is_binary(version["id"])
      assert version["deployedAt"] != nil
    end
  end

  describe "ProcessInstance → flowNodeInstances with nested filter" do
    test "returns only flow node instances matching the nested filter" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      query = """
      query GetProcessInstanceFilteredFlowNodeInstances($id: ID!) {
        getProcessInstance(id: $id) {
          id
          flowNodeInstances(filter: {flowNodeType: {eq: "end_event"}}) {
            id
            flowNodeId
            flowNodeType
            state
          }
        }
      }
      """

      {200, body} =
        http_graphql(query, %{"id" => process_instance_id}, @admin_claims)

      refute Map.has_key?(body, "errors")

      process_instance = body["data"]["getProcessInstance"]
      assert process_instance["id"] == process_instance_id

      flow_node_instances = process_instance["flowNodeInstances"]
      assert length(flow_node_instances) == 1

      [end_event_flow_node_instance] = flow_node_instances
      assert end_event_flow_node_instance["flowNodeId"] == "End_1"
      assert end_event_flow_node_instance["flowNodeType"] == "end_event"
      assert end_event_flow_node_instance["state"] == "finished"
    end
  end

  describe "ProcessInstance → flowNodeInstances with nested sort" do
    test "returns flow node instances in chronological order" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      query = """
      query GetProcessInstanceSortedFlowNodeInstances($id: ID!) {
        getProcessInstance(id: $id) {
          id
          flowNodeInstances(sort: [{field: STARTED_AT, order: ASC}]) {
            id
            flowNodeId
            flowNodeType
            startedAt
          }
        }
      }
      """

      {200, body} =
        http_graphql(query, %{"id" => process_instance_id}, @admin_claims)

      refute Map.has_key?(body, "errors")

      process_instance = body["data"]["getProcessInstance"]
      flow_node_instances = process_instance["flowNodeInstances"]
      assert length(flow_node_instances) == 2

      parsed_started_at = parse_started_at_values(flow_node_instances)
      assert parsed_started_at == Enum.sort(parsed_started_at, DateTime)

      flow_node_ids = Enum.map(flow_node_instances, & &1["flowNodeId"])
      assert flow_node_ids == ["Start_1", "End_1"]
    end
  end

  describe "Process → versions with nested filter" do
    test "returns only versions matching the nested filter" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      query = """
      query ProcessesWithFilteredVersions {
        processes(filter: {processModelId: {eq: "#{@process_model_id}"}}) {
          results {
            versions(filter: {version: {eq: "#{@process_version_string}"}}) {
              id
              version
            }
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      refute Map.has_key?(body, "errors")

      results = body["data"]["processes"]["results"]
      refute results == []

      process = hd(results)
      versions = process["versions"]
      assert length(versions) == 1

      [version] = versions
      assert version["version"] == @process_version_string
      assert is_binary(version["id"])
    end
  end

  describe "ProcessInstance → flowNodeInstances all fields" do
    test "returns all flow node instance fields with expected nullability" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      query = """
      query GetProcessInstanceAllFlowNodeInstanceFields($id: ID!) {
        getProcessInstance(id: $id) {
          id
          state
          flowNodeInstances {
            id
            flowNodeId
            flowNodeType
            eventType
            laneName
            state
            startedAt
            finishedAt
            inputToken
            outputToken
            typeProperties
            errorInfo
            processInstanceId
          }
        }
      }
      """

      {200, body} =
        http_graphql(query, %{"id" => process_instance_id}, @admin_claims)

      refute Map.has_key?(body, "errors")

      process_instance = body["data"]["getProcessInstance"]
      assert process_instance["id"] == process_instance_id
      assert process_instance["state"] == "finished"

      flow_node_instances = process_instance["flowNodeInstances"]
      assert length(flow_node_instances) == 2

      assert Enum.all?(flow_node_instances, fn flow_node_instance ->
               flow_node_instance["id"] != nil and
                 flow_node_instance["flowNodeId"] in ["Start_1", "End_1"] and
                 flow_node_instance["flowNodeType"] in ["start_event", "end_event"] and
                 flow_node_instance["laneName"] == "default" and
                 flow_node_instance["state"] == "finished" and
                 flow_node_instance["startedAt"] != nil and
                 flow_node_instance["finishedAt"] != nil and
                 flow_node_instance["inputToken"] != nil and
                 flow_node_instance["outputToken"] != nil and
                 flow_node_instance["typeProperties"] != nil and
                 flow_node_instance["errorInfo"] == nil and
                 flow_node_instance["processInstanceId"] == process_instance_id and
                 Map.has_key?(flow_node_instance, "eventType")
             end)

      end_event_flow_node_instance =
        Enum.find(flow_node_instances, &(&1["flowNodeId"] == "End_1"))

      type_properties = Jason.decode!(end_event_flow_node_instance["typeProperties"])
      assert type_properties["end_event_id"] == "End_1"
      assert type_properties["end_event_name"] == "End"
    end
  end
end
