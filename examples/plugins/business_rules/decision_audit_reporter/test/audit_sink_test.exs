defmodule Examples.BusinessRules.DecisionAuditReporter.AuditSinkTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Types.Event
  alias Examples.BusinessRules.DecisionAuditReporter.AuditSink
  alias Examples.BusinessRules.DecisionAuditReporter.EventTracker

  setup do
    tracker_name = :"audit_sink_test_#{:erlang.unique_integer([:positive])}"
    {:ok, sink_state} = AuditSink.init(tracker_name: tracker_name)

    on_exit(fn ->
      case Process.whereis(tracker_name) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid), do: Agent.stop(pid)
      end
    end)

    {:ok, sink_state: sink_state, tracker_name: tracker_name}
  end

  defp dmn_brt_finished_event(overrides \\ %{}) do
    type_properties =
      Map.get(overrides, :type_properties) ||
        %{"mode" => "dmn", "decision_ref" => "employee-benefits"}

    struct_fields =
      %{
        flow_node_instance_id: "fni-1",
        process_instance_id: "process-instance-1",
        flow_node_id: "BRT_determine_benefits",
        flow_node_type: :business_rule_task,
        event_type: nil,
        terminal_state: :finished,
        occurred_at: ~U[2026-05-20T12:00:00Z]
      }
      |> Map.merge(Map.drop(overrides, [:type_properties]))

    struct(Event.FlowNodeInstanceFinished, struct_fields)
    |> Map.put(:type_properties, type_properties)
  end

  test "accepts?/1 returns true for BRT DMN finished events" do
    assert AuditSink.accepts?(dmn_brt_finished_event())
  end

  test "accepts?/1 ignores non-BRT and non-DMN events" do
    refute AuditSink.accepts?(
             dmn_brt_finished_event(%{
               flow_node_type: :service_task,
               type_properties: %{"mode" => "dmn"}
             })
           )

    refute AuditSink.accepts?(
             dmn_brt_finished_event(%{type_properties: %{"mode" => "feel"}})
           )
  end

  test "handle_event/2 tracks the flow node instance id", %{
    sink_state: sink_state,
    tracker_name: tracker_name
  } do
    assert {:ok, ^sink_state} = AuditSink.handle_event(dmn_brt_finished_event(), sink_state)

    assert EventTracker.get_tracked_flow_node_instance_ids(name: tracker_name) == ["fni-1"]
  end
end
