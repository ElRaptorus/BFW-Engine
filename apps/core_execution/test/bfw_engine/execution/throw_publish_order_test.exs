defmodule BfwEngine.Execution.ThrowPublishOrderTest do
  @moduledoc """
  Throw-side handlers resolve their outgoing flows before publishing: an
  unresolvable flow fatals the node and nothing reaches a subscriber. Also
  covers the correlation value types a throw or catch may produce.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.MessageDefinition
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.BPMN.Model.SignalDefinition
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Execution.FlowNodes
  alias BfwEngine.Execution.FlowNodes.MessageEventHelper
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Execution.ServiceReset
  alias BfwEngine.Types.Token

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      BfwEngine.Execution.Persistence.NoOp
    )

    ServiceReset.message_subscriptions()
    ServiceReset.signal_subscriptions()
    MessageSubscriptions.mark_ready()
    SignalSubscriptions.mark_ready()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      ServiceReset.message_subscriptions()
      ServiceReset.signal_subscriptions()
    end)

    {:ok, _subscription_id} =
      MessageSubscriptions.register(%{
        process_instance_id: "pi-listener",
        flow_node_instance_id: "fni-listener",
        flow_node_id: "Catch",
        message_name: "order",
        expected_correlation_value: :none,
        kind: :intermediate_catch,
        via_pid: self()
      })

    {:ok, _subscription_id} =
      SignalSubscriptions.register(%{
        process_instance_id: "pi-listener",
        flow_node_instance_id: "fni-listener-signal",
        flow_node_id: "CatchSignal",
        signal_name: "go",
        kind: :intermediate_catch,
        via_pid: self()
      })

    :ok
  end

  describe "an unresolvable outgoing flow fatals before anything is published" do
    test "MessageThrowEvent" do
      type_data = %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Message{message_ref: "Message_1"}
      }

      {flow_node, context} = throw_setup(:intermediate_throw_event, type_data, outgoing: [])

      assert {:error, %{reason: :dead_end}} =
               FlowNodes.MessageThrowEvent.handle_enter(flow_node, token(), context)

      refute_received {:message_arrived, _message_id, _payload, _correlation}
    end

    test "SendTask with an implicit split" do
      type_data = %FlowNodeData.SendTask{message_ref: "Message_1"}

      {flow_node, context} =
        throw_setup(:send_task, type_data, outgoing: ["Flow_a", "Flow_b"], extra_targets: 2)

      assert {:error, %{reason: :implicit_split}} =
               FlowNodes.SendTask.handle_enter(flow_node, token(), context)

      refute_received {:message_arrived, _message_id, _payload, _correlation}
    end

    test "SignalThrowEvent" do
      type_data = %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Signal{signal_ref: "Signal_1"}
      }

      {flow_node, context} = throw_setup(:intermediate_throw_event, type_data, outgoing: [])

      assert {:error, %{reason: :dead_end}} =
               FlowNodes.SignalThrowEvent.handle_enter(flow_node, token(), context)

      refute_received {:signal_arrived, _signal_id, _triggerer}
    end
  end

  describe "with a resolvable flow the message is published" do
    test "MessageThrowEvent publishes and forwards along the flow" do
      type_data = %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Message{message_ref: "Message_1"}
      }

      {flow_node, context} =
        throw_setup(:intermediate_throw_event, type_data, outgoing: ["Flow_a"], extra_targets: 1)

      assert {:ok, %{next_flow_node_ids: ["Target_a"]}} =
               FlowNodes.MessageThrowEvent.handle_enter(flow_node, token(), context)

      assert_received {:message_arrived, _message_id, %{}, "fni-throw"}
    end

    test "SignalThrowEvent publishes and forwards along the flow" do
      type_data = %FlowNodeData.IntermediateThrowEvent{
        event_definition: %EventDefinition.Signal{signal_ref: "Signal_1"}
      }

      {flow_node, context} =
        throw_setup(:intermediate_throw_event, type_data, outgoing: ["Flow_a"], extra_targets: 1)

      assert {:ok, %{next_flow_node_ids: ["Target_a"]}} =
               FlowNodes.SignalThrowEvent.handle_enter(flow_node, token(), context)

      assert_received {:signal_arrived, _signal_id, _triggerer}
    end
  end

  describe "correlation value types" do
    test "a list or map result on the throw side fails with a readable reason" do
      for expression <- ["[1, 2]", "{a: 1}"] do
        source = %FlowNodeData.SendTask{correlation_retrieval_expression: expression}

        assert {:error, {:correlation_expression_failed, reason}} =
                 MessageEventHelper.resolve_throw_correlation(source, %{}, bare_context(nil))

        assert reason =~ "cannot convert"
      end
    end

    test "a list or map result on the catch side (correlation key) fails the same way" do
      for expression <- ["[1, 2]", "{a: 1}"] do
        assert {:error, {:correlation_expression_failed, reason}} =
                 MessageEventHelper.evaluate_correlation_key(
                   %BpmnProcess{id: "p", correlation_key: expression},
                   bare_context(expression),
                   %{}
                 )

        assert reason =~ "cannot convert"
      end
    end

    test "a number is converted to its text" do
      source = %FlowNodeData.SendTask{correlation_retrieval_expression: "42"}

      assert {:ok, "42"} =
               MessageEventHelper.resolve_throw_correlation(source, %{}, bare_context(nil))
    end

    test "a date nested in a list is reported as text, not as a tuple" do
      source = %FlowNodeData.SendTask{
        correlation_retrieval_expression: "[date(\"2026-01-02\")]"
      }

      assert {:error, {:correlation_expression_failed, reason}} =
               MessageEventHelper.resolve_throw_correlation(source, %{}, bare_context(nil))

      assert reason =~ "2026-01-02"
      refute reason =~ "feel_date"
    end
  end

  defp token do
    %Token{
      id: "token-1",
      process_instance_id: "pi-throw",
      payload: %{},
      created_at: DateTime.utc_now()
    }
  end

  defp bare_context(correlation_key) do
    %HandlerContext{
      flow_node_instance_id: "fni-throw",
      process_instance_id: "pi-throw",
      process_model: %BpmnProcess{id: "proc-throw", correlation_key: correlation_key}
    }
  end

  # Builds the throwing node plus `extra_targets` end events reached by
  # `Flow_a`, `Flow_b`, ...; `outgoing` lists the flow ids the node declares.
  defp throw_setup(type, type_data, options) do
    outgoing = Keyword.fetch!(options, :outgoing)
    extra_targets = Keyword.get(options, :extra_targets, 0)

    flow_node = %FlowNode{id: "Throw_1", type: type, type_data: type_data, outgoing: outgoing}

    targets =
      for index <- 1..extra_targets//1 do
        suffix = <<?a + index - 1>>
        %FlowNode{id: "Target_#{suffix}", type: :end_event, type_data: %FlowNodeData.EndEvent{}}
      end

    sequence_flows =
      for index <- 1..extra_targets//1 do
        suffix = <<?a + index - 1>>
        %SequenceFlow{id: "Flow_#{suffix}", source_ref: "Throw_1", target_ref: "Target_#{suffix}"}
      end

    process_model = %BpmnProcess{
      id: "proc-throw",
      flow_nodes: [flow_node | targets],
      sequence_flows: sequence_flows
    }

    definitions = %Definitions{
      processes: [process_model],
      messages: [%MessageDefinition{id: "Message_1", name: "order"}],
      signals: [%SignalDefinition{id: "Signal_1", name: "go"}],
      raw_xml: ""
    }

    context = %HandlerContext{
      flow_node_instance_id: "fni-throw",
      process_instance_id: "pi-throw",
      process_model: process_model,
      definitions: definitions
    }

    {flow_node, context}
  end
end
