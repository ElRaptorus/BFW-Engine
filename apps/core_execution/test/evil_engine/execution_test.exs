defmodule EvilEngine.ExecutionTest do
  use ExUnit.Case, async: true

  test "supervision tree started" do
    assert Process.whereis(EvilEngine.Execution.ApplicationSupervisor)
  end

  test "DynamicSupervisor started" do
    assert Process.whereis(EvilEngine.Execution.Supervisor)
  end

  test "Registry started" do
    assert Process.whereis(EvilEngine.Execution.Registry)
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
               EvilEngine.Execution.start_process_instance(opts)
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
               EvilEngine.Execution.start_process_instance(opts)
    end
  end
end
