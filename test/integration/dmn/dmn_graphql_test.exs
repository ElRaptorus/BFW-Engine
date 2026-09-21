defmodule BfwEngine.Integration.DMN.DmnGraphqlTest do
  @moduledoc """
  GraphQL integration tests for DMN decision definitions.

  Exercises `listDecisionDefinitions` and `getDecisionDefinition` queries
  through the full HTTP/GraphQL pipeline.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @list_decisions_query """
  query ListDecisionDefinitions {
    decisionDefinitions {
      results {
        id
        decisionDefinitionId
        name
        enabled
      }
    }
  }
  """

  @get_decision_query """
  query GetDecisionDefinition($id: ID!) {
    getDecisionDefinition(id: $id) {
      id
      decisionDefinitionId
      name
      enabled
    }
  }
  """

  describe "listDecisionDefinitions" do
    test "returns empty list when no decisions deployed" do
      {200, body} = http_graphql(@list_decisions_query)

      assert body["data"]["decisionDefinitions"]["results"] == []
    end

    test "returns deployed decision definitions" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]

      {200, body} = http_graphql(@list_decisions_query)

      results = body["data"]["decisionDefinitions"]["results"]
      assert length(results) >= 1

      found =
        Enum.find(results, &(&1["decisionDefinitionId"] == deployed["decisionDefinitionId"]))

      assert found != nil
      assert found["enabled"] == true
      assert is_binary(found["id"])
    end

    test "lists multiple deployed definitions" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy_dmn("literal_expression.dmn")

      {200, body} = http_graphql(@list_decisions_query)

      results = body["data"]["decisionDefinitions"]["results"]
      assert length(results) >= 2
    end
  end

  describe "getDecisionDefinition" do
    test "returns a specific decision definition by ID" do
      {201, deploy_body} = http_deploy_dmn("simple_unique.dmn")
      [deployed] = deploy_body["deployed"]

      {200, list_body} = http_graphql(@list_decisions_query)
      results = list_body["data"]["decisionDefinitions"]["results"]

      found =
        Enum.find(results, &(&1["decisionDefinitionId"] == deployed["decisionDefinitionId"]))

      assert found != nil

      {200, get_body} = http_graphql(@get_decision_query, %{"id" => found["id"]})
      definition = get_body["data"]["getDecisionDefinition"]

      assert definition["id"] == found["id"]
      assert definition["decisionDefinitionId"] == deployed["decisionDefinitionId"]
      assert definition["enabled"] == true
    end

    test "returns null for non-existent ID" do
      fake_id = Ash.UUIDv7.generate()
      {200, body} = http_graphql(@get_decision_query, %{"id" => fake_id})

      assert body["data"]["getDecisionDefinition"] == nil
    end
  end
end
