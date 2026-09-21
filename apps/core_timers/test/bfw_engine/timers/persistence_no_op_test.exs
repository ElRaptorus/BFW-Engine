defmodule BfwEngine.Timers.Persistence.NoOpTest do
  use ExUnit.Case, async: false

  alias BfwEngine.Timers.Persistence.NoOp

  setup do
    NoOp.reset_state()
    :ok
  end

  describe "create_schedule/1" do
    test "creates a schedule record with given attributes" do
      attrs = %{
        process_version_id: "pv-1",
        process_model_id: "order-process",
        flow_node_id: "TimerStart_1",
        kind: "cycle",
        iso_spec: "R/PT1H",
        enabled: true,
        next_fire_at: ~U[2026-06-01 11:00:00Z],
        last_triggered_at: nil,
        cycle_total: nil,
        cycle_remaining: nil
      }

      assert {:ok, record} = NoOp.create_schedule(attrs)
      assert is_binary(record.id)
      assert record.process_version_id == "pv-1"
      assert record.flow_node_id == "TimerStart_1"
      assert record.kind == "cycle"
      assert record.enabled == true
    end

    test "auto-generates an ID if not provided" do
      {:ok, record} = NoOp.create_schedule(%{process_version_id: "pv-1"})
      assert is_binary(record.id)
      assert String.length(record.id) > 0
    end

    test "uses provided ID if given" do
      {:ok, record} = NoOp.create_schedule(%{id: "custom-id", process_version_id: "pv-1"})
      assert record.id == "custom-id"
    end
  end

  describe "update_schedule/2" do
    test "updates existing schedule fields" do
      {:ok, record} = NoOp.create_schedule(%{process_version_id: "pv-1", enabled: true})

      assert {:ok, updated} = NoOp.update_schedule(record.id, %{enabled: false})
      assert updated.enabled == false
      assert updated.process_version_id == "pv-1"
    end

    test "returns :not_found for nonexistent ID" do
      assert {:error, :not_found} = NoOp.update_schedule("nonexistent", %{enabled: false})
    end
  end

  describe "get_schedule/1" do
    test "returns existing schedule" do
      {:ok, record} = NoOp.create_schedule(%{id: "sched-1", process_version_id: "pv-1"})
      assert {:ok, ^record} = NoOp.get_schedule("sched-1")
    end

    test "returns :not_found for nonexistent ID" do
      assert {:error, :not_found} = NoOp.get_schedule("nonexistent")
    end
  end

  describe "list_armed_schedules/0" do
    test "returns only enabled schedules with non-nil next_fire_at" do
      NoOp.create_schedule(%{id: "s1", enabled: true, next_fire_at: ~U[2026-06-01 10:00:00Z]})
      NoOp.create_schedule(%{id: "s2", enabled: false, next_fire_at: ~U[2026-06-01 11:00:00Z]})
      NoOp.create_schedule(%{id: "s3", enabled: true, next_fire_at: nil})
      NoOp.create_schedule(%{id: "s4", enabled: true, next_fire_at: ~U[2026-06-01 09:00:00Z]})

      {:ok, armed} = NoOp.list_armed_schedules()
      armed_ids = Enum.map(armed, & &1.id)

      assert "s1" in armed_ids
      assert "s4" in armed_ids
      refute "s2" in armed_ids
      refute "s3" in armed_ids
    end

    test "returns schedules sorted by next_fire_at" do
      NoOp.create_schedule(%{id: "late", enabled: true, next_fire_at: ~U[2026-06-02 10:00:00Z]})
      NoOp.create_schedule(%{id: "early", enabled: true, next_fire_at: ~U[2026-06-01 08:00:00Z]})

      {:ok, armed} = NoOp.list_armed_schedules()
      assert [%{id: "early"}, %{id: "late"}] = armed
    end

    test "returns empty list when no schedules exist" do
      assert {:ok, []} = NoOp.list_armed_schedules()
    end
  end

  describe "list_all_schedules/1" do
    test "returns all schedules regardless of enabled/fire state" do
      NoOp.create_schedule(%{id: "s1", enabled: true, next_fire_at: ~U[2026-06-01 10:00:00Z]})
      NoOp.create_schedule(%{id: "s2", enabled: false, next_fire_at: nil})

      {:ok, all} = NoOp.list_all_schedules()
      assert length(all) == 2
    end

    test "filters by process_version_id when provided" do
      NoOp.create_schedule(%{id: "s1", process_version_id: "pv-1"})
      NoOp.create_schedule(%{id: "s2", process_version_id: "pv-1"})
      NoOp.create_schedule(%{id: "s3", process_version_id: "pv-2"})

      {:ok, filtered} = NoOp.list_all_schedules(process_version_id: "pv-1")
      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.process_version_id == "pv-1"))
    end

    test "returns all when no filter is given" do
      NoOp.create_schedule(%{id: "s1", process_version_id: "pv-1"})
      NoOp.create_schedule(%{id: "s2", process_version_id: "pv-2"})

      {:ok, all} = NoOp.list_all_schedules([])
      assert length(all) == 2
    end
  end

  describe "delete_schedules_for_version/1" do
    test "deletes all schedules for a given process version" do
      NoOp.create_schedule(%{id: "s1", process_version_id: "pv-1"})
      NoOp.create_schedule(%{id: "s2", process_version_id: "pv-1"})
      NoOp.create_schedule(%{id: "s3", process_version_id: "pv-2"})

      assert :ok = NoOp.delete_schedules_for_version("pv-1")

      {:ok, remaining} = NoOp.list_all_schedules()
      assert length(remaining) == 1
      assert hd(remaining).id == "s3"
    end

    test "is a no-op when no schedules match" do
      assert :ok = NoOp.delete_schedules_for_version("nonexistent")
    end
  end

  describe "reset_state/0" do
    test "clears all stored schedules" do
      NoOp.create_schedule(%{id: "s1"})
      NoOp.create_schedule(%{id: "s2"})

      NoOp.reset_state()
      {:ok, all} = NoOp.list_all_schedules()
      assert all == []
    end
  end
end
