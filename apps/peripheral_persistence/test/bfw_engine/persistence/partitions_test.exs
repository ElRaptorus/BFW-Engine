defmodule BfwEngine.Persistence.PartitionsTest do
  use BfwEngine.Persistence.DataCase, async: false

  alias BfwEngine.Persistence.Partitions
  alias BfwEngine.Persistence.Repo

  describe "ensure_partitions/0 with partitioning ON" do
    test "creates partitions for all partitioned tables" do
      {:ok, count} = Partitions.ensure_partitions()
      assert count >= 0

      for {table, _col} <- Partitions.partitioned_tables() do
        %{rows: partitions} =
          Repo.query!(
            "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent = '#{table}'::regclass"
          )

        assert partitions != [],
               "Expected at least one partition for #{table}, got none"
      end
    end

    test "is idempotent — running twice creates no additional partitions" do
      {:ok, first_count} = Partitions.ensure_partitions()
      {:ok, second_count} = Partitions.ensure_partitions()

      assert first_count == second_count
    end
  end

  describe "ensure_partitions/0 with partitioning OFF" do
    test "is a no-op and returns zero" do
      previous = Application.get_env(:peripheral_persistence, :partition_interval)
      Application.put_env(:peripheral_persistence, :partition_interval, :off)

      on_exit(fn ->
        Application.put_env(:peripheral_persistence, :partition_interval, previous)
      end)

      assert {:ok, 0} = Partitions.ensure_partitions()
    end
  end

  describe "partitioned_tables/0" do
    test "returns at least two entries" do
      tables = Partitions.partitioned_tables()
      assert length(tables) >= 2
    end

    test "includes process_instance_events and data_object_writes" do
      table_names = Partitions.partitioned_tables() |> Enum.map(&elem(&1, 0))
      assert "process_instance_events" in table_names
      assert "data_object_writes" in table_names
    end
  end
end
