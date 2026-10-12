defmodule BfwEngineWeb.ContractExportTest do
  use ExUnit.Case, async: true

  alias BfwEngineWeb.ContractExport

  @repository_root Path.expand("../../../..", __DIR__)

  describe "render_all/0" do
    test "committed contract files match the generated output" do
      for {path, content} <- ContractExport.render_all() do
        committed = @repository_root |> Path.join(path) |> File.read!()

        assert committed == content,
               "#{path} is stale. Run `mix bfw.gen.contracts` and commit the result."
      end
    end

    test "exports the GraphQL SDL with the query root and resource pages" do
      sdl = contract_content("contracts/graphql/schema.graphql")

      assert sdl =~ "query: RootQueryType"
      assert sdl =~ "type PageOfProcessInstance"
    end

    test "exports the OpenAPI document without the runtime servers block" do
      document = "contracts/openapi.json" |> contract_content() |> Jason.decode!()

      assert document["openapi"] =~ "3."
      assert is_map(document["paths"]["/processes"])
      refute Map.has_key?(document, "servers")
    end

    test "is deterministic across calls" do
      assert ContractExport.render_all() == ContractExport.render_all()
    end
  end

  defp contract_content(path) do
    {^path, content} = path |> then(&List.keyfind(ContractExport.render_all(), &1, 0))
    content
  end
end
