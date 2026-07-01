defmodule EvilEngine.Integration.Graphql.GraphqlListFeaturesTest do
  @moduledoc """
  GraphQL integration tests for list features used by Bifrost Forge World
  Engine Workspace views.

  Covers process/decision version listing, ilike filtering, offset pagination,
  sorting, total counts, and nested version includes.
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @process_model_id "LinearStartEnd"
  @process_name "Linear Start End"
  @process_version_string "1.0.0"

  @list_process_versions_query """
  query ListProcessVersions {
    processVersions {
      results {
        id
        version
        processId
        deployedAt
      }
      count
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
        deployedAt
      }
      count
    }
  }
  """

  defp start_linear_process_instances(count) do
    {201, _} = http_deploy("linear_start_end.bpmn")

    for _ <- 1..count do
      {201, body} = http_start(@process_model_id, %{}, @admin_claims)
      wait_for_process_instance(body["processInstanceId"])
    end
  end

  describe "processVersions list query" do
    test "returns deployed process version" do
      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      {200, body} = http_graphql(@list_process_versions_query, %{}, @admin_claims)

      results = body["data"]["processVersions"]["results"]
      assert length(results) >= 1

      found =
        Enum.find(results, fn version ->
          version["version"] == deployed["version"]
        end)

      assert found != nil
      assert found["version"] == @process_version_string
      assert is_binary(found["processId"])
      assert found["deployedAt"] != nil
    end
  end

  describe "decisionVersions list query" do
    test "returns deployed decision version" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]

      {200, body} = http_graphql(@list_decision_versions_query, %{}, @admin_claims)

      results = body["data"]["decisionVersions"]["results"]
      assert length(results) >= 1

      found =
        Enum.find(results, fn version ->
          version["version"] == deployed["version"]
        end)

      assert found != nil
      assert is_binary(found["decisionDefinitionId"])
      assert found["deployedAt"] != nil
    end
  end

  describe "ilike filtering" do
    test "filters processes by partial name match" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      query = """
      query FilterProcessesByName {
        processes(filter: {name: {ilike: "%Linear%"}}) {
          results {
            id
            name
            processModelId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)

      results = body["data"]["processes"]["results"]
      assert length(results) >= 1

      found = Enum.find(results, &(&1["processModelId"] == @process_model_id))
      assert found != nil
      assert found["name"] == @process_name
    end

    test "filters processVersions by partial version string" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      query = """
      query FilterProcessVersionsByVersion {
        processVersions(filter: {version: {ilike: "%1.0%"}}) {
          results {
            id
            version
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)

      results = body["data"]["processVersions"]["results"]
      assert length(results) >= 1

      assert Enum.all?(results, &String.contains?(&1["version"], "1.0"))
    end
  end

  describe "offset pagination" do
    test "paginates with limit and offset for distinct pages" do
      start_linear_process_instances(3)

      first_page_query = """
      query FirstProcessInstancePage {
        processInstances(limit: 1, offset: 0) {
          results {
            id
          }
          count
          hasNextPage
          hasPreviousPage
          pageNumber
          lastPage
        }
      }
      """

      {200, first_body} = http_graphql(first_page_query, %{}, @admin_claims)
      first_page = first_body["data"]["processInstances"]

      assert first_page["count"] >= 3
      assert length(first_page["results"]) == 1
      assert first_page["hasNextPage"] == true
      assert first_page["hasPreviousPage"] == false
      assert first_page["pageNumber"] == 1
      assert first_page["lastPage"] >= 3

      first_id = hd(first_page["results"])["id"]

      second_page_query = """
      query SecondProcessInstancePage {
        processInstances(limit: 1, offset: 1) {
          results {
            id
          }
          pageNumber
          hasPreviousPage
        }
      }
      """

      {200, second_body} = http_graphql(second_page_query, %{}, @admin_claims)
      second_page = second_body["data"]["processInstances"]

      assert length(second_page["results"]) == 1
      assert second_page["pageNumber"] == 2
      assert second_page["hasPreviousPage"] == true

      second_id = hd(second_page["results"])["id"]
      assert second_id != first_id
    end
  end

  describe "sorting" do
    test "returns processInstances sorted by started_at descending" do
      start_linear_process_instances(3)

      query = """
      query SortedProcessInstances {
        processInstances(limit: 10, sort: [{field: STARTED_AT, order: DESC}]) {
          results {
            id
            startedAt
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]
      assert length(results) >= 3

      started_at_values = Enum.map(results, & &1["startedAt"])

      parsed_started_at =
        Enum.map(started_at_values, fn value ->
          {:ok, datetime, _offset} = DateTime.from_iso8601(value)
          datetime
        end)

      assert parsed_started_at == Enum.sort(parsed_started_at, {:desc, DateTime})
    end
  end

  describe "count / totalCount" do
    test "count reflects total matching rows, not just page size" do
      start_linear_process_instances(3)

      query = """
      query ProcessInstanceCount {
        processInstances(limit: 1) {
          results {
            id
          }
          count
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      page = body["data"]["processInstances"]

      assert page["count"] >= 3
      assert length(page["results"]) == 1
    end
  end

  describe "process with nested versions include" do
    test "returns processes with populated versions relationship" do
      {201, deploy_body} = http_deploy("linear_start_end.bpmn")
      [deployed] = deploy_body["deployed"]

      query = """
      query ProcessesWithVersions {
        processes(filter: {processModelId: {eq: "#{@process_model_id}"}}) {
          results {
            id
            processModelId
            name
            versions {
              id
              version
              deployedAt
            }
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processes"]["results"]
      assert length(results) >= 1

      process = hd(results)
      assert process["processModelId"] == @process_model_id
      assert is_list(process["versions"])
      assert length(process["versions"]) >= 1

      version =
        Enum.find(process["versions"], &(&1["version"] == deployed["version"]))

      assert version != nil
      assert version["deployedAt"] != nil
    end
  end
end
