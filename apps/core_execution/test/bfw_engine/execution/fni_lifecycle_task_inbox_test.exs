defmodule BfwEngine.Execution.FniLifecycleTaskInboxTest do
  @moduledoc """
  Regression coverage for C1: PI-side terminations
  (`FniLifecycle.transition_to_fatal/8`, `transition_to_aborted/8`,
  `transition_to_error/8`, `transition_to_interrupted/8`) must thread the
  FNI entry's `multi_instance_id` / `iteration_index` through to
  `TaskInboxEvents` so a withdrawn Multi-Instance User Task iteration still
  publishes `UserTaskFinished`.

  These tests call the real `FniLifecycle.transition_to_*` functions with
  the `iteration_context` a real call site derives from the FNI entry
  (`multi_instance_id: Map.get(entry, :multi_instance_id), iteration_index:
  Map.get(entry, :iteration_index)`) — not a hand-built
  `%Event.FlowNodeInstanceFinished{}` that already carries
  `iteration_index`. That is exactly the plumbing C1 was missing.
  """

  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.MultiInstance
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.FniLifecycle
  alias BfwEngine.Types.Event

  @fni_id "fni-c1-regression-00000001"
  @pi_id "pi-c1-regression-00000001"
  @shell_fni_id "fni-c1-regression-shell"

  @user_task %FlowNode{
    id: "UserTask_1",
    type: :user_task,
    type_data: %FlowNodeData.UserTask{}
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

  defmodule NoOpAdapter do
    @moduledoc false
    @behaviour BfwEngine.Execution.Persistence

    @impl true
    def create_process_instance(attributes), do: {:ok, attributes}
    @impl true
    def update_process_instance(_id, _changes), do: :ok
    @impl true
    def create_flow_node_instance(attributes), do: {:ok, attributes}
    @impl true
    def update_flow_node_instance(_id, :update_finished, _changes) do
      count = Process.get(:terminal_write_count, 0)
      Process.put(:terminal_write_count, count + 1)
      reject_after = Process.get(:reject_terminal_after)

      if is_integer(reject_after) and count >= reject_after do
        {:error, :already_terminal}
      else
        :ok
      end
    end

    @impl true
    def update_flow_node_instance(_id, _action, _changes), do: :ok

    @impl true
    def finish_flow_node_instance(flow_node_instance_id, changes) do
      case update_flow_node_instance(flow_node_instance_id, :update_finished, changes) do
        :ok ->
          {:ok, %{}, Process.get(:bfw_persistence_previous_flow_node_state, "active")}

        other ->
          other
      end
    end

    @impl true
    def list_running_process_instances(_opts), do: {:ok, %{records: [], next_cursor: nil}}
    @impl true
    def list_flow_node_instances(_id), do: {:ok, []}
    @impl true
    def finish_fni_with_data_objects(_fni_id, _fni_changes, _intents), do: {:ok, %{writes: []}}
    @impl true
    def write_data_object(_params), do: {:ok, %{write_id: "mock", created_at: DateTime.utc_now()}}
    @impl true
    def list_data_objects(_process_instance_id), do: {:ok, []}
    @impl true
    def cleanup_orphaned_flow_node_instances, do: {:ok, 0}
    @impl true
    def cleanup_orphaned_process_instances, do: {:ok, 0}
    @impl true
    def get_process_instance_for_retry(_id), do: {:error, :not_found}
    @impl true
    def list_all_flow_node_instances(_id), do: {:ok, []}
    @impl true
    def count_all_flow_node_instances(_id), do: {:ok, 0}
    @impl true
    def get_flow_node_instance_by_id(_id), do: {:error, :not_found}
    @impl true
    def execute_retry_reset(_id, _opts), do: {:ok, []}
    @impl true
    def revert_retry(_id, _state, _finished_at), do: :ok
    @impl true
    def list_child_process_instances(_), do: {:ok, []}
    @impl true
    def patch_fni_type_properties(_, _), do: :ok
    @impl true
    def create_gateway_pending_arrival(_params), do: :ok
    @impl true
    def list_gateway_pending_arrivals(_process_instance_id), do: {:ok, []}
    @impl true
    def delete_gateway_pending_arrivals_for_gateway(_fni_id), do: :ok
  end

  defmodule CapturingSink do
    @moduledoc false
    @behaviour BfwEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
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
    Process.delete(:bfw_persistence_previous_flow_node_state)
    Process.delete(:reject_terminal_after)
    Process.delete(:terminal_write_count)
    Application.put_env(:core_execution, :persistence_adapter, NoOpAdapter)
    Application.put_env(:core_execution, :persistence_retry_max_attempts, 1)

    sink_name = "test:c1-regression-#{inspect(self())}"
    :ok = EngineEventBus.register_sink(sink_name, CapturingSink, test_pid: self())

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :persistence_retry_max_attempts)
    end)

    :ok
  end

  describe "MI iteration termination publishes UserTaskFinished(:aborted)" do
    test "transition_to_interrupted (completionCondition early break / boundary interrupt)" do
      Process.put(:bfw_persistence_previous_flow_node_state, "waiting")

      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :cancelled_by_mi_shell,
          @multi_instance_user_task,
          %{},
          nil,
          nil,
          multi_instance_id: @shell_fni_id,
          iteration_index: 0,
          was_waiting: true
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{iteration_index: 0}}
      assert_receive {:captured, %Event.UserTaskFinished{} = finished}
      assert finished.outcome == :aborted
      assert finished.flow_node_type == :user_task
    end

    test "transition_to_aborted (PI abort cascade)" do
      Process.put(:bfw_persistence_previous_flow_node_state, "waiting")

      :ok =
        FniLifecycle.transition_to_aborted(
          @fni_id,
          @pi_id,
          "process_aborted",
          @multi_instance_user_task,
          %{},
          nil,
          nil,
          multi_instance_id: @shell_fni_id,
          iteration_index: 1,
          was_waiting: true
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{iteration_index: 1}}
      assert_receive {:captured, %Event.UserTaskFinished{} = finished}
      assert finished.outcome == :aborted
      assert finished.flow_node_type == :user_task
    end

    test "transition_to_fatal (crash cascade)" do
      Process.put(:bfw_persistence_previous_flow_node_state, "waiting")

      :ok =
        FniLifecycle.transition_to_fatal(
          @fni_id,
          @pi_id,
          %{"error_code" => "process_fatal", "message" => "cascade"},
          @multi_instance_user_task,
          %{},
          nil,
          nil,
          multi_instance_id: @shell_fni_id,
          iteration_index: 2,
          was_waiting: true
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{iteration_index: 2}}
      assert_receive {:captured, %Event.UserTaskFinished{} = finished}
      assert finished.outcome == :aborted
      assert finished.flow_node_type == :user_task
    end

    test "transition_to_error (Error End Event cascade)" do
      Process.put(:bfw_persistence_previous_flow_node_state, "waiting")

      :ok =
        FniLifecycle.transition_to_error(
          @fni_id,
          @pi_id,
          %{"error_code" => "process_error", "message" => "cascade"},
          @multi_instance_user_task,
          %{},
          nil,
          nil,
          multi_instance_id: @shell_fni_id,
          iteration_index: 3,
          was_waiting: true
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{iteration_index: 3}}
      assert_receive {:captured, %Event.UserTaskFinished{} = finished}
      assert finished.outcome == :aborted
      assert finished.flow_node_type == :user_task
    end
  end

  describe "MI shell termination does not publish UserTaskFinished" do
    test "transition_to_interrupted with no multi_instance_id / iteration_index (shell FNI)" do
      :ok =
        FniLifecycle.transition_to_interrupted(
          @shell_fni_id,
          @pi_id,
          :terminated_by_end_event,
          @multi_instance_user_task,
          %{}
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{iteration_index: nil}}
      refute_receive {:captured, %Event.UserTaskFinished{}}
    end
  end

  describe "inbox eligibility" do
    test "a waiting row publishes UserTaskFinished even when the caller says it was active" do
      Process.put(:bfw_persistence_previous_flow_node_state, "waiting")

      :ok =
        FniLifecycle.transition_to_aborted(
          @fni_id,
          @pi_id,
          "process_aborted",
          @user_task,
          %{},
          nil,
          nil,
          was_waiting: false
        )

      assert_receive {:captured, %Event.UserTaskFinished{outcome: :aborted}}
    end

    test "transition_to_fatal with was_waiting false publishes no UserTaskFinished" do
      :ok =
        FniLifecycle.transition_to_fatal(
          @fni_id,
          @pi_id,
          %{"error_code" => "enter_failed", "message" => "failed before waiting"},
          @multi_instance_user_task,
          %{},
          nil,
          nil,
          multi_instance_id: @shell_fni_id,
          iteration_index: 0,
          was_waiting: false
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{terminal_state: :fatal}}
      refute_receive {:captured, %Event.UserTaskFinished{}}
    end

    test "transition_to_fatal with was_waiting true publishes one aborted UserTaskFinished" do
      Process.put(:bfw_persistence_previous_flow_node_state, "waiting")

      :ok =
        FniLifecycle.transition_to_fatal(
          @fni_id,
          @pi_id,
          %{"error_code" => "process_fatal", "message" => "cascade"},
          @multi_instance_user_task,
          %{},
          nil,
          nil,
          multi_instance_id: @shell_fni_id,
          iteration_index: 4,
          was_waiting: true
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{iteration_index: 4}}
      assert_receive {:captured, %Event.UserTaskFinished{} = finished}
      assert finished.outcome == :aborted
    end

    test "a second transition_to_interrupted publishes no second UserTaskFinished" do
      Process.put(:bfw_persistence_previous_flow_node_state, "waiting")
      Process.put(:reject_terminal_after, 1)

      :ok =
        FniLifecycle.transition_to_interrupted(
          @fni_id,
          @pi_id,
          :cancelled_by_mi_shell,
          @multi_instance_user_task,
          %{},
          nil,
          nil,
          multi_instance_id: @shell_fni_id,
          iteration_index: 0,
          was_waiting: true
        )

      assert_receive {:captured, %Event.FlowNodeInstanceFinished{terminal_state: :interrupted}}
      assert_receive {:captured, %Event.UserTaskFinished{outcome: :aborted}}

      assert {:ok, :already_terminal} =
               FniLifecycle.transition_to_interrupted(
                 @fni_id,
                 @pi_id,
                 :cancelled_by_mi_shell,
                 @multi_instance_user_task,
                 %{},
                 nil,
                 nil,
                 multi_instance_id: @shell_fni_id,
                 iteration_index: 0,
                 was_waiting: true
               )

      refute_receive {:captured, %Event.UserTaskFinished{}}
      refute_receive {:captured, %Event.FlowNodeInstanceFinished{}}
    end
  end
end
