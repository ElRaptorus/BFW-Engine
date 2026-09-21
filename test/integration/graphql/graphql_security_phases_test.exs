defmodule BfwEngine.Integration.Graphql.GraphqlSecurityPhasesTest do
  @moduledoc """
  GraphQL integration tests for security validation phases through the full
  HTTP pipeline.

  Verifies depth limiting, complexity limiting, and introspection blocking
  as configured via `Application.get_env/3` on `:api_web`. Complements the
  unit tests in `apps/api_web/test/bfw_engine_web/graphql/` which exercise
  the phase modules on synthetic Absinthe blueprints only.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

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

  # Mirrors the Studio debugger's parallel `queryDataObjectValues` call
  # (`limit: 500`, six result fields, offset page metadata).
  @debugger_data_object_values_query """
  query DebuggerDataObjectValues {
    dataObjectValues(
      filter: {processInstanceId: {eq: "00000000-0000-0000-0000-000000000001"}}
      limit: 500
    ) {
      results {
        id
        dataObjectId
        flowNodeInstanceId
        value
        createdAt
        processInstanceId
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

  setup do
    original_depth = Application.get_env(:api_web, :graphql_max_depth)
    original_introspection = Application.get_env(:api_web, :graphql_introspection_disabled)
    original_complexity = Application.get_env(:api_web, :graphql_max_complexity)

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

      if is_nil(original_complexity) do
        Application.delete_env(:api_web, :graphql_max_complexity)
      else
        Application.put_env(:api_web, :graphql_max_complexity, original_complexity)
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

  describe "complexity limit" do
    test "rejects the debugger dataObjectValues snapshot when the cap is 1000" do
      Application.put_env(:api_web, :graphql_max_complexity, 1000)

      {200, body} = http_graphql(@debugger_data_object_values_query, %{}, @admin_claims)

      assert is_list(body["errors"])
      assert hd(body["errors"])["message"] =~ ~r/too complex/i
    end

    test "allows the debugger dataObjectValues snapshot at the default cap" do
      {200, body} = http_graphql(@debugger_data_object_values_query, %{}, @admin_claims)

      refute complexity_error?(body),
             "debugger snapshot rejected at default cap: #{inspect(body["errors"])}"

      assert is_list(get_in(body, ["data", "dataObjectValues", "results"]))
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

  defp complexity_error?(body) do
    errors = body["errors"] || []

    Enum.any?(errors, fn error ->
      is_binary(error["message"]) and String.contains?(error["message"], "too complex")
    end)
  end
end
