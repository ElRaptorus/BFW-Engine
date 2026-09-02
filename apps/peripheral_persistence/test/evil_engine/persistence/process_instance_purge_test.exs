defmodule EvilEngine.Persistence.ProcessInstancePurgeTest do
  @moduledoc """
  Unit tests for `EvilEngine.Persistence.ProcessInstancePurge`.

  Covers eligibility (unset knobs, cancelled, soft-deleted roots),
  skip-when-descendant-running, nested terminal trees, dry-run, and
  cascade of data-object / gateway rows.
  """

  use EvilEngine.Persistence.DataCase, async: false

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias EvilEngine.Persistence.ExecutionAdapter
  alias EvilEngine.Persistence.ProcessInstancePurge
  alias EvilEngine.Persistence.Repo
  alias EvilEngine.Persistence.Resources.GatewayPendingArrival
  alias EvilEngine.Persistence.Resources.ProcessInstance

  describe "purge_eligible_trees/1" do
    test "unset policies return zero purged roots" do
      {:ok, %{id: process_instance_id}} = create_terminal_root("finished", days_ago: 30)

      assert {:ok, %{purged_root_count: 0, skipped_root_count: 0, dry_run: false}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [],
                 now: DateTime.utc_now()
               )

      assert process_instance_row_exists?(process_instance_id)
    end

    test "aged finished root with no children deletes PI, FNI, data objects, and gateway rows" do
      {:ok, %{id: process_instance_id}} = create_terminal_root("finished", days_ago: 10)

      {:ok, %{id: flow_node_instance_id}} =
        ExecutionAdapter.create_flow_node_instance(%{
          process_instance_id: process_instance_id,
          flow_node_id: "Task_1",
          flow_node_type: "task",
          state: "finished",
          started_at: DateTime.utc_now()
        })

      {:ok, _write} =
        ExecutionAdapter.write_data_object(%{
          process_instance_id: process_instance_id,
          data_object_id: "DO_Order",
          flow_node_instance_id: flow_node_instance_id,
          value: %{"status" => "ok"}
        })

      {:ok, _arrival} =
        Ash.create(
          GatewayPendingArrival,
          %{
            process_instance_id: process_instance_id,
            gateway_flow_node_instance_id: flow_node_instance_id,
            source_branch_sequence_flow_id: "Flow_1",
            source_flow_node_instance_id: flow_node_instance_id,
            arrived_payload: %{},
            arrived_at: DateTime.utc_now()
          },
          authorize?: false
        )

      assert {:ok, %{purged_root_count: 1, skipped_root_count: 0, dry_run: false}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 1],
                 now: DateTime.utc_now()
               )

      refute process_instance_row_exists?(process_instance_id)
      assert count_flow_node_instances(process_instance_id) == 0
      assert count_data_objects(process_instance_id) == 0
      assert count_data_object_writes(process_instance_id) == 0
      assert count_gateway_pending_arrivals(process_instance_id) == 0
    end

    test "skips an aged root when a child is still running" do
      {:ok, %{id: root_id}} = create_terminal_root("finished", days_ago: 10)

      {:ok, %{id: child_id}} =
        ExecutionAdapter.create_process_instance(%{
          process_version_id: Ash.UUIDv7.generate(),
          parent_process_instance_id: root_id,
          state: "running",
          started_at: DateTime.utc_now()
        })

      assert {:ok, %{purged_root_count: 0, skipped_root_count: 1, dry_run: false}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 1],
                 now: DateTime.utc_now()
               )

      assert process_instance_row_exists?(root_id)
      assert process_instance_row_exists?(child_id)
    end

    test "skips an aged root when a descendant is suspended" do
      {:ok, %{id: root_id}} = create_terminal_root("finished", days_ago: 10)

      {:ok, %{id: child_id}} =
        ExecutionAdapter.create_process_instance(%{
          process_version_id: Ash.UUIDv7.generate(),
          parent_process_instance_id: root_id,
          state: "suspended",
          started_at: DateTime.utc_now()
        })

      assert {:ok, %{purged_root_count: 0, skipped_root_count: 1, dry_run: false}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 1],
                 now: DateTime.utc_now()
               )

      assert process_instance_row_exists?(root_id)
      assert process_instance_row_exists?(child_id)
    end

    test "string days knobs are accepted; zero and garbage knobs are ignored" do
      {:ok, %{id: process_instance_id}} = create_terminal_root("finished", days_ago: 10)

      refute ProcessInstancePurge.any_days_policy?(finished_days: 0)
      refute ProcessInstancePurge.any_days_policy?(finished_days: "")
      refute ProcessInstancePurge.any_days_policy?(finished_days: "abc")
      assert ProcessInstancePurge.any_days_policy?(finished_days: "1")

      assert {:ok, %{purged_root_count: 0}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 0],
                 now: DateTime.utc_now()
               )

      assert process_instance_row_exists?(process_instance_id)

      assert {:ok, %{purged_root_count: 1}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: "1"],
                 now: DateTime.utc_now()
               )

      refute process_instance_row_exists?(process_instance_id)
    end

    test "deletes a nested Call Activity / SubProcess tree when every descendant is terminal" do
      {:ok, %{id: root_id}} = create_terminal_root("finished", days_ago: 10)

      {:ok, %{id: child_id}} =
        create_terminal_child(root_id, "finished", days_ago: 0)

      {:ok, %{id: grandchild_id}} =
        create_terminal_child(child_id, "finished", days_ago: 0)

      assert {:ok, %{purged_root_count: 1, skipped_root_count: 0, dry_run: false}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 1],
                 now: DateTime.utc_now()
               )

      refute process_instance_row_exists?(root_id)
      refute process_instance_row_exists?(child_id)
      refute process_instance_row_exists?(grandchild_id)
    end

    test "dry-run counts eligible roots without deleting rows" do
      {:ok, %{id: process_instance_id}} = create_terminal_root("finished", days_ago: 10)

      assert {:ok, %{purged_root_count: 1, skipped_root_count: 0, dry_run: true}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 1],
                 dry_run: true,
                 now: DateTime.utc_now()
               )

      assert process_instance_row_exists?(process_instance_id)
    end

    test "cancelled roots purge only when cancelled_days is set" do
      {:ok, %{id: process_instance_id}} = create_terminal_root("cancelled", days_ago: 10)

      assert {:ok, %{purged_root_count: 0, skipped_root_count: 0}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 1],
                 now: DateTime.utc_now()
               )

      assert process_instance_row_exists?(process_instance_id)

      assert {:ok, %{purged_root_count: 1, skipped_root_count: 0}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [cancelled_days: 1],
                 now: DateTime.utc_now()
               )

      refute process_instance_row_exists?(process_instance_id)
    end

    test "soft-deleted aged finished roots are still eligible" do
      {:ok, %{id: process_instance_id}} = create_terminal_root("finished", days_ago: 10)

      {:ok, record} = Ash.get(ProcessInstance, process_instance_id, authorize?: false)

      {:ok, _updated} =
        Ash.update(
          record,
          %{
            deleted: true,
            deleted_at: DateTime.utc_now(),
            deleted_by: %{"id" => "admin"}
          },
          action: :soft_delete,
          authorize?: false
        )

      assert {:ok, %{purged_root_count: 1, skipped_root_count: 0}} =
               ProcessInstancePurge.purge_eligible_trees(
                 retention_config: [finished_days: 1],
                 now: DateTime.utc_now()
               )

      refute process_instance_row_exists?(process_instance_id)
    end
  end

  defp create_terminal_root(state, days_ago: days_ago) do
    now = DateTime.utc_now()

    {:ok, created} =
      ExecutionAdapter.create_process_instance(%{
        process_version_id: Ash.UUIDv7.generate(),
        state: "running",
        started_at: DateTime.add(now, -days_ago, :day)
      })

    :ok =
      ExecutionAdapter.update_process_instance(created.id, %{
        state: state,
        finished_at: DateTime.add(now, -days_ago, :day)
      })

    {:ok, created}
  end

  defp create_terminal_child(parent_id, state, days_ago: days_ago) do
    now = DateTime.utc_now()

    {:ok, created} =
      ExecutionAdapter.create_process_instance(%{
        process_version_id: Ash.UUIDv7.generate(),
        parent_process_instance_id: parent_id,
        state: "running",
        started_at: DateTime.add(now, -days_ago, :day)
      })

    :ok =
      ExecutionAdapter.update_process_instance(created.id, %{
        state: state,
        finished_at: DateTime.add(now, -days_ago, :day)
      })

    {:ok, created}
  end

  defp process_instance_row_exists?(process_instance_id) do
    %{rows: [[count]]} =
      EctoSQL.query!(
        Repo,
        "SELECT COUNT(*) FROM process_instances WHERE id = $1::uuid",
        [dump_uuid!(process_instance_id)]
      )

    count > 0
  end

  defp count_flow_node_instances(process_instance_id) do
    count_child_rows("flow_node_instances", process_instance_id)
  end

  defp count_data_objects(process_instance_id) do
    count_child_rows("data_objects", process_instance_id)
  end

  defp count_data_object_writes(process_instance_id) do
    count_child_rows("data_object_writes", process_instance_id)
  end

  defp count_gateway_pending_arrivals(process_instance_id) do
    count_child_rows("gateway_pending_arrivals", process_instance_id)
  end

  defp count_child_rows(table, process_instance_id)
       when table in [
              "flow_node_instances",
              "data_objects",
              "data_object_writes",
              "gateway_pending_arrivals"
            ] do
    %{rows: [[count]]} =
      EctoSQL.query!(
        Repo,
        "SELECT COUNT(*) FROM #{table} WHERE process_instance_id = $1::uuid",
        [dump_uuid!(process_instance_id)]
      )

    count
  end

  defp dump_uuid!(uuid_string) do
    {:ok, binary} = Ecto.UUID.dump(uuid_string)
    binary
  end
end
