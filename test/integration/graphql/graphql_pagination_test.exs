defmodule BfwEngine.Integration.Graphql.GraphqlPaginationTest do
  @moduledoc """
  GraphQL integration tests for offset pagination edge cases.

  Exercises `limit`/`offset` pagination metadata (`count`, `hasNextPage`,
  `hasPreviousPage`, `pageNumber`, `lastPage`) on processInstances,
  processVersions, and decisionDefinitions list queries.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @process_model_id "LinearStartEnd"

  defp start_linear_process_instances(count) do
    {201, _} = http_deploy("linear_start_end.bpmn")

    for _ <- 1..count do
      {201, body} = http_start(@process_model_id, %{}, @admin_claims)
      wait_for_process_instance(body["processInstanceId"])
    end
  end

  defp process_instances_page_query(limit, offset) do
    """
    query ProcessInstancesPage {
      processInstances(limit: #{limit}, offset: #{offset}) {
        results {
          id
        }
        count
        hasNextPage
        hasPreviousPage
        pageNumber
        lastPage
        limit
      }
    }
    """
  end

  describe "offset beyond total rows" do
    test "returns empty results with correct count and pagination flags" do
      start_linear_process_instances(2)

      query = process_instances_page_query(10, 1000)

      {200, body} = http_graphql(query, %{}, @admin_claims)
      page = body["data"]["processInstances"]

      assert page["results"] == []
      assert page["count"] >= 2
      refute page["hasNextPage"]
      assert page["hasPreviousPage"]
    end
  end

  describe "no limit or offset supplied" do
    test "returns all matching results" do
      start_linear_process_instances(2)

      query = """
      query AllProcessInstances {
        processInstances {
          results {
            id
          }
          count
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      page = body["data"]["processInstances"]

      assert page["count"] >= 2
      assert length(page["results"]) == page["count"]
    end
  end

  describe "full pagination metadata across multiple pages" do
    test "pageNumber, navigation flags, lastPage, and distinct IDs across three pages" do
      start_linear_process_instances(3)

      {200, first_body} =
        http_graphql(process_instances_page_query(1, 0), %{}, @admin_claims)

      first_page = first_body["data"]["processInstances"]

      assert length(first_page["results"]) == 1
      assert first_page["pageNumber"] == 1
      assert first_page["hasPreviousPage"] == false
      assert first_page["hasNextPage"] == true
      assert first_page["count"] >= 3
      first_id = hd(first_page["results"])["id"]

      {200, second_body} =
        http_graphql(process_instances_page_query(1, 1), %{}, @admin_claims)

      second_page = second_body["data"]["processInstances"]

      assert length(second_page["results"]) == 1
      assert second_page["pageNumber"] == 2
      assert second_page["hasPreviousPage"] == true
      assert second_page["hasNextPage"] == true
      second_id = hd(second_page["results"])["id"]

      {200, third_body} =
        http_graphql(process_instances_page_query(1, 2), %{}, @admin_claims)

      third_page = third_body["data"]["processInstances"]

      assert length(third_page["results"]) == 1
      assert third_page["pageNumber"] == 3
      assert third_page["hasPreviousPage"] == true
      third_id = hd(third_page["results"])["id"]

      total_count = third_page["count"]
      assert third_page["lastPage"] == total_count

      if total_count == 3 do
        refute third_page["hasNextPage"]
      else
        assert third_page["hasNextPage"] == (2 + 1 < total_count)
      end

      assert first_id != second_id
      assert second_id != third_id
      assert first_id != third_id
    end
  end

  describe "processVersions pagination" do
    test "returns correct offset pagination metadata" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      query = """
      query ProcessVersionsPage {
        processVersions(limit: 1, offset: 0) {
          results {
            id
            version
          }
          count
          hasNextPage
          hasPreviousPage
          pageNumber
          lastPage
          limit
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      page = body["data"]["processVersions"]

      assert page["count"] >= 1
      assert length(page["results"]) == 1
      assert page["pageNumber"] == 1
      assert page["hasPreviousPage"] == false
      assert page["limit"] == 1
      assert page["lastPage"] == page["count"]
      assert page["hasNextPage"] == (page["count"] > 1)
    end
  end

  describe "decisionDefinitions pagination" do
    test "paginates with distinct results across pages" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy_dmn("literal_expression.dmn")

      first_page_query = """
      query FirstDecisionDefinitionsPage {
        decisionDefinitions(limit: 1, offset: 0) {
          results {
            id
            decisionDefinitionId
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
      first_page = first_body["data"]["decisionDefinitions"]

      assert first_page["count"] >= 2
      assert length(first_page["results"]) == 1
      assert first_page["hasNextPage"] == true
      assert first_page["hasPreviousPage"] == false
      assert first_page["pageNumber"] == 1
      first_id = hd(first_page["results"])["id"]

      second_page_query = """
      query SecondDecisionDefinitionsPage {
        decisionDefinitions(limit: 1, offset: 1) {
          results {
            id
            decisionDefinitionId
          }
          hasNextPage
          hasPreviousPage
          pageNumber
        }
      }
      """

      {200, second_body} = http_graphql(second_page_query, %{}, @admin_claims)
      second_page = second_body["data"]["decisionDefinitions"]

      assert length(second_page["results"]) == 1
      assert second_page["hasPreviousPage"] == true
      assert second_page["pageNumber"] == 2
      second_id = hd(second_page["results"])["id"]

      assert second_id != first_id
    end
  end

  describe "limit equals exact total" do
    test "hasNextPage is false when page size covers all rows" do
      start_linear_process_instances(2)

      query = """
      query ProcessInstancesExactLimit {
        processInstances(limit: 2) {
          results {
            id
          }
          count
          hasNextPage
          limit
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      page = body["data"]["processInstances"]

      assert page["count"] >= 2
      assert page["limit"] == 2
      assert length(page["results"]) == min(2, page["count"])

      if page["count"] == 2 do
        refute page["hasNextPage"]
        assert page["count"] == length(page["results"])
      else
        assert page["hasNextPage"] == (page["count"] > 2)
      end
    end
  end
end
