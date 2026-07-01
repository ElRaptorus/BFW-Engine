defmodule EvilEngine.Integration.Graphql.GraphqlSecurityPhasesTest do
  @moduledoc """
  GraphQL integration tests for security validation phases through the full
  HTTP pipeline.

  Verifies depth limiting and introspection blocking as configured via
  `Application.get_env/3` on `:api_web`. Complements the unit tests in
  `apps/api_web/test/evil_engine_web/graphql/phases/` which exercise the
  phase modules on synthetic Absinthe blueprints only.
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @deep_processes_query """
  query DeepProcesses {
    processes {
      results {
        versions {
          id
        }
      }
    }
  }
  """

  @shallow_processes_query """
  query ShallowProcesses {
    processes {
      results {
        id
      }
    }
  }
  """

  @schema_introspection_query """
  query SchemaIntrospection {
    __schema {
      queryType {
        name
      }
    }
  }
  """

  setup do
    original_depth = Application.get_env(:api_web, :graphql_max_depth)
    original_introspection = Application.get_env(:api_web, :graphql_introspection_disabled)

    on_exit(fn ->
      if is_nil(original_depth) do
        Application.delete_env(:api_web, :graphql_max_depth)
      else
        Application.put_env(:api_web, :graphql_max_depth, original_depth)
      end

      if is_nil(original_introspection) do
        Application.delete_env(:api_web, :graphql_introspection_disabled)
      else
        Application.put_env(:api_web, :graphql_introspection_disabled, original_introspection)
      end
    end)

    :ok
  end

  describe "depth limit" do
    test "rejects query exceeding max depth" do
      Application.put_env(:api_web, :graphql_max_depth, 3)

      {200, body} = http_graphql(@deep_processes_query)

      assert is_list(body["errors"])
      assert length(body["errors"]) >= 1
      assert hd(body["errors"])["message"] =~ ~r/depth limit/i
      refute Map.has_key?(body, "data") && body["data"] != nil
    end

    test "allows query within max depth" do
      Application.put_env(:api_web, :graphql_max_depth, 3)

      {200, body} = http_graphql(@shallow_processes_query)

      refute Map.has_key?(body, "errors")
      assert is_list(body["data"]["processes"]["results"])
    end
  end

  describe "introspection block" do
    test "rejects __schema when introspection is disabled" do
      Application.put_env(:api_web, :graphql_introspection_disabled, true)

      {200, body} = http_graphql(@schema_introspection_query)

      assert is_list(body["errors"])
      assert length(body["errors"]) >= 1
      assert hd(body["errors"])["message"] =~ "disabled"
    end

    test "allows regular query when introspection is disabled" do
      Application.put_env(:api_web, :graphql_introspection_disabled, true)

      {200, body} = http_graphql(@shallow_processes_query)

      refute Map.has_key?(body, "errors")
      assert is_list(body["data"]["processes"]["results"])
    end

    test "allows __schema when introspection is enabled (default)" do
      Application.delete_env(:api_web, :graphql_introspection_disabled)

      {200, body} = http_graphql(@schema_introspection_query)

      refute Map.has_key?(body, "errors")
      assert body["data"]["__schema"]["queryType"]["name"] == "RootQueryType"
    end
  end
end
