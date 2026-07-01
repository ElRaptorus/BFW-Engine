defmodule EvilEngineWeb.Graphql.SchemaTest do
  use ExUnit.Case, async: true

  test "schema module is declared" do
    assert Code.ensure_loaded?(EvilEngineWeb.Graphql.Schema)
  end

  test "schema exposes process queries from AshGraphql" do
    {:ok, result} =
      Absinthe.run("{ __schema { queryType { name } } }", EvilEngineWeb.Graphql.Schema)

    assert result.data["__schema"]["queryType"]["name"] == "RootQueryType"
  end
end
