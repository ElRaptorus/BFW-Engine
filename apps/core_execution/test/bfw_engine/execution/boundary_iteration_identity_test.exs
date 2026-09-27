defmodule BfwEngine.Execution.BoundaryIterationIdentityTest do
  @moduledoc """
  A boundary finish event copies the host iteration identity so a
  multi-instance host and its boundary stay on the same iteration.
  """

  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.Persistence.NoOp
  alias BfwEngine.Execution.ProcessInstance.BoundaryOrchestrator
  alias BfwEngine.Types.Event

  defmodule CapturingSink do
    @moduledoc false
    @behaviour BfwEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
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
    Application.put_env(:core_execution, :persistence_adapter, NoOp)
    Application.put_env(:core_execution, :persistence_retry_max_attempts, 1)
    sink_name = "test:boundary-iteration-#{inspect(self())}"
    :ok = EngineEventBus.register_sink(sink_name, CapturingSink, test_pid: self())

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :persistence_retry_max_attempts)
    end)

    :ok
  end

  test "error boundary finish carries the host iteration index" do
    host_id = "host-fni"

    boundary_node = %FlowNode{
      id: "Boundary_Error",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{attached_to_ref: "UserTask_1"},
      outgoing: []
    }

    host_entry = %{
      pid: nil,
      flow_node_id: "UserTask_1",
      flow_node_type: :user_task,
      state: :waiting,
      type_properties: %{},
      token: nil,
      multi_instance_id: "shell-fni",
      iteration_index: 3
    }

    data = %{
      process_instance_id: "pi-boundary",
      root_process_instance_id: "pi-boundary",
      process_model: %{flow_nodes: [boundary_node], sequence_flows: [], lanes: []},
      flow_node_instance_states: %{host_id => host_entry},
      conditional_waiters: %{}
    }

    {_data, ^host_id, false, _targets} =
      BoundaryOrchestrator.handle_boundary_catch(
        data,
        host_id,
        boundary_node.id,
        %{"error_code" => "E"},
        false,
        nil
      )

    assert_receive {:captured, %Event.FlowNodeInstanceFinished{} = finished}
    assert finished.multi_instance_id == "shell-fni"
    assert finished.iteration_index == 3
    assert finished.flow_node_id == "Boundary_Error"
  end
end
