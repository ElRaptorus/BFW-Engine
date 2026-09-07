defmodule EvilEngine.Persistence.SchemaShapeTest do
  @moduledoc """
  SQL-level SHAPE-* guards: no `final_token`, no `active_tokens` table,
  `gateway_pending_arrivals` columns, and JSONB compression settings.
  """
  use EvilEngine.Persistence.DataCase, async: false

  alias EvilEngine.Persistence.Repo
  alias EvilEngine.Persistence.Repo.Migrations.CreateInitialSchema

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260501110314_create_initial_schema.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  describe "SHAPE-NO-FINAL-TOKEN-COLUMN" do
    test "process_instances has no final_token column" do
      %{rows: rows} =
        Repo.query!("""
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = 'process_instances'
           AND column_name = 'final_token'
        """)

      assert rows == []
    end
  end

  describe "SHAPE-NO-ACTIVE-TOKENS-TABLE" do
    test "public.active_tokens does not exist" do
      %{rows: rows} =
        Repo.query!("""
        SELECT table_name FROM information_schema.tables
         WHERE table_schema = 'public' AND table_name = 'active_tokens'
        """)

      assert rows == []
    end
  end

  describe "SHAPE-GATEWAY-PENDING-EXISTS" do
    test "gateway_pending_arrivals has arrived_payload and join identity columns" do
      %{rows: rows} =
        Repo.query!("""
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = 'gateway_pending_arrivals'
           AND column_name IN (
             'arrived_payload',
             'source_branch_sequence_flow_id',
             'gateway_flow_node_instance_id'
           )
        """)

      names = rows |> Enum.map(&List.first/1) |> Enum.sort()

      assert names == [
               "arrived_payload",
               "gateway_flow_node_instance_id",
               "source_branch_sequence_flow_id"
             ]
    end
  end

  describe "SHAPE-LZ4-APPLIED" do
    test "JSONB columns report the configured toast compression" do
      expected =
        Application.get_env(:peripheral_persistence, :retention, [])
        |> Keyword.get(:jsonb_compression, "lz4")

      for {table_name, column_name} <- CreateInitialSchema.lz4_jsonb_columns() do
        %{rows: [[attcompression]]} =
          Repo.query!(
            """
            SELECT a.attcompression::text
              FROM pg_attribute a
              JOIN pg_class c ON c.oid = a.attrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public'
               AND c.relname = $1
               AND a.attname = $2
               AND a.attnum > 0
               AND NOT a.attisdropped
            """,
            [table_name, column_name]
          )

        assert postgres_compression_name(attcompression) == expected,
               "#{table_name}.#{column_name} compression is #{inspect(attcompression)} (expected #{expected})"
      end
    end
  end

  defp postgres_compression_name(value) when value in ["l", "lz4", <<?l>>], do: "lz4"
  defp postgres_compression_name(value) when value in ["p", "pglz", <<?p>>], do: "pglz"
  defp postgres_compression_name(other), do: other
end
