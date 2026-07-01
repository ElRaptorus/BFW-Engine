defmodule EvilEngine.Integration.Graphql.GraphqlAuthMatrixTest do
  @moduledoc """
  GraphQL authorization matrix integration tests.

  Verifies the full authorization model across all GraphQL list query families:

  - **Catalog resources** (`Process`, `ProcessVersion`, `DecisionDefinition`,
    `DecisionVersion`): readable by any authenticated actor
  - **PI-scoped resources** (`ProcessInstance`, `FlowNodeInstance`,
    `DataObjectValue`, `DataObjectHistoryEntry`): visible only to the PI starter,
    lane-accessible users, or `zeeky_boogie_doog` admin bypass
  - **No JWT**: HTTP 401 for all queries
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @minimal_claims %{"sub" => "minimal-user"}

  @process_model_id "LinearStartEnd"

  @unauthenticated_query_families [
    {"processes", "{ processes { results { id } } }"},
    {"processVersions", "{ processVersions { results { id } } }"},
    {"processInstances", "{ processInstances { results { id } } }"},
    {"flowNodeInstances", "{ flowNodeInstances { results { id } } }"},
    {"decisionDefinitions", "{ decisionDefinitions { results { id } } }"},
    {"decisionVersions", "{ decisionVersions { results { id } } }"}
  ]

  defp post_graphql_without_auth(query) do
    json_body = Jason.encode!(%{"query" => query})

    Plug.Test.conn(:post, "/api/v1/graphql", json_body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> route()
  end

  defp start_data_object_process do
    {201, _} = http_deploy("data_object_simple_write.bpmn")

    {201, body} =
      http_start(
        "DataObjectSimpleWrite",
        %{"payload" => %{"amount" => 1}},
        %{"sub" => "do-starter"}
      )

    process_instance_id = body["processInstanceId"]
    wait_for_process_instance(process_instance_id)
    process_instance_id
  end

  defp start_laned_process do
    {201, _} = http_deploy("user_task_with_lane.bpmn")

    {201, body} =
      http_start(
        "LanedUserTask",
        %{},
        %{"sub" => "starter", "lane:Management" => true}
      )

    process_instance_id = body["processInstanceId"]
    Process.sleep(200)
    {process_instance_id, fetch_flow_node_instances(process_instance_id)}
  end

  describe "no JWT → 401 for all query families" do
    test "rejects unauthenticated GraphQL requests" do
      Enum.each(@unauthenticated_query_families, fn {family_name, query} ->
        conn = post_graphql_without_auth(query)
        assert conn.status == 401, "expected 401 for #{family_name} without JWT"
      end)
    end
  end

  describe "catalog resources visible to any authenticated user" do
    setup do
      {201, process_deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed_process] = process_deploy_body["deployed"]

      {201, decision_deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed_decision] = decision_deploy_body["deployed"]

      {:ok,
       deployed_process: deployed_process,
       deployed_decision: deployed_decision}
    end

    test "processes query returns results for minimal JWT", %{deployed_process: deployed_process} do
      query = """
      {
        processes(filter: {processModelId: {eq: "#{@process_model_id}"}}) {
          results {
            id
            processModelId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @minimal_claims)
      results = get_in(body, ["data", "processes", "results"])
      refute results == []

      found = Enum.find(results, &(&1["processModelId"] == deployed_process["processModelId"]))
      assert found != nil
    end

    test "processVersions query returns results for minimal JWT", %{deployed_process: deployed_process} do
      query = """
      {
        processVersions {
          results {
            id
            version
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @minimal_claims)
      results = get_in(body, ["data", "processVersions", "results"])
      refute results == []

      found = Enum.find(results, &(&1["version"] == deployed_process["version"]))
      assert found != nil
    end

    test "decisionDefinitions query returns results for minimal JWT", %{
      deployed_decision: deployed_decision
    } do
      query = """
      {
        decisionDefinitions {
          results {
            id
            decisionDefinitionId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @minimal_claims)
      results = get_in(body, ["data", "decisionDefinitions", "results"])
      refute results == []

      found =
        Enum.find(results, &(&1["decisionDefinitionId"] == deployed_decision["decisionDefinitionId"]))

      assert found != nil
    end

    test "decisionVersions query returns results for minimal JWT", %{
      deployed_decision: deployed_decision
    } do
      query = """
      {
        decisionVersions {
          results {
            id
            version
            decisionDefinitionId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @minimal_claims)
      results = get_in(body, ["data", "decisionVersions", "results"])
      refute results == []

      found =
        Enum.find(results, &(&1["version"] == deployed_decision["version"]))

      assert found != nil
      assert is_binary(found["decisionDefinitionId"])
    end
  end

  describe "FNI admin bypass" do
    test "zeeky_boogie_doog user sees FNIs from laned PI" do
      {process_instance_id, _flow_node_instances} = start_laned_process()

      query = """
      {
        flowNodeInstances(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            id
            processInstanceId
            flowNodeId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = get_in(body, ["data", "flowNodeInstances", "results"])
      refute results == []
      assert Enum.all?(results, &(&1["processInstanceId"] == process_instance_id))
    end
  end

  describe "DataObjectValues PI-scoped auth" do
    setup do
      process_instance_id = start_data_object_process()
      {:ok, process_instance_id: process_instance_id}
    end

    test "starter sees data object value records", %{process_instance_id: process_instance_id} do
      query = """
      {
        dataObjectValues(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            id
            dataObjectId
            processInstanceId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, %{"sub" => "do-starter"})
      results = get_in(body, ["data", "dataObjectValues", "results"])
      assert length(results) == 1
      assert hd(results)["dataObjectId"] == "DO_1"
    end

    test "non-starter without lane claim sees empty results", %{
      process_instance_id: process_instance_id
    } do
      query = """
      {
        dataObjectValues(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            id
          }
        }
      }
      """

      {200, body} =
        http_graphql(query, %{}, %{"sub" => "other-user", "lane:default" => nil})

      results = get_in(body, ["data", "dataObjectValues", "results"])
      assert results == []
    end
  end

  describe "DataObjectHistory PI-scoped auth" do
    setup do
      process_instance_id = start_data_object_process()
      {:ok, process_instance_id: process_instance_id}
    end

    test "starter sees data object history records", %{process_instance_id: process_instance_id} do
      query = """
      {
        dataObjectHistory(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            dataObjectId
            processInstanceId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, %{"sub" => "do-starter"})
      results = get_in(body, ["data", "dataObjectHistory", "results"])
      assert length(results) == 1
      assert hd(results)["dataObjectId"] == "DO_1"
    end

    test "non-starter without lane claim sees empty history", %{
      process_instance_id: process_instance_id
    } do
      query = """
      {
        dataObjectHistory(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            dataObjectId
          }
        }
      }
      """

      {200, body} =
        http_graphql(query, %{}, %{"sub" => "other-user", "lane:default" => nil})

      results = get_in(body, ["data", "dataObjectHistory", "results"])
      assert results == []
    end
  end

  describe "DataObjectValues admin bypass" do
    test "zeeky_boogie_doog user sees data object value records" do
      process_instance_id = start_data_object_process()

      query = """
      {
        dataObjectValues(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            id
            dataObjectId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = get_in(body, ["data", "dataObjectValues", "results"])
      assert length(results) == 1
      assert hd(results)["dataObjectId"] == "DO_1"
    end
  end
end
