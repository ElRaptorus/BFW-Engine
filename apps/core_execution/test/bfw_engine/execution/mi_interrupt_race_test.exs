defmodule BfwEngine.Execution.MiInterruptRaceTest do
  @moduledoc """
  The multi-instance shell interrupt must not withdraw an iteration whose
  finish is already committed or already queued as `{:ok, %FlowNodeResult{}}`.
  """

  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Execution.FlowNodeResult
  alias BfwEngine.Execution.Persistence.NoOp
  alias BfwEngine.Execution.ProcessInstance
  alias BfwEngine.Types.Event

  @shell_id "shell-fni"
  @iteration_id "iteration-fni"

  defmodule CapturingSink do
    @moduledoc false
    @behaviour BfwEngine.Plugin.EventSink

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def accepts?(%Event.UserTaskFinished{}), do: true
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

    sink_name = "test:mi-interrupt-#{inspect(self())}"
    :ok = EngineEventBus.register_sink(sink_name, CapturingSink, test_pid: self())

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :persistence_retry_max_attempts)
      Process.delete(:bfw_persistence_terminal_write_result)
      Process.delete(:bfw_persisted_flow_node_instances)
    end)

    :ok
  end

  test "a shutdown with a queued ok result does not publish UserTaskFinished aborted" do
    iteration_pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        receive do
          {:EXIT, _from, :shutdown} -> exit(:noproc)
        end
      end)

    send(
      self(),
      {:fni_result, @iteration_id, {:ok, %FlowNodeResult{output_payload: %{"done" => true}}}}
    )

    {:keep_state, data} =
      ProcessInstance.running(
        :cast,
        {:mi_interrupt_remaining, @shell_id},
        iteration_data(iteration_pid, self())
      )

    assert data.flow_node_instance_states[@iteration_id].state == :waiting
    refute_receive {:captured, %Event.UserTaskFinished{}}, 100

    receive do
      {:fni_result, @iteration_id, {:ok, %FlowNodeResult{}}} -> :ok
    after
      0 -> flunk("queued iteration result was consumed")
    end
  end

  test "a dead iteration pid with a queued ok result is left alone" do
    dead_pid = spawn(fn -> :ok end)
    ref = Process.monitor(dead_pid)

    receive do
      {:DOWN, ^ref, :process, ^dead_pid, _reason} -> :ok
    end

    send(
      self(),
      {:fni_result, @iteration_id, {:ok, %FlowNodeResult{output_payload: %{"done" => true}}}}
    )

    {:keep_state, data} =
      ProcessInstance.running(
        :cast,
        {:mi_interrupt_remaining, @shell_id},
        iteration_data(dead_pid, self(), :active)
      )

    assert data.flow_node_instance_states[@iteration_id].state == :active
    refute_receive {:captured, %Event.UserTaskFinished{}}, 100
  end

  test "an interrupt that loses the terminal write notifies the shell from the persisted token" do
    Process.put(:bfw_persistence_terminal_write_result, {:error, :already_terminal})

    Process.put(:bfw_persisted_flow_node_instances, %{
      @iteration_id => %{state: "finished", output_token: %{"kept" => 1}}
    })

    test_pid = self()

    shell_pid =
      spawn(fn ->
        receive do
          message -> send(test_pid, {:shell_received, message})
        after
          2_000 -> send(test_pid, :shell_timeout)
        end
      end)

    iteration_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:keep_state, data} =
      ProcessInstance.running(
        :cast,
        {:mi_interrupt_remaining, @shell_id},
        iteration_data(iteration_pid, shell_pid, :waiting)
      )

    assert data.flow_node_instance_states[@iteration_id].state == :waiting

    assert_receive {:shell_received,
                    {:mi_iteration_completed, @iteration_id,
                     {:ok, %FlowNodeResult{output_payload: payload}}}}

    assert payload == %{"kept" => 1}
    refute_receive {:captured, %Event.UserTaskFinished{}}, 100
  end

  defp iteration_data(iteration_pid, shell_pid, state \\ :waiting) do
    flow_node = %FlowNode{
      id: "UserTask_MI",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{}
    }

    entry = %{
      pid: iteration_pid,
      flow_node_id: flow_node.id,
      flow_node_type: :user_task,
      state: state,
      token: %{payload: %{}},
      type_properties: %{},
      multi_instance_id: @shell_id,
      iteration_index: 1
    }

    %{
      process_instance_id: "pi-interrupt",
      root_process_instance_id: "pi-interrupt",
      process_model: %{flow_nodes: [flow_node], lanes: [], sequence_flows: []},
      flow_node_instance_states: %{@iteration_id => entry},
      mi_shell_tasks: %{@iteration_id => {@shell_id, shell_pid}}
    }
  end
end
