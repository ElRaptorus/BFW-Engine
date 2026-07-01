defmodule EvilEngine.Integration.Graphql.GraphqlGetQueriesTest do
  @moduledoc """
  GraphQL integration tests for single-record get queries.

  Exercises all seven AshGraphql `get_*` queries through the full
  HTTP/GraphQL pipeline: `getProcess`, `getProcessVersion`,
  `getProcessInstance`, `getFlowNodeInstance`, `getDecisionDefinition`,
  `getDecisionVersion`, and `getDataObjectValue`.
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @process_model_id "LinearStartEnd"
  @process_name "Linear Start End"
  @process_version_string "1.0.0"
  @decision_definition_id "definitions_discount"

  @list_processes_query """
  query ListProcesses {
    processes(filter: {processModelId: {eq: "#{@process_model_id}"}}) {
      results {
        id
        processModelId
        name
        enabled
        createdAt
      }
    }
  }
  """

  @get_process_query """
  query GetProcess($id: ID!) {
    getProcess(id: $id) {
      id
      processModelId
      name
      enabled
      createdAt
    }
  }
  """

  @list_process_versions_query """
  query ListProcessVersions {
    processVersions {
      results {
        id
        version
        processId
        bpmnXml
        deployedAt
        deployer
      }
    }
  }
  """

  @get_process_version_query """
  query GetProcessVersion($id: ID!) {
    getProcessVersion(id: $id) {
      id
      version
      processId
      bpmnXml
      deployedAt
      deployer
    }
  }
  """

  @get_process_instance_query """
  query GetProcessInstance($id: ID!) {
    getProcessInstance(id: $id) {
      id
      state
      startedAt
      startedBy
      processVersionId
    }
  }
  """

  @list_flow_node_instances_query """
  query ListFlowNodeInstances($processInstanceId: ID!) {
    flowNodeInstances(filter: {processInstanceId: {eq: $processInstanceId}}) {
      results {
        id
        flowNodeId
        flowNodeType
        state
        processInstanceId
      }
    }
  }
  """

  @get_flow_node_instance_query """
  query GetFlowNodeInstance($id: ID!) {
    getFlowNodeInstance(id: $id) {
      id
      flowNodeId
      flowNodeType
      state
      processInstanceId
    }
  }
  """

  @list_decision_definitions_query """
  query ListDecisionDefinitions {
    decisionDefinitions {
      results {
        id
        decisionDefinitionId
        name
        enabled
        createdAt
      }
    }
  }
  """

  @get_decision_definition_query """
  query GetDecisionDefinition($id: ID!) {
    getDecisionDefinition(id: $id) {
      id
      decisionDefinitionId
      name
      enabled
      createdAt
    }
  }
  """

  @list_decision_versions_query """
  query ListDecisionVersions {
    decisionVersions {
      results {
        id
        version
        decisionDefinitionId
        dmnXml
        deployedAt
      }
    }
  }
  """

  @get_decision_version_query """
  query GetDecisionVersion($id: ID!) {
    getDecisionVersion(id: $id) {
      id
      version
      decisionDefinitionId
      dmnXml
      deployedAt
    }
  }
  """

  @list_data_object_values_query """
  query ListDataObjectValues($processInstanceId: ID!) {
    dataObjectValues(filter: {processInstanceId: {eq: $processInstanceId}}) {
      results {
        id
        dataObjectId
        processInstanceId
        value
        createdAt
      }
    }
  }
  """

  @get_data_object_value_query """
  query GetDataObjectValue($id: ID!) {
    getDataObjectValue(id: $id) {
      id
      dataObjectId
      processInstanceId
      value
      createdAt
    }
  }
  """

  describe "getProcess" do
    test "returns a deployed process by UUID" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {200, list_body} = http_graphql(@list_processes_query, %{}, @admin_claims)
      results = list_body["data"]["processes"]["results"]
      assert length(results) >= 1

      found = Enum.find(results, &(&1["processModelId"] == @process_model_id))
      assert found != nil

      {200, get_body} =
        http_graphql(@get_process_query, %{"id" => found["id"]}, @admin_claims)

      process = get_body["data"]["getProcess"]
      assert process["id"] == found["id"]
      assert process["processModelId"] == @process_model_id
      assert process["name"] == @process_name
      assert process["enabled"] == true
      assert process["createdAt"] != nil
    end

    test "returns null for non-existent UUID" do
      fake_id = Ash.UUIDv7.generate()

      {200, body} = http_graphql(@get_process_query, %{"id" => fake_id}, @admin_claims)

      assert body["data"]["getProcess"] == nil
      refute Map.has_key?(body, "errors")
    end
  end

  describe "getProcessVersion" do
    test "returns a deployed process version by UUID" do
      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} = http_graphql(@list_process_versions_query, %{}, @admin_claims)
      results = list_body["data"]["processVersions"]["results"]
      assert length(results) >= 1

      found =
        Enum.find(results, fn version ->
          version["version"] == deployed["version"]
        end)

      assert found != nil

      {200, get_body} =
        http_graphql(@get_process_version_query, %{"id" => found["id"]}, @admin_claims)

      process_version = get_body["data"]["getProcessVersion"]
      assert process_version["id"] == found["id"]
      assert process_version["version"] == @process_version_string
      assert is_binary(process_version["processId"])
      assert is_binary(process_version["bpmnXml"])
      assert String.contains?(process_version["bpmnXml"], @process_model_id)
      assert process_version["deployedAt"] != nil
      deployer = Jason.decode!(process_version["deployer"])
      assert is_map(deployer)
      assert deployer["id"] == "test-user"
    end

    test "returns null for non-existent UUID" do
      fake_id = Ash.UUIDv7.generate()

      {200, body} =
        http_graphql(@get_process_version_query, %{"id" => fake_id}, @admin_claims)

      assert body["data"]["getProcessVersion"] == nil
      refute Map.has_key?(body, "errors")
    end
  end

  describe "getProcessInstance" do
    test "returns a started process instance by UUID" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      {200, get_body} =
        http_graphql(
          @get_process_instance_query,
          %{"id" => process_instance_id},
          @admin_claims
        )

      process_instance = get_body["data"]["getProcessInstance"]
      assert process_instance["id"] == process_instance_id
      assert process_instance["state"] == "finished"
      assert process_instance["startedAt"] != nil
      started_by = Jason.decode!(process_instance["startedBy"])
      assert is_map(started_by)
      assert started_by["id"] == "test-user"
      assert is_binary(process_instance["processVersionId"])
    end

    test "returns null for non-existent UUID" do
      fake_id = Ash.UUIDv7.generate()

      {200, body} =
        http_graphql(@get_process_instance_query, %{"id" => fake_id}, @admin_claims)

      assert body["data"]["getProcessInstance"] == nil
      refute Map.has_key?(body, "errors")
    end
  end

  describe "getFlowNodeInstance" do
    test "returns a flow node instance by UUID" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      {200, list_body} =
        http_graphql(
          @list_flow_node_instances_query,
          %{"processInstanceId" => process_instance_id},
          @admin_claims
        )

      results = list_body["data"]["flowNodeInstances"]["results"]
      assert length(results) >= 1

      [listed_flow_node_instance | _] = results

      {200, get_body} =
        http_graphql(
          @get_flow_node_instance_query,
          %{"id" => listed_flow_node_instance["id"]},
          @admin_claims
        )

      flow_node_instance = get_body["data"]["getFlowNodeInstance"]
      assert flow_node_instance["id"] == listed_flow_node_instance["id"]
      assert is_binary(flow_node_instance["flowNodeId"])
      assert is_binary(flow_node_instance["flowNodeType"])
      assert is_binary(flow_node_instance["state"])
      assert flow_node_instance["processInstanceId"] == process_instance_id
    end

    test "returns null for non-existent UUID" do
      fake_id = Ash.UUIDv7.generate()

      {200, body} =
        http_graphql(@get_flow_node_instance_query, %{"id" => fake_id}, @admin_claims)

      assert body["data"]["getFlowNodeInstance"] == nil
      refute Map.has_key?(body, "errors")
    end
  end

  describe "getDecisionDefinition" do
    test "returns a deployed decision definition by UUID" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} = http_graphql(@list_decision_definitions_query, %{}, @admin_claims)
      results = list_body["data"]["decisionDefinitions"]["results"]
      assert length(results) >= 1

      found =
        Enum.find(results, &(&1["decisionDefinitionId"] == deployed["decisionDefinitionId"]))

      assert found != nil

      {200, get_body} =
        http_graphql(@get_decision_definition_query, %{"id" => found["id"]}, @admin_claims)

      decision_definition = get_body["data"]["getDecisionDefinition"]
      assert decision_definition["id"] == found["id"]
      assert decision_definition["decisionDefinitionId"] == @decision_definition_id
      assert is_binary(decision_definition["name"])
      assert decision_definition["enabled"] == true
      assert decision_definition["createdAt"] != nil
    end

    test "returns null for non-existent UUID" do
      fake_id = Ash.UUIDv7.generate()

      {200, body} =
        http_graphql(@get_decision_definition_query, %{"id" => fake_id}, @admin_claims)

      assert body["data"]["getDecisionDefinition"] == nil
      refute Map.has_key?(body, "errors")
    end
  end

  describe "getDecisionVersion" do
    test "returns a deployed decision version by UUID" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} = http_graphql(@list_decision_versions_query, %{}, @admin_claims)
      results = list_body["data"]["decisionVersions"]["results"]
      assert length(results) >= 1

      found =
        Enum.find(results, fn version ->
          version["version"] == deployed["version"]
        end)

      assert found != nil

      {200, get_body} =
        http_graphql(@get_decision_version_query, %{"id" => found["id"]}, @admin_claims)

      decision_version = get_body["data"]["getDecisionVersion"]
      assert decision_version["id"] == found["id"]
      assert is_binary(decision_version["version"])
      assert is_binary(decision_version["decisionDefinitionId"])
      assert is_binary(decision_version["dmnXml"])
      assert String.contains?(decision_version["dmnXml"], @decision_definition_id)
      assert decision_version["deployedAt"] != nil
    end

    test "returns null for non-existent UUID" do
      fake_id = Ash.UUIDv7.generate()

      {200, body} =
        http_graphql(@get_decision_version_query, %{"id" => fake_id}, @admin_claims)

      assert body["data"]["getDecisionVersion"] == nil
      refute Map.has_key?(body, "errors")
    end
  end

  describe "getDataObjectValue" do
    test "returns a data object value by UUID" do
      process_instance_id =
        http_deploy_and_start("data_object_simple_write.bpmn", "DataObjectSimpleWrite", %{
          "payload" => %{"amount" => 42}
        })

      wait_for_process_instance(process_instance_id)

      {200, list_body} =
        http_graphql(
          @list_data_object_values_query,
          %{"processInstanceId" => process_instance_id},
          @admin_claims
        )

      results = list_body["data"]["dataObjectValues"]["results"]
      assert length(results) == 1

      [listed_data_object_value] = results

      {200, get_body} =
        http_graphql(
          @get_data_object_value_query,
          %{"id" => listed_data_object_value["id"]},
          @admin_claims
        )

      data_object_value = get_body["data"]["getDataObjectValue"]
      assert data_object_value["id"] == listed_data_object_value["id"]
      assert data_object_value["dataObjectId"] == "DO_1"
      assert data_object_value["processInstanceId"] == process_instance_id
      assert data_object_value["value"]["order_id"] == "ABC-123"
      assert data_object_value["value"]["total"] == 42
      assert data_object_value["createdAt"] != nil
    end

    test "returns null for non-existent UUID" do
      fake_id = Ash.UUIDv7.generate()

      {200, body} =
        http_graphql(@get_data_object_value_query, %{"id" => fake_id}, @admin_claims)

      assert body["data"]["getDataObjectValue"] == nil
      refute Map.has_key?(body, "errors")
    end
  end
end
