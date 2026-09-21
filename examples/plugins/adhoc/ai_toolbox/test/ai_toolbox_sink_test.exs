defmodule Examples.Plugins.Adhoc.AiToolbox.AiToolboxSinkTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Types.Event
  alias Examples.Plugins.Adhoc.AiToolbox.AiToolboxSink

  defp activity(id, enabled), do: %{id: id, name: id, type: "task", enabled: enabled, performed_count: 0, active_count: 0}

  defp facade_stub(responses) do
    %{
      adhoc_subprocesses: %{
        get_enabled_activities: fn _child_pi_id -> {:ok, Keyword.fetch!(responses, :activities)} end,
        activate_activity: fn _child_pi_id, tool_id ->
          send(self(), {:activated, tool_id})
          {:ok, %{flow_node_instance_id: "fni-#{tool_id}"}}
        end,
        complete: fn _child_pi_id ->
          send(self(), :completed)
          :ok
        end,
        get_status: fn _child_pi_id -> {:ok, %{}} end
      }
    }
  end

  test "choose_next_tool/2 picks the highest-priority enabled tool not yet performed" do
    activities = [activity("SendEmail", true), activity("LookupOrder", true), activity("CheckInventory", true)]

    assert AiToolboxSink.choose_next_tool(activities, []) == "LookupOrder"
    assert AiToolboxSink.choose_next_tool(activities, ["LookupOrder"]) == "CheckInventory"
  end

  test "choose_next_tool/2 skips disabled activities" do
    activities = [activity("LookupOrder", false), activity("CheckInventory", true)]

    assert AiToolboxSink.choose_next_tool(activities, []) == "CheckInventory"
  end

  test "choose_next_tool/2 returns nil when every priority tool is disabled or performed" do
    activities = [activity("LookupOrder", true)]

    assert AiToolboxSink.choose_next_tool(activities, ["LookupOrder"]) == nil
  end

  test "handle_event/2 activates the first enabled tool when an ad-hoc scope starts" do
    facade =
      facade_stub(
        activities: [activity("LookupOrder", true), activity("CheckInventory", true)]
      )

    {:ok, state} = AiToolboxSink.init(facade: facade)

    event = %Event.SubProcessChildStarted{
      subprocess_flow_node_instance_id: "fni-shell",
      parent_process_instance_id: "pi-parent",
      child_process_instance_id: "pi-child-1",
      subprocess_node_id: "AdHocSubprocess_Toolbox",
      child_process_model_id: "order-process__subprocess__AdHocSubprocess_Toolbox",
      child_version: "1.0.0",
      is_event_subprocess: false,
      is_ad_hoc_subprocess: true,
      occurred_at: DateTime.utc_now()
    }

    {:ok, updated_state} = AiToolboxSink.handle_event(event, state)

    assert_received {:activated, "LookupOrder"}
    assert Map.has_key?(updated_state.scopes, "pi-child-1")
  end

  test "handle_event/2 completes the scope once EscalateToHuman finishes" do
    facade = facade_stub(activities: [])
    {:ok, state} = AiToolboxSink.init(facade: facade)
    state = %{state | scopes: %{"pi-child-1" => ["LookupOrder"]}}

    event = %Event.FlowNodeInstanceFinished{
      flow_node_instance_id: "fni-escalate",
      process_instance_id: "pi-child-1",
      root_process_instance_id: "pi-root",
      flow_node_id: "EscalateToHuman",
      flow_node_type: :task,
      event_type: nil,
      lane_name: nil,
      terminal_state: :finished,
      triggerer_flow_node_instance_id: nil,
      multi_instance_id: nil,
      iteration_index: nil,
      type_properties: %{},
      error_info: nil,
      occurred_at: DateTime.utc_now()
    }

    {:ok, _updated_state} = AiToolboxSink.handle_event(event, state)

    assert_received :completed
  end

  test "handle_event/2 forgets the scope once AdHocSubProcessCompleted arrives" do
    facade = facade_stub(activities: [])
    {:ok, state} = AiToolboxSink.init(facade: facade)
    state = %{state | scopes: %{"pi-child-1" => ["LookupOrder"]}}

    event = %Event.AdHocSubProcessCompleted{
      process_instance_id: "pi-child-1",
      root_process_instance_id: "pi-root",
      adhoc_flow_node_instance_id: "fni-shell",
      adhoc_node_id: "AdHocSubprocess_Toolbox",
      completion_reason: :completed,
      total_activations: 1,
      occurred_at: DateTime.utc_now()
    }

    {:ok, updated_state} = AiToolboxSink.handle_event(event, state)

    refute Map.has_key?(updated_state.scopes, "pi-child-1")
  end
end
