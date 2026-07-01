defmodule EvilEngine.Types.EventTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Types.Event

  describe "SinkFailed" do
    test "builds with all required keys" do
      now = DateTime.utc_now()

      event = %Event.SinkFailed{
        sink_name: "console",
        event_kind: Event.EngineStarted,
        reason: "connection reset",
        occurred_at: now
      }

      assert event.sink_name == "console"
      assert event.event_kind == Event.EngineStarted
      assert event.reason == "connection reset"
      assert event.occurred_at == now
    end

    test "raises when required key is missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.SinkFailed, %{sink_name: "x"})
      end
    end
  end

  describe "EngineStarted" do
    test "builds with required keys, optional fields default to nil" do
      now = DateTime.utc_now()

      event = %Event.EngineStarted{
        engine_id: "engine-1",
        started_at: now
      }

      assert event.engine_id == "engine-1"
      assert event.started_at == now
      assert event.engine_name == nil
      assert event.version == nil
    end

    test "raises when :engine_id missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.EngineStarted, %{started_at: DateTime.utc_now()})
      end
    end

    test "raises when :started_at missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.EngineStarted, %{engine_id: "e1"})
      end
    end
  end

  describe "EngineShutdown" do
    test "builds with all required keys" do
      now = DateTime.utc_now()

      event = %Event.EngineShutdown{
        engine_id: "engine-1",
        reason: :normal,
        occurred_at: now
      }

      assert event.engine_id == "engine-1"
      assert event.reason == :normal
      assert event.occurred_at == now
    end

    test "raises when required keys missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.EngineShutdown, %{engine_id: "e1"})
      end
    end
  end

  describe "PluginAsyncFlowNodeRehydrated" do
    test "builds with required keys and optional plugin_name" do
      now = DateTime.utc_now()

      event = %Event.PluginAsyncFlowNodeRehydrated{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        plugin_name: "my-plugin",
        occurred_at: now
      }

      assert event.flow_node_instance_id == "fni-1"
      assert event.process_instance_id == "pi-1"
      assert event.plugin_name == "my-plugin"
      assert event.occurred_at == now
    end

    test "allows plugin_name to be omitted (nil)" do
      now = DateTime.utc_now()

      event = %Event.PluginAsyncFlowNodeRehydrated{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        occurred_at: now
      }

      assert event.plugin_name == nil
    end

    test "raises when a required key is missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.PluginAsyncFlowNodeRehydrated, %{
          flow_node_instance_id: "fni-1",
          process_instance_id: "pi-1"
        })
      end
    end
  end

  describe "PluginQuarantined" do
    test "builds with all required keys" do
      now = DateTime.utc_now()

      event = %Event.PluginQuarantined{
        plugin_name: "my-plugin",
        tier: :inbeam,
        reason: "on_load failed",
        occurred_at: now
      }

      assert event.plugin_name == "my-plugin"
      assert event.tier == :inbeam
      assert event.reason == "on_load failed"
      assert event.occurred_at == now
    end

    test "raises when :tier missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.PluginQuarantined, %{
          plugin_name: "p",
          reason: "x",
          occurred_at: DateTime.utc_now()
        })
      end
    end

    test "new/1 preserves binary reason strings" do
      now = DateTime.utc_now()

      event =
        Event.PluginQuarantined.new(%{
          plugin_name: "my-plugin",
          tier: :inbeam,
          reason: "on_load failed",
          occurred_at: now
        })

      assert event.reason == "on_load failed"
    end

    test "new/1 replaces non-binary reasons with a generic message" do
      now = DateTime.utc_now()

      event =
        Event.PluginQuarantined.new(%{
          plugin_name: "evil:broken",
          tier: :inbeam,
          reason: :app_not_loaded,
          occurred_at: now
        })

      assert event.reason == "Plugin 'evil:broken' was quarantined"
    end

    test "new/1 replaces tuple reasons with a generic message" do
      now = DateTime.utc_now()

      event =
        Event.PluginQuarantined.new(%{
          plugin_name: "evil:broken",
          tier: :sidecar,
          reason: {:error, :timeout},
          occurred_at: now
        })

      assert event.reason == "Plugin 'evil:broken' was quarantined"
    end
  end

  describe "ProcessInstanceStateChanged" do
    test "builds with all required keys and optional transition metadata" do
      now = DateTime.utc_now()

      event = %Event.ProcessInstanceStateChanged{
        process_instance_id: "pi-1",
        process_model_id: "order-process",
        version: "1.0.0",
        parent_process_instance_id: "parent-pi",
        old_state: :running,
        new_state: :finished,
        occurred_at: now
      }

      assert event.process_instance_id == "pi-1"
      assert event.process_model_id == "order-process"
      assert event.version == "1.0.0"
      assert event.parent_process_instance_id == "parent-pi"
      assert event.old_state == :running
      assert event.new_state == :finished
      assert event.occurred_at == now
    end

    test "allows optional parent and old_state to be omitted" do
      now = DateTime.utc_now()

      event = %Event.ProcessInstanceStateChanged{
        process_instance_id: "pi-1",
        process_model_id: "order-process",
        version: "1.0.0",
        new_state: :running,
        occurred_at: now
      }

      assert event.parent_process_instance_id == nil
      assert event.old_state == nil
    end

    test "raises when :new_state missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.ProcessInstanceStateChanged, %{
          process_instance_id: "pi-1",
          process_model_id: "order-process",
          version: "1.0.0",
          occurred_at: DateTime.utc_now()
        })
      end
    end
  end

  describe "FlowNodeInstanceStarted" do
    test "builds with all required keys and optional event metadata" do
      now = DateTime.utc_now()

      event = %Event.FlowNodeInstanceStarted{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        flow_node_id: "Catch_payment",
        flow_node_type: :intermediate_catch_event,
        event_type: "message",
        lane_name: "default",
        occurred_at: now
      }

      assert event.flow_node_instance_id == "fni-1"
      assert event.process_instance_id == "pi-1"
      assert event.flow_node_id == "Catch_payment"
      assert event.flow_node_type == :intermediate_catch_event
      assert event.event_type == "message"
      assert event.lane_name == "default"
      assert event.occurred_at == now
    end

    test "allows event_type and lane_name to be omitted" do
      now = DateTime.utc_now()

      event = %Event.FlowNodeInstanceStarted{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        flow_node_id: "Task_1",
        flow_node_type: :task,
        occurred_at: now
      }

      assert event.event_type == nil
      assert event.lane_name == nil
    end

    test "raises when :flow_node_type missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.FlowNodeInstanceStarted, %{
          flow_node_instance_id: "fni-1",
          process_instance_id: "pi-1",
          flow_node_id: "Task_1",
          occurred_at: DateTime.utc_now()
        })
      end
    end
  end

  describe "FlowNodeInstanceFinished" do
    test "builds with terminal_state and handler type_properties" do
      now = DateTime.utc_now()

      event = %Event.FlowNodeInstanceFinished{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        flow_node_id: "BRT_1",
        flow_node_type: :business_rule_task,
        event_type: nil,
        lane_name: "default",
        terminal_state: :finished,
        type_properties: %{"hitPolicy" => "UNIQUE", "matchedRules" => [1]},
        error_info: nil,
        occurred_at: now
      }

      assert event.terminal_state == :finished
      assert event.type_properties == %{"hitPolicy" => "UNIQUE", "matchedRules" => [1]}
      assert event.error_info == nil
    end

    test "defaults type_properties to empty map and error_info to nil" do
      now = DateTime.utc_now()

      event = %Event.FlowNodeInstanceFinished{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        flow_node_id: "Task_1",
        flow_node_type: :task,
        terminal_state: :fatal,
        occurred_at: now
      }

      assert event.type_properties == %{}
      assert event.error_info == nil
    end

    test "carries error_info for fatal terminal states" do
      now = DateTime.utc_now()

      event = %Event.FlowNodeInstanceFinished{
        flow_node_instance_id: "fni-1",
        process_instance_id: "pi-1",
        flow_node_id: "Task_1",
        flow_node_type: :service_task,
        terminal_state: :fatal,
        type_properties: %{},
        error_info: %{"error_code" => "contract_violation", "message" => "Result schema failed"},
        occurred_at: now
      }

      assert event.terminal_state == :fatal
      assert event.error_info["error_code"] == "contract_violation"
    end

    test "raises when :terminal_state missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.FlowNodeInstanceFinished, %{
          flow_node_instance_id: "fni-1",
          process_instance_id: "pi-1",
          flow_node_id: "Task_1",
          flow_node_type: :task,
          occurred_at: DateTime.utc_now()
        })
      end
    end
  end

  describe "MessagePublished" do
    test "builds with required keys and publish-outcome defaults" do
      now = DateTime.utc_now()

      event = %Event.MessagePublished{
        message_id: "msg-1",
        message_name: "payment-received",
        correlation_value: "order-42",
        origin: %{"source" => "rest"},
        deliveries: [%{process_instance_id: "pi-1", flow_node_instance_id: "fni-1"}],
        started_process_instance_ids: ["pi-2"],
        pending: true,
        occurred_at: now
      }

      assert event.message_id == "msg-1"
      assert event.message_name == "payment-received"
      assert event.correlation_value == "order-42"
      assert event.pending == true
      assert length(event.deliveries) == 1
      assert event.started_process_instance_ids == ["pi-2"]
    end

    test "defaults deliveries, started_process_instance_ids, and pending" do
      now = DateTime.utc_now()

      event = %Event.MessagePublished{
        message_id: "msg-1",
        message_name: "payment-received",
        occurred_at: now
      }

      assert event.deliveries == []
      assert event.started_process_instance_ids == []
      assert event.pending == false
    end
  end

  describe "MessageArrived" do
    test "builds with delivery context and opaque payload default" do
      now = DateTime.utc_now()

      event = %Event.MessageArrived{
        message_id: "msg-1",
        message_name: "payment-received",
        correlation_value: "order-42",
        process_instance_id: "pi-1",
        flow_node_instance_id: "fni-1",
        payload: %{"amount" => 100},
        occurred_at: now
      }

      assert event.process_instance_id == "pi-1"
      assert event.flow_node_instance_id == "fni-1"
      assert event.payload == %{"amount" => 100}
    end

    test "defaults payload to empty map" do
      now = DateTime.utc_now()

      event = %Event.MessageArrived{
        message_id: "msg-1",
        message_name: "payment-received",
        process_instance_id: "pi-1",
        flow_node_instance_id: "fni-1",
        occurred_at: now
      }

      assert event.payload == %{}
    end
  end

  describe "SignalPublished" do
    test "builds broadcast outcome without payload or correlation" do
      now = DateTime.utc_now()

      event = %Event.SignalPublished{
        signal_id: "sig-1",
        signal_name: "shipment-ready",
        origin: %{"source" => "plugin:metrics"},
        deliveries: [%{process_instance_id: "pi-1", flow_node_instance_id: "fni-1"}],
        started_process_instance_ids: [],
        pending: false,
        occurred_at: now
      }

      assert event.signal_id == "sig-1"
      assert event.signal_name == "shipment-ready"
      assert event.pending == false

      assert event.deliveries == [
               %{process_instance_id: "pi-1", flow_node_instance_id: "fni-1"}
             ]
    end
  end

  describe "SignalArrived" do
    test "builds with signal identity and recipient only — no payload" do
      now = DateTime.utc_now()

      event = %Event.SignalArrived{
        signal_id: "sig-1",
        signal_name: "shipment-ready",
        process_instance_id: "pi-1",
        flow_node_instance_id: "fni-1",
        occurred_at: now
      }

      assert event.signal_id == "sig-1"
      assert event.signal_name == "shipment-ready"
      assert event.process_instance_id == "pi-1"
      assert event.flow_node_instance_id == "fni-1"
      assert Map.has_key?(event, :payload) == false
    end
  end

  describe "DecisionDefinitionDeployed" do
    test "builds with all required keys" do
      now = DateTime.utc_now()

      event = %Event.DecisionDefinitionDeployed{
        decision_definition_id: "risk-rules",
        version: "a1b2c3d4e5f6",
        source: "user:test-user",
        occurred_at: now
      }

      assert event.decision_definition_id == "risk-rules"
      assert event.version == "a1b2c3d4e5f6"
      assert event.source == "user:test-user"
      assert event.occurred_at == now
    end

    test "raises when :source missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.DecisionDefinitionDeployed, %{
          decision_definition_id: "risk-rules",
          version: "1.0.0",
          occurred_at: DateTime.utc_now()
        })
      end
    end
  end

  describe "DecisionDefinitionUndeployed" do
    test "builds with all required keys" do
      now = DateTime.utc_now()

      event = %Event.DecisionDefinitionUndeployed{
        decision_definition_id: "risk-rules",
        version: "a1b2c3d4e5f6",
        source: "plugin:my-plugin",
        occurred_at: now
      }

      assert event.decision_definition_id == "risk-rules"
      assert event.version == "a1b2c3d4e5f6"
      assert event.source == "plugin:my-plugin"
      assert event.occurred_at == now
    end

    test "allows version to be nil (bulk undeploy)" do
      now = DateTime.utc_now()

      event = %Event.DecisionDefinitionUndeployed{
        decision_definition_id: "risk-rules",
        source: "user:admin",
        occurred_at: now
      }

      assert event.version == nil
    end

    test "raises when :source missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.DecisionDefinitionUndeployed, %{
          decision_definition_id: "risk-rules",
          occurred_at: DateTime.utc_now()
        })
      end
    end
  end

  describe "DecisionEvaluated" do
    test "builds with all required keys" do
      now = DateTime.utc_now()

      event = %Event.DecisionEvaluated{
        decision_definition_id: "risk-rules",
        decision_model_id: "Decision_1",
        version: "a1b2c3d4e5f6",
        decision_version_id: "uuid-123",
        duration_microseconds: 1234,
        source: "user:test-user",
        occurred_at: now
      }

      assert event.decision_definition_id == "risk-rules"
      assert event.decision_model_id == "Decision_1"
      assert event.version == "a1b2c3d4e5f6"
      assert event.decision_version_id == "uuid-123"
      assert event.duration_microseconds == 1234
      assert event.source == "user:test-user"
      assert event.occurred_at == now
    end

    test "allows optional fields to be nil" do
      now = DateTime.utc_now()

      event = %Event.DecisionEvaluated{
        decision_definition_id: "risk-rules",
        source: "plugin:analytics",
        occurred_at: now
      }

      assert event.decision_model_id == nil
      assert event.version == nil
      assert event.decision_version_id == nil
      assert event.duration_microseconds == nil
    end

    test "raises when :source missing" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event.DecisionEvaluated, %{
          decision_definition_id: "risk-rules",
          occurred_at: DateTime.utc_now()
        })
      end
    end
  end
end
