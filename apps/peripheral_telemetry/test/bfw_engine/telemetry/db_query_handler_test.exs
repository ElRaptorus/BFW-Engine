defmodule BfwEngine.Telemetry.DbQueryHandlerTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Telemetry.DbQueryHandler

  describe "source_from_metadata/1" do
    test "keeps a non-blank string source" do
      assert DbQueryHandler.source_from_metadata(%{source: "flow_node_instances"}) ==
               "flow_node_instances"
    end

    test "stringifies an atom source" do
      assert DbQueryHandler.source_from_metadata(%{source: :messages}) == "messages"
    end

    test "unwraps a {prefix, source} tuple" do
      assert DbQueryHandler.source_from_metadata(%{source: {"public", :data_objects}}) ==
               "data_objects"
    end

    test "parses INSERT INTO for raw SQL with no Ecto source" do
      query = """
      INSERT INTO data_object_writes (id, process_instance_id, data_object_id,
                                      flow_node_instance_id, value, created_at)
      VALUES ($1, $2, $3, $4, $5, $6)
      """

      assert DbQueryHandler.source_from_metadata(%{query: query}) == "data_object_writes"
    end

    test "parses quoted INSERT INTO public.table" do
      query = ~s[INSERT INTO "data_objects" (id) VALUES ($1)]
      assert DbQueryHandler.source_from_metadata(%{query: query}) == "data_objects"
    end

    test "falls back to unknown when the query has no table" do
      assert DbQueryHandler.source_from_metadata(%{query: "SELECT 1"}) == "unknown"
    end
  end
end
