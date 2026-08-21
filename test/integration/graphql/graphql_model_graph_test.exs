defmodule EvilEngine.Integration.Graphql.GraphqlModelGraphTest do
  @moduledoc """
  Integration tests for the BPMN Model graph (Phase 6.1, WP-2/WP-3):
  `ProcessVersion.processModel`, `FlowNodeInstance.flowNode`, and
  `FlowNodeInstance.processVersion`.

  Exercises the full HTTP/GraphQL pipeline against `EvilEngineWeb.Graphql.ModelTypes`
  and `EvilEngineWeb.Graphql.ModelResolvers`, including the polymorphic
  `FlowNode` interface (inline fragments per concrete `*Node` type) and the
  `EventDefinition` union.
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @process_model_id "LinearStartEnd"

  @model_graph_query """
  query GetProcessVersionModel($id: ID!) {
    getProcessVersion(id: $id) {
      id
      version
      processModel {
        id
        name
        version
        isExecutable
        isTransactionScope
        isAdHocScope
        correlationKey
        lanes {
          id
          name
          flowNodeRefs
        }
        sequenceFlows {
          id
          sourceRef
          targetRef
          isDefault
        }
        flowNodes {
          id
          name
          type
          incoming
          outgoing
          ... on StartEventNode {
            isInterrupting
            eventDefinition {
              ... on NoneEventDefinition {
                isNone
              }
            }
          }
          ... on EndEventNode {
            eventDefinition {
              ... on NoneEventDefinition {
                isNone
              }
            }
          }
        }
        allFlowNodes {
          id
          type
          parentSubProcessId
        }
      }
    }
  }
  """

  @flow_node_instance_model_query """
  query GetFlowNodeInstanceModel($id: ID!) {
    getFlowNodeInstance(id: $id) {
      id
      flowNodeId
      flowNodeType
      flowNode {
        id
        type
        ... on StartEventNode {
          isInterrupting
        }
        ... on EndEventNode {
          inMappings {
            source
            target
          }
        }
      }
      processVersion {
        id
        version
      }
    }
  }
  """

  describe "ProcessVersion.processModel" do
    test "resolves the parsed BPMN model with flow nodes, lanes, and sequence flows" do
      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} =
        http_graphql(
          "query { processVersions { results { id version processId bpmnXml } } }",
          %{},
          @admin_claims
        )

      results = list_body["data"]["processVersions"]["results"]

      found =
        Enum.find(results, fn version ->
          version["version"] == deployed["version"] and
            is_binary(version["bpmnXml"]) and
            String.contains?(version["bpmnXml"], @process_model_id)
        end)

      assert found != nil

      {200, body} = http_graphql(@model_graph_query, %{"id" => found["id"]}, @admin_claims)
      refute Map.has_key?(body, "errors")

      process_version = body["data"]["getProcessVersion"]
      assert process_version["id"] == found["id"]

      process_model = process_version["processModel"]
      assert process_model != nil
      assert process_model["name"] == "Linear Start End"
      assert process_model["version"] == "1.0.0"
      assert process_model["isExecutable"] == true
      assert process_model["isTransactionScope"] == false
      assert process_model["isAdHocScope"] == false

      lane_names = Enum.map(process_model["lanes"], & &1["name"])
      assert "default" in lane_names

      assert [%{"sourceRef" => "Start_1", "targetRef" => "End_1"}] =
               process_model["sequenceFlows"]

      flow_node_ids = Enum.map(process_model["flowNodes"], & &1["id"])
      assert "Start_1" in flow_node_ids
      assert "End_1" in flow_node_ids

      start_node = Enum.find(process_model["flowNodes"], &(&1["id"] == "Start_1"))
      assert start_node["type"] == "START_EVENT"
      assert start_node["eventDefinition"]["isNone"] == true

      end_node = Enum.find(process_model["flowNodes"], &(&1["id"] == "End_1"))
      assert end_node["type"] == "END_EVENT"
      assert end_node["eventDefinition"]["isNone"] == true

      # allFlowNodes is the flat, every-scope index — top-level nodes carry no parent.
      all_flow_node_ids = Enum.map(process_model["allFlowNodes"], & &1["id"])
      assert "Start_1" in all_flow_node_ids
      assert "End_1" in all_flow_node_ids

      for node <- process_model["allFlowNodes"] do
        assert node["parentSubProcessId"] == nil
      end
    end

    test "exposes Definitions catalogs and SendTaskNode.outMappings" do
      {201, deploy_body} = http_deploy("send_receive_task.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} =
        http_graphql(
          "query { processVersions { results { id version processId bpmnXml } } }",
          %{},
          @admin_claims
        )

      found =
        Enum.find(list_body["data"]["processVersions"]["results"], fn version ->
          version["version"] == deployed["version"] and
            is_binary(version["bpmnXml"]) and
            String.contains?(version["bpmnXml"], "SendReceiveTask")
        end)

      assert found != nil

      query = """
      query($id: ID!) {
        getProcessVersion(id: $id) {
          id
          processModel {
            id
            definitionsId
            messages { id name }
            signals { id name }
            errors { id name errorCode }
            escalations { id name escalationCode }
            linterScores { rulesetId }
            flowNodes {
              id
              type
              ... on SendTaskNode {
                messageRef
                outMappings { source target }
                inMappings { source target }
              }
              ... on ReceiveTaskNode {
                messageRef
                outMappings { source target }
                inMappings { source target }
              }
            }
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{"id" => found["id"]}, @admin_claims)
      refute Map.has_key?(body, "errors"), inspect(body["errors"])

      process_model = body["data"]["getProcessVersion"]["processModel"]
      assert process_model["definitionsId"] == "Definitions_1"

      message_names = Enum.map(process_model["messages"], & &1["name"])
      assert "service-request" in message_names
      assert "service-response" in message_names
      assert process_model["signals"] == []
      assert process_model["errors"] == []
      assert process_model["escalations"] == []
      assert process_model["linterScores"] == []

      send_task = Enum.find(process_model["flowNodes"], &(&1["id"] == "SendTask_1"))
      assert send_task["type"] == "SEND_TASK"
      assert send_task["messageRef"] == "Msg_request"
      assert send_task["outMappings"] == []
      assert send_task["inMappings"] == []

      receive_task = Enum.find(process_model["flowNodes"], &(&1["id"] == "ReceiveTask_1"))
      assert receive_task["type"] == "RECEIVE_TASK"
      assert receive_task["messageRef"] == "Msg_response"
      assert receive_task["outMappings"] == []
    end

    test "returns null processModel when ModelCache.fetch returns not_found" do
      previous_loader = Application.get_env(:core_bpmn, :model_cache_loader)

      Application.put_env(
        :core_bpmn,
        :model_cache_loader,
        {__MODULE__, :not_found_loader}
      )

      on_exit(fn ->
        if previous_loader do
          Application.put_env(:core_bpmn, :model_cache_loader, previous_loader)
        else
          Application.delete_env(:core_bpmn, :model_cache_loader)
        end
      end)

      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} =
        http_graphql(
          "query { processVersions { results { id version bpmnXml } } }",
          %{},
          @admin_claims
        )

      found =
        Enum.find(list_body["data"]["processVersions"]["results"], fn version ->
          version["version"] == deployed["version"] and
            is_binary(version["bpmnXml"]) and
            String.contains?(version["bpmnXml"], @process_model_id)
        end)

      assert found != nil

      alias EvilEngine.BPMN.ModelCache
      ModelCache.delete(found["id"])

      {200, body} =
        http_graphql(
          "query($id: ID!) { getProcessVersion(id: $id) { id processModel { id } } }",
          %{"id" => found["id"]},
          @admin_claims
        )

      refute Map.has_key?(body, "errors")
      assert body["data"]["getProcessVersion"]["id"] == found["id"]
      assert body["data"]["getProcessVersion"]["processModel"] == nil
    end
  end

  describe "FlowNodeInstance.flowNode and FlowNodeInstance.processVersion" do
    test "resolves the model node and owning process version for a started instance" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      {200, list_body} =
        http_graphql(
          """
          query($processInstanceId: ID!) {
            flowNodeInstances(filter: {processInstanceId: {eq: $processInstanceId}}) {
              results { id flowNodeId flowNodeType }
            }
          }
          """,
          %{"processInstanceId" => process_instance_id},
          @admin_claims
        )

      results = list_body["data"]["flowNodeInstances"]["results"]
      start_fni = Enum.find(results, &(&1["flowNodeId"] == "Start_1"))
      assert start_fni != nil

      {200, body} =
        http_graphql(@flow_node_instance_model_query, %{"id" => start_fni["id"]}, @admin_claims)

      refute Map.has_key?(body, "errors")

      flow_node_instance = body["data"]["getFlowNodeInstance"]
      assert flow_node_instance["flowNodeId"] == "Start_1"

      flow_node = flow_node_instance["flowNode"]
      assert flow_node["id"] == "Start_1"
      assert flow_node["type"] == "START_EVENT"
      assert flow_node["isInterrupting"] == true

      process_version = flow_node_instance["processVersion"]
      assert process_version != nil
      assert is_binary(process_version["id"])
      assert process_version["version"] == "1.0.0"
    end

    test "resolves an EndEventNode with its in-mappings" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      {200, list_body} =
        http_graphql(
          """
          query($processInstanceId: ID!) {
            flowNodeInstances(filter: {processInstanceId: {eq: $processInstanceId}}) {
              results { id flowNodeId }
            }
          }
          """,
          %{"processInstanceId" => process_instance_id},
          @admin_claims
        )

      results = list_body["data"]["flowNodeInstances"]["results"]
      end_fni = Enum.find(results, &(&1["flowNodeId"] == "End_1"))
      assert end_fni != nil

      {200, body} =
        http_graphql(@flow_node_instance_model_query, %{"id" => end_fni["id"]}, @admin_claims)

      refute Map.has_key?(body, "errors")

      flow_node = body["data"]["getFlowNodeInstance"]["flowNode"]
      assert flow_node["id"] == "End_1"
      assert flow_node["inMappings"] == []
    end
  end

  def not_found_loader(_process_version_id), do: {:error, :not_found}
end
