defmodule BfwEngine.ExecutionTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(BfwEngine.Execution.ApplicationSupervisor)
  end

  test "DynamicSupervisor started" do
    assert Process.whereis(BfwEngine.Execution.Supervisor)
  end

  test "Registry started" do
    assert Process.whereis(BfwEngine.Execution.Registry)
  end

  # Subprocess start isolation invariant. These calls are rejected by the guard
  # before the supervisor or the database is ever touched, so no DB is required.
  # This is the authoritative guard every entry point (REST, plugin facade, Call
  # Activity, SubProcess) flows through.
  describe "start_process_instance/1 — subprocess start isolation" do
    test "rejects a subprocess_node_id without a parent process instance" do
      opts = %{
        process_instance_id: "pi-orphan-1",
        process_version_id: "pv-1",
        payload: %{},
        identity: nil,
        subprocess_node_id: "SubProcess_1"
      }

      assert {:error, :orphan_subprocess_start} =
               BfwEngine.Execution.start_process_instance(opts)
    end

    test "rejects when parent is explicitly nil even with other internal opts set" do
      opts = %{
        process_instance_id: "pi-orphan-2",
        process_version_id: "pv-2",
        payload: %{},
        identity: nil,
        subprocess_node_id: "SubProcess_1",
        parent_process_instance_id: nil,
        triggerer_flow_node_instance_id: "fni-1"
      }

      assert {:error, :orphan_subprocess_start} =
               BfwEngine.Execution.start_process_instance(opts)
    end
  end

  describe "ad-hoc subprocess operations — lookup failures" do
    test "activate_adhoc_activity returns :not_found for unregistered PI" do
      assert {:error, :not_found} =
               BfwEngine.Execution.activate_adhoc_activity(
                 "nonexistent-pi-id",
                 "Task_1"
               )
    end

    test "signal_adhoc_completion returns :not_found for unregistered PI" do
      assert {:error, :not_found} =
               BfwEngine.Execution.signal_adhoc_completion("nonexistent-pi-id")
    end

    test "get_adhoc_enabled_activities returns :not_found for unregistered PI" do
      assert {:error, :not_found} =
               BfwEngine.Execution.get_adhoc_enabled_activities("nonexistent-pi-id")
    end

    test "get_adhoc_status returns :not_found for unregistered PI" do
      assert {:error, :not_found} =
               BfwEngine.Execution.get_adhoc_status("nonexistent-pi-id")
    end
  end
end
