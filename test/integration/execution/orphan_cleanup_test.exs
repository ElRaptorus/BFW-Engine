defmodule EvilEngine.Integration.Execution.OrphanCleanupTest do
  @moduledoc """
  Integration tests for the boot-time orphan cleanup sweep.

  These tests directly insert DB rows to simulate crash scenarios where
  the engine died mid-cascade, leaving orphaned PIs or FNIs. They then
  call the adapter's cleanup functions and verify the resulting DB state.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Persistence.ExecutionAdapter

  alias EvilEngine.Persistence.Resources.FlowNodeInstance, as: FniResource
  alias EvilEngine.Persistence.Resources.ProcessInstance, as: PiResource

  @domain EvilEngine.Persistence.Api
  @dummy_process_version_id "01966b00-0000-7000-8000-000000000001"

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp insert_process_instance(attrs) do
    id = Map.get(attrs, :id, Ash.UUIDv7.generate())
    target_state = Map.get(attrs, :state, "running")
    finished_at = Map.get(attrs, :finished_at)

    create_attrs = %{
      id: id,
      process_version_id: Map.get(attrs, :process_version_id, @dummy_process_version_id),
      state: "running",
      started_at: Map.get(attrs, :started_at, DateTime.utc_now()),
      started_by: Map.get(attrs, :started_by, %{"id" => "test-user"}),
      parent_process_instance_id: Map.get(attrs, :parent_process_instance_id)
    }

    {:ok, record} = Ash.create(PiResource, create_attrs, domain: @domain, authorize?: false)

    if target_state != "running" do
      update_changes = %{state: target_state, finished_at: finished_at || DateTime.utc_now()}
      {:ok, _} = Ash.update(record, update_changes, domain: @domain, action: :update_state, authorize?: false)
    end

    id
  end

  @terminal_fni_states ~w(finished fatal aborted interrupted error)

  defp insert_flow_node_instance(attrs) do
    id = Map.get(attrs, :id, Ash.UUIDv7.generate())
    target_state = Map.get(attrs, :state, "active")

    create_attrs = %{
      id: id,
      process_instance_id: Map.fetch!(attrs, :process_instance_id),
      flow_node_id: Map.get(attrs, :flow_node_id, "Task_1"),
      flow_node_type: Map.get(attrs, :flow_node_type, "service_task"),
      state: target_state,
      started_at: Map.get(attrs, :started_at, DateTime.utc_now())
    }

    {:ok, record} = Ash.create(FniResource, create_attrs, domain: @domain, authorize?: false)

    if target_state in @terminal_fni_states do
      finished_at = Map.get(attrs, :finished_at, DateTime.utc_now())

      {:ok, _} =
        Ash.update(record, %{finished_at: finished_at},
          domain: @domain,
          action: :update_finished,
          authorize?: false
        )
    end

    id
  end

  # -------------------------------------------------------------------
  # Orphaned FNI tests
  # -------------------------------------------------------------------

  describe "cleanup_orphaned_flow_node_instances/0" do
    test "aborts active FNIs on a fatal PI" do
      process_instance_id = insert_process_instance(%{state: "fatal", finished_at: DateTime.utc_now()})

      fni_id =
        insert_flow_node_instance(%{
          process_instance_id: process_instance_id,
          state: "active"
        })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_flow_node_instances()
      assert count == 1

      fni = fetch_flow_node_instances(process_instance_id) |> Enum.find(&(&1.id == fni_id))
      assert fni.state == "aborted"
      assert fni.finished_at != nil
      assert fni.error_info["error_code"] == "orphaned_fni_cleanup"
      assert fni.error_info["message"] =~ "engine startup"
    end

    test "aborts waiting FNIs on an aborted PI" do
      process_instance_id = insert_process_instance(%{state: "aborted", finished_at: DateTime.utc_now()})

      fni_id =
        insert_flow_node_instance(%{
          process_instance_id: process_instance_id,
          flow_node_type: "user_task",
          state: "waiting"
        })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_flow_node_instances()
      assert count == 1

      fni = fetch_flow_node_instances(process_instance_id) |> Enum.find(&(&1.id == fni_id))
      assert fni.state == "aborted"
      assert fni.error_info["error_code"] == "orphaned_fni_cleanup"
    end

    test "aborts FNIs on a finished PI" do
      process_instance_id = insert_process_instance(%{state: "finished", finished_at: DateTime.utc_now()})

      fni_id =
        insert_flow_node_instance(%{
          process_instance_id: process_instance_id,
          state: "active"
        })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_flow_node_instances()
      assert count == 1

      fni = fetch_flow_node_instances(process_instance_id) |> Enum.find(&(&1.id == fni_id))
      assert fni.state == "aborted"
    end

    test "does not touch FNIs on a running PI" do
      process_instance_id = insert_process_instance(%{state: "running"})

      insert_flow_node_instance(%{
        process_instance_id: process_instance_id,
        state: "active"
      })

      insert_flow_node_instance(%{
        process_instance_id: process_instance_id,
        flow_node_type: "user_task",
        state: "waiting"
      })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_flow_node_instances()
      assert count == 0

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      assert Enum.all?(flow_node_instances, &(&1.state in ["active", "waiting"]))
      assert Enum.all?(flow_node_instances, &is_nil(&1.error_info))
    end

    test "does not touch already-terminal FNIs" do
      process_instance_id = insert_process_instance(%{state: "fatal", finished_at: DateTime.utc_now()})

      insert_flow_node_instance(%{
        process_instance_id: process_instance_id,
        state: "finished",
        finished_at: DateTime.utc_now()
      })

      insert_flow_node_instance(%{
        process_instance_id: process_instance_id,
        state: "fatal",
        finished_at: DateTime.utc_now()
      })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_flow_node_instances()
      assert count == 0
    end

    test "handles multiple orphaned FNIs across multiple PIs" do
      pi1 = insert_process_instance(%{state: "fatal", finished_at: DateTime.utc_now()})
      pi2 = insert_process_instance(%{state: "aborted", finished_at: DateTime.utc_now()})

      insert_flow_node_instance(%{process_instance_id: pi1, state: "active"})
      insert_flow_node_instance(%{process_instance_id: pi1, state: "waiting", flow_node_type: "user_task"})
      insert_flow_node_instance(%{process_instance_id: pi2, state: "active"})

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_flow_node_instances()
      assert count == 3
    end
  end

  # -------------------------------------------------------------------
  # Orphaned PI tests
  # -------------------------------------------------------------------

  describe "cleanup_orphaned_process_instances/0" do
    test "aborts a running child PI whose parent is terminal (1 level)" do
      parent_id = insert_process_instance(%{state: "fatal", finished_at: DateTime.utc_now()})

      child_id =
        insert_process_instance(%{
          state: "running",
          parent_process_instance_id: parent_id
        })

      child_fni_id =
        insert_flow_node_instance(%{
          process_instance_id: child_id,
          state: "active"
        })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_process_instances()
      assert count == 1

      child_pi = fetch_process_instance!(child_id)
      assert child_pi.state == "aborted"
      assert child_pi.finished_at != nil
      assert child_pi.error_info["error_code"] == "orphaned_pi_cleanup"
      assert child_pi.error_info["message"] =~ "engine startup"

      child_fni = fetch_flow_node_instances(child_id) |> Enum.find(&(&1.id == child_fni_id))
      assert child_fni.state == "aborted"
      assert child_fni.error_info["error_code"] == "orphaned_fni_cleanup"
      assert child_fni.error_info["message"] =~ "engine startup"
    end

    test "aborts nested orphans (2 levels: grandparent terminal → parent running → child running)" do
      grandparent_id = insert_process_instance(%{state: "aborted", finished_at: DateTime.utc_now()})

      parent_id =
        insert_process_instance(%{
          state: "running",
          parent_process_instance_id: grandparent_id
        })

      child_id =
        insert_process_instance(%{
          state: "running",
          parent_process_instance_id: parent_id
        })

      insert_flow_node_instance(%{process_instance_id: parent_id, state: "active"})
      insert_flow_node_instance(%{process_instance_id: child_id, state: "waiting", flow_node_type: "user_task"})

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_process_instances()
      assert count == 2

      parent_pi = fetch_process_instance!(parent_id)
      assert parent_pi.state == "aborted"
      assert parent_pi.error_info["error_code"] == "orphaned_pi_cleanup"

      child_pi = fetch_process_instance!(child_id)
      assert child_pi.state == "aborted"
      assert child_pi.error_info["error_code"] == "orphaned_pi_cleanup"

      assert_no_running_fnis!(parent_id)
      assert_no_running_fnis!(child_id)
    end

    test "does not touch a finished child PI" do
      parent_id = insert_process_instance(%{state: "fatal", finished_at: DateTime.utc_now()})

      child_id =
        insert_process_instance(%{
          state: "finished",
          finished_at: DateTime.utc_now(),
          parent_process_instance_id: parent_id
        })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_process_instances()
      assert count == 0

      child_pi = fetch_process_instance!(child_id)
      assert child_pi.state == "finished"
      assert is_nil(child_pi.error_info)
    end

    test "does not touch a running root PI (no parent)" do
      root_id = insert_process_instance(%{state: "running"})
      insert_flow_node_instance(%{process_instance_id: root_id, state: "active"})

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_process_instances()
      assert count == 0

      root_pi = fetch_process_instance!(root_id)
      assert root_pi.state == "running"
      assert is_nil(root_pi.error_info)
    end

    test "does not touch a running child PI whose parent is still running" do
      parent_id = insert_process_instance(%{state: "running"})

      child_id =
        insert_process_instance(%{
          state: "running",
          parent_process_instance_id: parent_id
        })

      {:ok, count} = ExecutionAdapter.cleanup_orphaned_process_instances()
      assert count == 0

      child_pi = fetch_process_instance!(child_id)
      assert child_pi.state == "running"
    end
  end

  # -------------------------------------------------------------------
  # Combined cleanup (via ResumeRunner path)
  # -------------------------------------------------------------------

  describe "full cleanup sweep via ResumeRunner" do
    test "cleans up both orphaned FNIs and orphaned PIs in correct order" do
      parent_id = insert_process_instance(%{state: "fatal", finished_at: DateTime.utc_now()})

      orphaned_fni_on_parent =
        insert_flow_node_instance(%{
          process_instance_id: parent_id,
          state: "active"
        })

      child_id =
        insert_process_instance(%{
          state: "running",
          parent_process_instance_id: parent_id
        })

      orphaned_fni_on_child =
        insert_flow_node_instance(%{
          process_instance_id: child_id,
          state: "waiting",
          flow_node_type: "user_task"
        })

      {:ok, fni_count} = ExecutionAdapter.cleanup_orphaned_flow_node_instances()
      assert fni_count == 1

      parent_fni = fetch_flow_node_instances(parent_id) |> Enum.find(&(&1.id == orphaned_fni_on_parent))
      assert parent_fni.state == "aborted"

      {:ok, pi_count} = ExecutionAdapter.cleanup_orphaned_process_instances()
      assert pi_count == 1

      child_pi = fetch_process_instance!(child_id)
      assert child_pi.state == "aborted"
      assert child_pi.error_info["error_code"] == "orphaned_pi_cleanup"

      child_fni = fetch_flow_node_instances(child_id) |> Enum.find(&(&1.id == orphaned_fni_on_child))
      assert child_fni.state == "aborted"
      assert child_fni.error_info["error_code"] == "orphaned_fni_cleanup"
    end
  end
end
