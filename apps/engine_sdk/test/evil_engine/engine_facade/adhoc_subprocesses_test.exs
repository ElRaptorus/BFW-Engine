defmodule EvilEngine.EngineFacade.AdhocSubprocessesTest do
  use ExUnit.Case, async: true

  alias EvilEngine.EngineFacade.AdhocSubprocesses

  describe "default struct" do
    test "all closures default to noop functions returning {:error, :not_wired}" do
      facade = %AdhocSubprocesses{}

      assert {:error, :not_wired} = facade.get_enabled_activities.("pi-1")
      assert {:error, :not_wired} = facade.activate_activity.("pi-1", "Task_1")
      assert {:error, :not_wired} = facade.complete.("pi-1")
      assert {:error, :not_wired} = facade.get_status.("pi-1")
    end
  end

  describe "wired closures" do
    test "get_enabled_activities can be wired to a custom function" do
      facade = %AdhocSubprocesses{
        get_enabled_activities: fn _process_instance_id ->
          {:ok, [%{id: "Task_1", name: "My Task", enabled: true}]}
        end
      }

      assert {:ok, [%{id: "Task_1"}]} = facade.get_enabled_activities.("pi-1")
    end

    test "activate_activity can be wired to a custom function" do
      facade = %AdhocSubprocesses{
        activate_activity: fn _process_instance_id, flow_node_id ->
          {:ok, %{flow_node_instance_id: "fni-#{flow_node_id}"}}
        end
      }

      assert {:ok, %{flow_node_instance_id: "fni-Task_1"}} =
               facade.activate_activity.("pi-1", "Task_1")
    end

    test "complete can be wired to a custom function" do
      facade = %AdhocSubprocesses{
        complete: fn _process_instance_id -> :ok end
      }

      assert :ok = facade.complete.("pi-1")
    end

    test "get_status can be wired to a custom function" do
      facade = %AdhocSubprocesses{
        get_status: fn _process_instance_id ->
          {:ok, %{active_count: 2, completion_signaled: false}}
        end
      }

      assert {:ok, %{active_count: 2}} = facade.get_status.("pi-1")
    end
  end
end
