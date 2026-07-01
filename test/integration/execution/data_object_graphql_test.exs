defmodule EvilEngine.Integration.Execution.DataObjectGraphqlTest do
  @moduledoc """
  GraphQL integration tests for Data Object queries.
  Deploys BPMNs with Data Objects, runs PIs, and queries the GraphQL API.
  """
  use EvilEngine.ExecutionCase, async: false

  describe "DO-GQL1: query data_object_values for a PI" do
    test "returns correct snapshots after a DO write" do
      process_instance_id =
        http_deploy_and_start("data_object_simple_write.bpmn", "DataObjectSimpleWrite", %{
          "payload" => %{"amount" => 42}
        })

      wait_for_process_instance(process_instance_id)

      query = """
      {
        dataObjectValues(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            id
            processInstanceId
            dataObjectId
            flowNodeInstanceId
            value
            createdAt
          }
        }
      }
      """

      {200, body} = http_graphql(query)
      results = get_in(body, ["data", "dataObjectValues", "results"])
      assert length(results) == 1
      [do_record] = results
      assert do_record["dataObjectId"] == "DO_1"
      assert do_record["flowNodeInstanceId"] != nil
      assert do_record["createdAt"] != nil
      assert do_record["value"]["order_id"] == "ABC-123"
    end
  end

  describe "DO-GQL2: query data_object_history for a PI" do
    test "returns full write history in order" do
      process_instance_id =
        http_deploy_and_start("data_object_multi_write.bpmn", "DataObjectMultiWrite", %{
          "payload" => %{"amount" => 5}
        })

      wait_for_process_instance(process_instance_id)

      query = """
      {
        dataObjectHistory(filter: {processInstanceId: {eq: "#{process_instance_id}"}}, sort: [{field: CREATED_AT}]) {
          results {
            dataObjectId
            flowNodeInstanceId
            value
            createdAt
          }
        }
      }
      """

      {200, body} = http_graphql(query)
      results = get_in(body, ["data", "dataObjectHistory", "results"])
      assert length(results) == 2
    end
  end

  describe "DO-GQL3: nested processInstance { dataObjectValues } query" do
    test "returns data objects via PI relationship" do
      process_instance_id =
        http_deploy_and_start("data_object_simple_write.bpmn", "DataObjectSimpleWrite", %{
          "payload" => %{"amount" => 7}
        })

      wait_for_process_instance(process_instance_id)

      query = """
      {
        getProcessInstance(id: "#{process_instance_id}") {
          id
          dataObjectValues {
            dataObjectId
            value
          }
        }
      }
      """

      {200, body} = http_graphql(query)
      process_instance = get_in(body, ["data", "getProcessInstance"])
      assert process_instance != nil
      data_objects = process_instance["dataObjectValues"]
      assert length(data_objects) == 1
      assert hd(data_objects)["dataObjectId"] == "DO_1"
    end
  end

  describe "DO-GQL4: query on PI with no DO writes" do
    test "returns empty list" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")

      wait_for_process_instance(process_instance_id)

      query = """
      {
        dataObjectValues(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            id
          }
        }
      }
      """

      {200, body} = http_graphql(query)
      results = get_in(body, ["data", "dataObjectValues", "results"])
      assert results == []
    end
  end

  describe "DO-GQL5: write history detail verification" do
    test "includes correct value and flowNodeInstanceId" do
      process_instance_id =
        http_deploy_and_start("data_object_simple_write.bpmn", "DataObjectSimpleWrite", %{
          "payload" => %{"amount" => 99}
        })

      wait_for_process_instance(process_instance_id)

      query = """
      {
        dataObjectHistory(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
          results {
            dataObjectId
            flowNodeInstanceId
            value
          }
        }
      }
      """

      {200, body} = http_graphql(query)
      results = get_in(body, ["data", "dataObjectHistory", "results"])
      assert length(results) == 1
      [write] = results
      assert write["dataObjectId"] == "DO_1"
      assert write["flowNodeInstanceId"] != nil
      assert write["value"]["total"] == 99
    end
  end

  describe "DO-GQL6: authorization — query without actor" do
    test "rejects unauthenticated requests" do
      process_instance_id =
        http_deploy_and_start("data_object_simple_write.bpmn", "DataObjectSimpleWrite", %{
          "payload" => %{"amount" => 1}
        })

      wait_for_process_instance(process_instance_id)

      json_body =
        Jason.encode!(%{
          "query" => """
          {
            dataObjectValues(filter: {processInstanceId: {eq: "#{process_instance_id}"}}) {
              results { id }
            }
          }
          """
        })

      conn =
        Plug.Test.conn(:post, "/api/v1/graphql", json_body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> route()

      assert conn.status == 401
    end
  end
end
