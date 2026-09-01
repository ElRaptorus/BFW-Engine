defmodule Examples.BusinessRules.DecisionAuditReporter.EventTrackerTest do
  use ExUnit.Case, async: true

  alias Examples.BusinessRules.DecisionAuditReporter.EventTracker

  setup do
    tracker_name = :"event_tracker_test_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = EventTracker.start_link(name: tracker_name)
    {:ok, tracker_name: tracker_name}
  end

  defp tracked_event(flow_node_instance_id) do
    %{
      flow_node_instance_id: flow_node_instance_id,
      process_instance_id: "process-instance-1",
      flow_node_id: "BRT_1"
    }
  end

  test "records FNI finished events", %{tracker_name: tracker_name} do
    :ok = EventTracker.track(tracked_event("fni-1"), name: tracker_name)

    assert EventTracker.get_count(name: tracker_name) == 1
    assert EventTracker.get_tracked_flow_node_instance_ids(name: tracker_name) == ["fni-1"]
    assert hd(EventTracker.get_events(name: tracker_name)).flow_node_instance_id == "fni-1"
  end

  test "get_count and get_tracked_flow_node_instance_ids work correctly", %{
    tracker_name: tracker_name
  } do
    :ok = EventTracker.track(tracked_event("fni-a"), name: tracker_name)
    :ok = EventTracker.track(tracked_event("fni-b"), name: tracker_name)

    assert EventTracker.get_count(name: tracker_name) == 2
    assert EventTracker.get_tracked_flow_node_instance_ids(name: tracker_name) == ["fni-a", "fni-b"]
  end

  test "reset clears state", %{tracker_name: tracker_name} do
    :ok = EventTracker.track(tracked_event("fni-1"), name: tracker_name)
    :ok = EventTracker.reset(name: tracker_name)

    assert EventTracker.get_count(name: tracker_name) == 0
    assert EventTracker.get_tracked_flow_node_instance_ids(name: tracker_name) == []
    assert EventTracker.get_events(name: tracker_name) == []
  end
end
