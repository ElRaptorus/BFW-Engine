defmodule EvilEngine.Events.JsonEncodersTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Types.Event
  alias EvilEngine.Types.{FinalToken, Identity, Token}

  @now DateTime.utc_now()

  describe "event struct encoding" do
    test "EngineStarted produces camelCase keys" do
      event = %Event.EngineStarted{
        engine_id: "eng-1",
        engine_name: "test",
        version: "0.1.0",
        started_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["engineId"] == "eng-1"
      assert decoded["engineName"] == "test"
      assert decoded["startedAt"]
      refute Map.has_key?(decoded, "engine_id")
    end

    test "ProcessInstanceStateChanged produces camelCase keys" do
      event = %Event.ProcessInstanceStateChanged{
        process_instance_id: "pi-1",
        process_model_id: "my-process",
        version: "1.0.0",
        old_state: "running",
        new_state: "finished",
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["processInstanceId"] == "pi-1"
      assert decoded["processModelId"] == "my-process"
      assert decoded["version"] == "1.0.0"
      assert decoded["oldState"] == "running"
      assert decoded["newState"] == "finished"
      assert decoded["hasLanelessFlowNode"] == false
      assert decoded["laneNames"] == []
      refute Map.has_key?(decoded, "process_instance_id")
    end

    test "FlowNodeInstanceStarted produces camelCase keys" do
      event = %Event.FlowNodeInstanceStarted{
        process_instance_id: "pi-1",
        flow_node_instance_id: "fni-1",
        flow_node_id: "task-1",
        flow_node_type: :user_task,
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["processInstanceId"] == "pi-1"
      assert decoded["flowNodeInstanceId"] == "fni-1"
      assert decoded["flowNodeId"] == "task-1"
      assert decoded["flowNodeType"] == "user_task"
      assert decoded["laneName"] == nil
    end

    test "FNI-originating events encode laneName" do
      for module <- [
            Event.FlowNodeInstanceStarted,
            Event.FlowNodeInstanceFinished,
            Event.FlowNodeInstanceStateChanged,
            Event.MultiInstanceStarted,
            Event.MultiInstanceCompleted,
            Event.UserTaskCreated,
            Event.UserTaskFinished,
            Event.UserTaskValidationFailed,
            Event.PluginAsyncFlowNodeRehydrated,
            Event.CallActivityChildStarted,
            Event.SubProcessChildStarted,
            Event.EventSubprocessTriggered,
            Event.DataObjectWritten,
            Event.TimerFired,
            Event.MessageArrived,
            Event.SignalArrived,
            Event.EscalationRaised,
            Event.CompensationTriggered,
            Event.ActivityCompensated,
            Event.TransactionCancelled,
            Event.AdHocActivityActivated,
            Event.AdHocSubProcessCompleted
          ] do
        decoded =
          module
          |> struct(lane_name: "Management")
          |> encode_and_decode()

        assert decoded["laneName"] == "Management",
               "#{inspect(module)} must encode lane_name as laneName"
      end
    end

    test "SinkFailed produces camelCase keys" do
      event = %Event.SinkFailed{
        sink_name: "test-sink",
        event_kind: :engine_started,
        reason: "timeout",
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["sinkName"] == "test-sink"
      assert decoded["eventKind"] == "engine_started"
      assert decoded["reason"] == "timeout"
      refute Map.has_key?(decoded, "sink_name")
    end

    test "EngineOverloaded produces camelCase keys" do
      event = %Event.EngineOverloaded{
        level: :critical,
        active_process_instances: 95,
        limit: 100,
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["level"] == "critical"
      assert decoded["activeProcessInstances"] == 95
      assert decoded["limit"] == 100
      refute Map.has_key?(decoded, "active_process_instances")
    end

    test "EngineRecovered produces camelCase keys" do
      event = %Event.EngineRecovered{
        previous_level: :elevated,
        active_process_instances: 60,
        limit: 100,
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["previousLevel"] == "elevated"
      assert decoded["activeProcessInstances"] == 60
      assert decoded["limit"] == 100
      refute Map.has_key?(decoded, "previous_level")
    end

    test "DecisionDefinitionDeployed produces camelCase keys" do
      event = %Event.DecisionDefinitionDeployed{
        decision_definition_id: "risk-rules",
        version: "a1b2c3d4e5f6",
        source: "user:test-user",
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["decisionDefinitionId"] == "risk-rules"
      assert decoded["version"] == "a1b2c3d4e5f6"
      assert decoded["source"] == "user:test-user"
      refute Map.has_key?(decoded, "decision_definition_id")
    end

    test "DecisionDefinitionUndeployed produces camelCase keys" do
      event = %Event.DecisionDefinitionUndeployed{
        decision_definition_id: "risk-rules",
        version: "a1b2c3d4e5f6",
        source: "plugin:my-plugin",
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["decisionDefinitionId"] == "risk-rules"
      assert decoded["version"] == "a1b2c3d4e5f6"
      assert decoded["source"] == "plugin:my-plugin"
      refute Map.has_key?(decoded, "decision_definition_id")
    end

    test "DecisionEvaluated produces camelCase keys" do
      event = %Event.DecisionEvaluated{
        decision_definition_id: "risk-rules",
        decision_model_id: "Decision_1",
        version: "a1b2c3d4e5f6",
        decision_version_id: "uuid-123",
        duration_microseconds: 1234,
        source: "user:test-user",
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["decisionDefinitionId"] == "risk-rules"
      assert decoded["decisionModelId"] == "Decision_1"
      assert decoded["version"] == "a1b2c3d4e5f6"
      assert decoded["decisionVersionId"] == "uuid-123"
      assert decoded["durationMicroseconds"] == 1234
      assert decoded["source"] == "user:test-user"
      refute Map.has_key?(decoded, "decision_definition_id")
      refute Map.has_key?(decoded, "duration_microseconds")
    end

    test "UserTaskValidationFailed preserves opaque violations" do
      event = %Event.UserTaskValidationFailed{
        process_instance_id: "pi-1",
        flow_node_instance_id: "fni-1",
        flow_node_id: "ut-1",
        violations: [%{"path" => "$.amount", "message" => "required"}],
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["processInstanceId"] == "pi-1"
      assert decoded["violations"] == [%{"path" => "$.amount", "message" => "required"}]
    end

    test "AdHocActivityActivated produces camelCase keys" do
      event = %Event.AdHocActivityActivated{
        process_instance_id: "pi-1",
        root_process_instance_id: "root-pi-1",
        adhoc_flow_node_instance_id: "fni-adhoc",
        activated_flow_node_id: "Task_1",
        activated_flow_node_instance_id: "fni-task-1",
        activation_source: "engine",
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["processInstanceId"] == "pi-1"
      assert decoded["rootProcessInstanceId"] == "root-pi-1"
      assert decoded["adhocFlowNodeInstanceId"] == "fni-adhoc"
      assert decoded["activatedFlowNodeId"] == "Task_1"
      assert decoded["activatedFlowNodeInstanceId"] == "fni-task-1"
      assert decoded["activationSource"] == "engine"
      assert decoded["laneName"] == nil
      refute Map.has_key?(decoded, "process_instance_id")
      refute Map.has_key?(decoded, "adhoc_flow_node_instance_id")
    end

    test "AdHocSubProcessCompleted produces camelCase keys" do
      event = %Event.AdHocSubProcessCompleted{
        process_instance_id: "pi-1",
        root_process_instance_id: "root-pi-1",
        adhoc_flow_node_instance_id: "fni-adhoc",
        adhoc_node_id: "AdHoc_1",
        completion_reason: :all_done,
        total_activations: 5,
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["processInstanceId"] == "pi-1"
      assert decoded["adhocFlowNodeInstanceId"] == "fni-adhoc"
      assert decoded["adhocNodeId"] == "AdHoc_1"
      assert decoded["completionReason"] == "all_done"
      assert decoded["totalActivations"] == 5
      assert decoded["laneName"] == nil
      refute Map.has_key?(decoded, "adhoc_node_id")
    end

    test "SubProcessChildStarted with is_ad_hoc_subprocess produces camelCase" do
      event = %Event.SubProcessChildStarted{
        subprocess_flow_node_instance_id: "fni-1",
        parent_process_instance_id: "pi-parent",
        child_process_instance_id: "pi-child",
        subprocess_node_id: "AdHoc_1",
        child_process_model_id: "model__subprocess__AdHoc_1",
        child_version: "1.0.0",
        is_event_subprocess: false,
        is_ad_hoc_subprocess: true,
        occurred_at: @now
      }

      decoded = encode_and_decode(event)

      assert decoded["isAdHocSubprocess"] == true
      assert decoded["isEventSubprocess"] == false
      refute Map.has_key?(decoded, "is_ad_hoc_subprocess")
    end
  end

  describe "Token encoding" do
    test "produces camelCase keys and preserves opaque payload" do
      token = %Token{
        id: "tok-1",
        process_instance_id: "pi-1",
        originating_flow_node_instance_id: "fni-1",
        payload: %{"order_total" => 99.99, "nested" => %{"deep_key" => true}}
      }

      decoded = encode_and_decode(token)

      assert decoded["id"] == "tok-1"
      assert decoded["processInstanceId"] == "pi-1"
      assert decoded["originatingFlowNodeInstanceId"] == "fni-1"

      assert decoded["payload"] == %{
               "order_total" => 99.99,
               "nested" => %{"deep_key" => true}
             }
    end
  end

  describe "FinalToken encoding" do
    test "produces camelCase keys and preserves opaque payload" do
      final = %FinalToken{
        end_event_id: "end-1",
        end_event_name: "Success",
        payload: %{"final_data" => true}
      }

      decoded = encode_and_decode(final)

      assert decoded["endEventId"] == "end-1"
      assert decoded["endEventName"] == "Success"
      assert decoded["payload"] == %{"final_data" => true}
    end
  end

  describe "Identity encoding" do
    test "produces camelCase keys and preserves opaque claims" do
      identity = %Identity{
        id: "user-1",
        roles: ["admin"],
        groups: ["eng"],
        claims: %{"custom_claim" => true, "org_id" => "org-42"}
      }

      decoded = encode_and_decode(identity)

      assert decoded["id"] == "user-1"
      assert decoded["roles"] == ["admin"]
      assert decoded["claims"] == %{"custom_claim" => true, "org_id" => "org-42"}
    end
  end

  defp encode_and_decode(struct) do
    struct |> Jason.encode!() |> Jason.decode!()
  end
end
