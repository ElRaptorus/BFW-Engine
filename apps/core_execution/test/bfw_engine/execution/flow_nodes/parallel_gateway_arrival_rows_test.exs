defmodule BfwEngine.Execution.FlowNodes.ParallelGatewayArrivalRowsTest do
  @moduledoc """
  A duplicate arrival fatals a Parallel Join but keeps its persisted
  `gateway_pending_arrivals` rows, so a retry can rebuild the join; only a
  firing join deletes them.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.Execution.FlowNodes.ParallelGateway
  alias BfwEngine.Execution.HandlerContext
  alias BfwEngine.Types.Token

  @observer_name :parallel_gateway_arrival_rows_observer

  defmodule ArrivalRecordingAdapter do
    @moduledoc false
    alias BfwEngine.Execution.Persistence
    alias BfwEngine.Execution.Persistence.NoOp

    for {name, arity} <- Persistence.behaviour_info(:callbacks),
        name != :delete_gateway_pending_arrivals_for_gateway do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(arguments)),
        do: NoOp.unquote(name)(unquote_splicing(arguments))
    end

    def delete_gateway_pending_arrivals_for_gateway(gateway_flow_node_instance_id) do
      send(
        :parallel_gateway_arrival_rows_observer,
        {:arrivals_deleted, gateway_flow_node_instance_id}
      )

      :ok
    end
  end

  setup do
    Application.put_env(:core_execution, :persistence_adapter, ArrivalRecordingAdapter)
    Process.register(self(), @observer_name)

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
    end)
  end

  test "a duplicate arrival keeps the persisted arrivals, a firing join deletes them" do
    {gateway, context} = join_context()

    assert {:async, "fni-join-1", continuation, %{join_gateway: true}} =
             ParallelGateway.handle_enter(gateway, token(), context)

    duplicate_task = Task.async(continuation)
    send(duplicate_task.pid, {:join_token_arrived, token(), ["fni-task-a-2"], "Flow_from_Task_A"})

    assert {:error, {:duplicate_join_arrival, %{incoming_flow_id: "Flow_from_Task_A"}}} =
             Task.await(duplicate_task, 1_000)

    refute_received {:arrivals_deleted, _gateway_flow_node_instance_id}

    {:async, "fni-join-1", continuation, _metadata} =
      ParallelGateway.handle_enter(gateway, token(), context)

    firing_task = Task.async(continuation)
    send(firing_task.pid, {:join_token_arrived, token(), ["fni-task-b"], "Flow_from_Task_B"})

    assert {:ok, _result} = Task.await(firing_task, 1_000)
    assert_received {:arrivals_deleted, "fni-join-1"}
  end

  defp token do
    %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: %{},
      created_at: DateTime.utc_now()
    }
  end

  defp join_context do
    gateway = %FlowNode{
      id: "Join_1",
      type: :parallel_gateway,
      type_data: %FlowNodeData.ParallelGateway{},
      incoming: ["Flow_from_Task_A", "Flow_from_Task_B"],
      outgoing: ["Flow_to_Next_1"]
    }

    next_node = %FlowNode{id: "Next_1", type: :task, type_data: %FlowNodeData.Task{}}

    process_model = %BpmnProcess{
      id: "proc-1",
      flow_nodes: [gateway, next_node],
      sequence_flows: [
        %SequenceFlow{id: "Flow_from_Task_A", source_ref: "Task_A", target_ref: "Join_1"},
        %SequenceFlow{id: "Flow_from_Task_B", source_ref: "Task_B", target_ref: "Join_1"},
        %SequenceFlow{id: "Flow_to_Next_1", source_ref: "Join_1", target_ref: "Next_1"}
      ]
    }

    context = %HandlerContext{
      flow_node_instance_id: "fni-join-1",
      process_instance_id: "pi-1",
      process_model: process_model,
      join_metadata: %{
        incoming_flow_id: "Flow_from_Task_A",
        source_flow_node_instance_id: "fni-task-a"
      }
    }

    {gateway, context}
  end
end
