defmodule BfwEngine.Telemetry.DbQueryHandlerTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Telemetry.DbQueryHandler

  describe "handle_event/4 source" do
    test "keeps a non-blank string source" do
      assert source_of(%{source: "flow_node_instances"}) == "flow_node_instances"
    end

    test "stringifies an atom source" do
      assert source_of(%{source: :messages}) == "messages"
    end

    test "unwraps a {prefix, source} tuple" do
      assert source_of(%{source: {"public", :data_objects}}) == "data_objects"
    end

    test "parses INSERT INTO for raw SQL with no Ecto source" do
      query = """
      INSERT INTO data_object_writes (id, process_instance_id, data_object_id,
                                      flow_node_instance_id, value, created_at)
      VALUES ($1, $2, $3, $4, $5, $6)
      """

      assert source_of(%{query: query}) == "data_object_writes"
    end

    test "parses quoted INSERT INTO public.table" do
      query = ~s[INSERT INTO "data_objects" (id) VALUES ($1)]
      assert source_of(%{query: query}) == "data_objects"
    end

    test "falls back to unknown when the query has no table" do
      assert source_of(%{query: "SELECT 1"}) == "unknown"
    end
  end

  defp source_of(metadata) do
    handler_id = "db-query-handler-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:bfw_engine, :db, :query],
      fn _event, _measurements, metadata, _config ->
        send(self(), {:source, metadata.source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    DbQueryHandler.handle_event([:bfw_engine, :repo, :query], %{}, metadata, %{repos: %{}})

    assert_receive {:source, source}
    source
  end
end
