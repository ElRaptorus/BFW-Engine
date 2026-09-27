defmodule BfwEngine.Execution.TaskInboxEventsTest do
  @moduledoc """
  Unit tests for `BfwEngine.Execution.TaskInboxEvents`: the `inbox_task?/1`
  truth table and the `UserTaskFinished` derivation performed by
  `publish_flow_node_instance_finished/2`.
  """

  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.MultiInstance
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.TaskInboxEvents
  alias BfwEngine.Types.Event

  defmodule CapturingSink do
    @moduledoc false
    @behaviour BfwEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def accepts?(%Event.UserTaskCreated{}), do: true
    def accepts?(%Event.UserTaskFinished{}), do: true
    def accepts?(%Event.FlowNodeInstanceFinished{}), do: true
    def accepts?(_event), do: false

    @impl true
    def handle_event(event, state) do
      send(state.test_pid, {:captured, event})
      {:ok, state}
    end

    @impl true
    def handle_shutdown(_state), do: :ok
  end

  setup do
    sink_name = "test:task-inbox-events-#{inspect(self())}"
    :ok = EngineEventBus.register_sink(sink_name, CapturingSink, test_pid: self())
    :ok
  end

  @user_task %FlowNode{
    id: "UserTask_1",
    type: :user_task,
    type_data: %FlowNodeData.UserTask{}
  }

  @confirming_manual_task %FlowNode{
    id: "ManualTask_1",
    type: :manual_task,
    type_data: %FlowNodeData.ManualTask{require_confirmation: true}
  }

  @non_confirming_manual_task %FlowNode{
    id: "ManualTask_2",
    type: :manual_task,
    type_data: %FlowNodeData.ManualTask{require_confirmation: false}
  }

  @service_task %FlowNode{
    id: "ServiceTask_1",
    type: :service_task,
    type_data: %FlowNodeData.ServiceTask{implementation: "echo"}
  }

  @multi_instance_user_task %FlowNode{
    id: "UserTask_MI",
    type: :user_task,
    type_data: %FlowNodeData.UserTask{},
    multi_instance: %MultiInstance{
      is_sequential: false,
      collection_expression: "token.items",
      output_collection: "results"
    }
  }

  describe "inbox_task?/1" do
    test "is true for a User Task" do
      assert TaskInboxEvents.inbox_task?(@user_task)
    end

    test "is true for a confirming Manual Task" do
      assert TaskInboxEvents.inbox_task?(@confirming_manual_task)
    end

    test "is false for a non-confirming Manual Task" do
      refute TaskInboxEvents.inbox_task?(@non_confirming_manual_task)
    end

    test "is false for a Service Task" do
      refute TaskInboxEvents.inbox_task?(@service_task)
    end

    test "is false for nil" do
      refute TaskInboxEvents.inbox_task?(nil)
    end
  end

  describe "publish_flow_node_instance_finished/2 outcome derivation" do
    for {terminal_state, expected_outcome} <- [
          {:finished, :completed},
          {:aborted, :aborted},
          {:interrupted, :aborted},
          {:error, :aborted},
          {:fatal, :aborted}
        ] do
      test "maps terminal_state #{terminal_state} to outcome #{expected_outcome} for a User Task" do
        event = finished_event(@user_task, unquote(terminal_state))

        TaskInboxEvents.publish_flow_node_instance_finished(event, @user_task, was_waiting: true)

        assert_receive {:captured, %Event.FlowNodeInstanceFinished{} = received_finished}
        assert received_finished.terminal_state == unquote(terminal_state)

        assert_receive {:captured, %Event.UserTaskFinished{} = received_outcome}
        assert received_outcome.outcome == unquote(expected_outcome)
        assert received_outcome.flow_node_type == :user_task

        refute_receive {:captured, %Event.UserTaskFinished{}}
      end
    end

    test "publishes no UserTaskFinished for a non-inbox flow node" do
      event = finished_event(@service_task, :finished)

      TaskInboxEvents.publish_flow_node_instance_finished(event, @service_task)

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{}}
      refute_receive {:captured, %Event.UserTaskFinished{}}
    end

    test "publishes no UserTaskFinished for a nil flow node" do
      event = finished_event(@user_task, :finished)

      TaskInboxEvents.publish_flow_node_instance_finished(event, nil)

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{}}
      refute_receive {:captured, %Event.UserTaskFinished{}}
    end

    test "publishes no UserTaskFinished for an MI shell finish (iteration_index nil)" do
      event = finished_event(@multi_instance_user_task, :finished, iteration_index: nil)

      TaskInboxEvents.publish_flow_node_instance_finished(event, @multi_instance_user_task)

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{}}
      refute_receive {:captured, %Event.UserTaskFinished{}}
    end

    test "a lost terminal write publishes nothing" do
      event = finished_event(@service_task, :finished)

      assert :ok =
               TaskInboxEvents.publish_committed_finish(
                 {:error, :already_terminal},
                 event,
                 @service_task
               )

      refute_receive {:captured, _}
    end

    test "a committed terminal write still publishes FlowNodeInstanceFinished" do
      event = finished_event(@service_task, :finished)

      assert :ok = TaskInboxEvents.publish_committed_finish(:ok, event, @service_task)

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{}}
      refute_receive {:captured, %Event.UserTaskFinished{}}
    end

    test "publishes UserTaskFinished for an MI iteration finish (iteration_index set)" do
      event = finished_event(@multi_instance_user_task, :finished, iteration_index: 0)

      TaskInboxEvents.publish_flow_node_instance_finished(event, @multi_instance_user_task)

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{}}
      assert_receive {:captured, %Event.UserTaskFinished{outcome: :completed}}
    end
  end

  defp finished_event(flow_node, terminal_state, opts \\ []) do
    %Event.FlowNodeInstanceFinished{
      flow_node_instance_id: "fni-1",
      process_instance_id: "pi-1",
      root_process_instance_id: "pi-1",
      flow_node_id: flow_node.id,
      flow_node_type: flow_node.type,
      terminal_state: terminal_state,
      lane_name: nil,
      iteration_index: Keyword.get(opts, :iteration_index),
      occurred_at: DateTime.utc_now()
    }
  end
end
