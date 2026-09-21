defmodule Examples.BusinessRules.DecisionTracePublisher.AuditMessageBuilderTest do
  use ExUnit.Case, async: true

  alias BfwEngine.Types.Event
  alias Examples.BusinessRules.DecisionTracePublisher.AuditMessageBuilder

  defp dmn_brt_finished_event(overrides \\ %{}) do
    type_properties =
      Map.get(overrides, :type_properties) ||
        %{
          "mode" => "dmn",
          "decision_ref" => "order-risk-rules",
          "decision_version_id" => "version-uuid-1",
          "hit_policy" => "UNIQUE",
          "matched_rules" => ["Rule_high_risk"],
          "duration_us" => 42_000,
          "trace" => %{"decisions" => [%{"decisionModelId" => "Decision_Risk_Level"}]}
        }

    struct_fields =
      %{
        flow_node_instance_id: "flow-node-instance-1",
        process_instance_id: "process-instance-1",
        flow_node_id: "BRT_assess_order_risk",
        flow_node_type: :business_rule_task,
        event_type: nil,
        terminal_state: :finished,
        occurred_at: ~U[2026-05-20T12:00:00Z]
      }
      |> Map.merge(Map.drop(overrides, [:type_properties]))

    struct(Event.FlowNodeInstanceFinished, struct_fields)
    |> Map.put(:type_properties, type_properties)
  end

  test "build/1 extracts all fields from event and type_properties" do
    event = dmn_brt_finished_event()

    audit_message = AuditMessageBuilder.build(event)

    assert audit_message.event_type == "dmn_decision_executed"
    assert %DateTime{} = audit_message.timestamp
    assert audit_message.process_instance_id == "process-instance-1"
    assert audit_message.flow_node_id == "BRT_assess_order_risk"
    assert audit_message.decision_ref == "order-risk-rules"
    assert audit_message.decision_version_id == "version-uuid-1"
    assert audit_message.hit_policy == "UNIQUE"
    assert audit_message.matched_rules == ["Rule_high_risk"]
    assert audit_message.duration_us == 42_000
    assert audit_message.trace == %{"decisions" => [%{"decisionModelId" => "Decision_Risk_Level"}]}
  end

  test "build/1 handles missing trace gracefully" do
    event =
      dmn_brt_finished_event(%{
        type_properties: %{
          "mode" => "dmn",
          "decision_ref" => "order-risk-rules",
          "trace" => nil
        }
      })

    audit_message = AuditMessageBuilder.build(event)
    assert audit_message.trace == %{}
  end

  test "build/1 handles missing type_properties gracefully" do
    event =
      struct(Event.FlowNodeInstanceFinished, %{
        flow_node_instance_id: "flow-node-instance-2",
        process_instance_id: "process-instance-2",
        flow_node_id: "BRT_assess_order_risk",
        flow_node_type: :business_rule_task,
        event_type: nil,
        terminal_state: :finished,
        occurred_at: ~U[2026-05-20T12:00:00Z]
      })

    audit_message = AuditMessageBuilder.build(event)

    assert audit_message.decision_ref == nil
    assert audit_message.decision_version_id == nil
    assert audit_message.hit_policy == nil
    assert audit_message.matched_rules == nil
    assert audit_message.duration_us == nil
    assert audit_message.trace == %{}
  end

  test "build/1 supports atom-keyed type_properties" do
    event =
      dmn_brt_finished_event(%{
        type_properties: %{
          mode: "dmn",
          decision_ref: "order-risk-rules",
          trace: %{decisions: []}
        }
      })

    audit_message = AuditMessageBuilder.build(event)
    assert audit_message.decision_ref == "order-risk-rules"
    assert audit_message.trace == %{decisions: []}
  end
end
