defmodule BfwEngine.Integration.Graphql.GraphqlErrorHandlingTest do
  @moduledoc """
  GraphQL integration tests for error handling and schema validation.

  Verifies that invalid syntax, nonexistent fields, and invalid sort
  enum values produce structured GraphQL errors rather than HTTP 500s.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  describe "invalid GraphQL syntax" do
    test "returns error for malformed query" do
      {200, body} = http_graphql("{ processes { results { id }")

      assert is_list(body["errors"])
      assert length(body["errors"]) >= 1
    end
  end

  describe "nonexistent field" do
    test "returns schema validation error for unknown field" do
      query = """
      {
        processes {
          results {
            id
            thisFieldDoesNotExist
          }
        }
      }
      """

      {200, body} = http_graphql(query)

      assert is_list(body["errors"])
      assert length(body["errors"]) >= 1

      error_message = hd(body["errors"])["message"]
      assert error_message =~ "thisFieldDoesNotExist"
    end
  end

  describe "nonexistent query" do
    test "returns error for unknown root query" do
      query = """
      {
        nonExistentQuery {
          id
        }
      }
      """

      {200, body} = http_graphql(query)

      assert is_list(body["errors"])
      assert length(body["errors"]) >= 1
    end
  end

  describe "invalid sort enum value" do
    test "returns error for unrecognized sort field" do
      query = """
      {
        processInstances(sort: [{field: NONEXISTENT_FIELD, order: ASC}]) {
          results {
            id
          }
        }
      }
      """

      {200, body} = http_graphql(query)

      assert is_list(body["errors"])
      assert length(body["errors"]) >= 1
    end
  end

  describe "invalid filter field" do
    test "returns error for unknown filter attribute" do
      query = """
      {
        processes(filter: {nonExistentField: {eq: "test"}}) {
          results {
            id
          }
        }
      }
      """

      {200, body} = http_graphql(query)

      assert is_list(body["errors"])
      assert length(body["errors"]) >= 1
    end
  end
end
