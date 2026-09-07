defmodule EvilEngineWeb.Graphql.ComplexityLimitTest do
  @moduledoc """
  Pins the Studio debugger's `dataObjectValues(limit: 500)` snapshot query
  against AshGraphql's `limit * child_complexity` scoring.

  Pure unit tests — complexity analysis stops before resolvers, so no
  database or HTTP is required.
  """
  use ExUnit.Case, async: false

  alias Absinthe.Pipeline
  alias EvilEngineWeb.Graphql.PipelineModifier
  alias EvilEngineWeb.Graphql.Schema

  # Mirrors `EngineAdapter.loadProcessWithModelGraph` in Bifrost Forge World:
  # `queryDataObjectValues` with offset pagination, six result fields, and
  # the page-metadata set `buildListQuery` always selects for `mode: 'offset'`.
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

  describe "Studio debugger dataObjectValues snapshot" do
    test "AshGraphql scores limit 500 above the old 1000 cap" do
      complexity = operation_complexity(@debugger_data_object_values_query)

      assert complexity > 1000,
             "expected limit*children scoring to exceed 1000, got #{complexity}"
    end

    test "the configured default cap covers the debugger snapshot score" do
      complexity = operation_complexity(@debugger_data_object_values_query)
      cap = PipelineModifier.max_complexity()

      assert cap >= complexity,
             "TDE_GRAPHQL_MAX_COMPLEXITY (#{cap}) is below the debugger snapshot score (#{complexity})"
    end

    test "the snapshot query is rejected when the cap is 1000" do
      {:ok, result} =
        Absinthe.run(@debugger_data_object_values_query, Schema,
          analyze_complexity: true,
          max_complexity: 1000
        )

      assert complexity_error?(result),
             "expected a complexity error at cap 1000, got: #{inspect(result[:errors])}"
    end

    test "the snapshot query is not rejected at the configured cap" do
      cap = PipelineModifier.max_complexity()
      blueprint = analyze_upto_complexity(@debugger_data_object_values_query, cap)

      refute complexity_error_in_blueprint?(blueprint),
             "debugger snapshot rejected at cap #{cap}: #{inspect(blueprint.execution.validation_errors)}"
    end
  end

  defp complexity_error?(result) do
    errors = Map.get(result, :errors) || Map.get(result, "errors") || []
    Enum.any?(errors, &too_complex_message?/1)
  end

  defp complexity_error_in_blueprint?(blueprint) do
    Enum.any?(blueprint.execution.validation_errors || [], &too_complex_message?/1)
  end

  defp too_complex_message?(%{message: message}) when is_binary(message) do
    String.contains?(message, "too complex")
  end

  defp too_complex_message?(error) when is_map(error) do
    message = error[:message] || error["message"]
    is_binary(message) and String.contains?(message, "too complex")
  end

  defp too_complex_message?(_error), do: false

  defp operation_complexity(query) do
    blueprint = analyze_upto_complexity(query, 1_000_000)
    operation = Absinthe.Blueprint.current_operation(blueprint)
    assert is_integer(operation.complexity)
    operation.complexity
  end

  defp analyze_upto_complexity(query, max_complexity) do
    pipeline =
      Schema
      |> Pipeline.for_document(analyze_complexity: true, max_complexity: max_complexity)
      |> Pipeline.upto(Absinthe.Phase.Document.Complexity.Result)

    case Pipeline.run(query, pipeline) do
      {:ok, blueprint, _phases} -> blueprint
      {:error, blueprint, _phases} -> blueprint
      {:jump, blueprint, _phase} -> blueprint
    end
  end
end
