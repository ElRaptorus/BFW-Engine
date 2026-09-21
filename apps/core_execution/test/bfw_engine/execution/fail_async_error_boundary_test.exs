defmodule BfwEngine.Execution.FailAsyncErrorBoundaryTest do
  @moduledoc """
  fail_async and handle_complete errors must be catchable by Error
  Boundary Events, including boundaries that only declare `errorRef`.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.Model.Definitions
  alias BfwEngine.BPMN.Model.ErrorDefinition
  alias BfwEngine.BPMN.Model.EventDefinition
  alias BfwEngine.BPMN.Model.FlowNode
  alias BfwEngine.BPMN.Model.FlowNodeData
  alias BfwEngine.BPMN.Model.Process, as: BpmnProcess
  alias BfwEngine.BPMN.Model.SequenceFlow
  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Execution
  alias BfwEngine.Execution.ProcessInstance
  alias BfwEngine.Types.Identity

  defmodule ParkingServiceTaskHandler do
    @behaviour BfwEngine.Execution.FlowNodeHandler

    @impl true
    def handle_enter(_flow_node, _token, context) do
      {:async, context.flow_node_instance_id}
    end
  end

  defmodule ParkingServiceTaskDispatch do
    @behaviour BfwEngine.Execution.ServiceTaskDispatch

    @impl true
    def lookup_handler("park-and-wait"), do: {:ok, ParkingServiceTaskHandler}
    def lookup_handler(_implementation), do: {:error, :not_found}
  end

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      BfwEngine.Execution.Persistence.NoOp
    )

    Application.put_env(:core_execution, :service_task_dispatch, ParkingServiceTaskDispatch)

    ModelCache.reset_state()

    ref = make_ref()
    subscribe_pi_events(ref)
    subscribe_fni_events(ref)

    on_exit(fn ->
      unsubscribe_pi_events(ref)
      unsubscribe_fni_events(ref)
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :service_task_dispatch)
      ModelCache.reset_state()
    end)

    {:ok, ref: ref}
  end

  test "fail_async with matching errorRef follows the interrupting error boundary", %{ref: ref} do
    version_id = random_id()
    ModelCache.put_new(version_id, build_async_service_with_error_ref_boundary())

    process_instance_id = random_id()

    assert {:ok, process_instance_pid} =
             start_process_instance(version_id, process_instance_id)

    service_fni_id = await_waiting_service_task(ref, process_instance_id)

    assert :ok =
             ProcessInstance.fail_async_service_task(
               process_instance_pid,
               service_fni_id,
               "CHARGE_FAILED",
               "card declined"
             )

    assert_receive {:fni_state_change, ^ref,
                    %{
                      process_instance_id: ^process_instance_id,
                      flow_node_type: :service_task,
                      terminal_state: :interrupted
                    }},
                   2_000

    assert_receive {:pi_state, ^ref,
                    %{process_instance_id: ^process_instance_id, new_state: :finished}},
                   2_000

    refute_receive {:pi_state, ^ref,
                    %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                   50

    await_process_death(process_instance_pid)
  end

  test "fail_async with unmatched code and no catch-all fatals the process instance", %{
    ref: ref
  } do
    version_id = random_id()
    ModelCache.put_new(version_id, build_async_service_with_error_ref_boundary())

    process_instance_id = random_id()

    assert {:ok, process_instance_pid} =
             start_process_instance(version_id, process_instance_id)

    service_fni_id = await_waiting_service_task(ref, process_instance_id)

    assert :ok =
             ProcessInstance.fail_async_service_task(
               process_instance_pid,
               service_fni_id,
               "UNKNOWN_CODE",
               "no matching boundary"
             )

    assert_receive {:pi_state, ^ref,
                    %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                   2_000

    await_process_death(process_instance_pid)
  end

  test "handle_complete contract error is caught by a catch-all error boundary", %{ref: ref} do
    version_id = random_id()
    ModelCache.put_new(version_id, build_async_service_with_result_contract_and_catch_all())

    process_instance_id = random_id()

    assert {:ok, process_instance_pid} =
             start_process_instance(version_id, process_instance_id)

    service_fni_id = await_waiting_service_task(ref, process_instance_id)

    assert :ok =
             ProcessInstance.finish_async_service_task(
               process_instance_pid,
               service_fni_id,
               %{"missing" => "required_ok"}
             )

    assert_receive {:pi_state, ^ref,
                    %{process_instance_id: ^process_instance_id, new_state: :finished}},
                   2_000

    refute_receive {:pi_state, ^ref,
                    %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                   50

    await_process_death(process_instance_pid)
  end

  defp start_process_instance(version_id, process_instance_id) do
    Execution.start_process_instance(%{
      process_instance_id: process_instance_id,
      process_version_id: version_id,
      payload: %{},
      identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
    })
  end

  defp await_waiting_service_task(ref, process_instance_id) do
    assert_receive {:fni_state_change, ^ref,
                    %{
                      process_instance_id: ^process_instance_id,
                      flow_node_type: :service_task,
                      new_state: :waiting,
                      flow_node_instance_id: service_fni_id
                    }},
                   2_000

    service_fni_id
  end

  defp await_process_death(pid) do
    monitor_ref = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _}, 2_000
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp subscribe_pi_events(ref) do
    test_pid = self()

    :telemetry.attach(
      "pi-state-fail-async-#{inspect(ref)}",
      [:bfw_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pi_state, ref, metadata})
      end,
      nil
    )
  end

  defp unsubscribe_pi_events(ref) do
    :telemetry.detach("pi-state-fail-async-#{inspect(ref)}")
  end

  defp subscribe_fni_events(ref) do
    test_pid = self()

    :telemetry.attach(
      "fni-state-fail-async-#{inspect(ref)}",
      [:bfw_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state_change, ref, metadata})
      end,
      nil
    )
  end

  defp unsubscribe_fni_events(ref) do
    :telemetry.detach("fni-state-fail-async-#{inspect(ref)}")
  end

  defp parking_service_task(opts) do
    %FlowNode{
      id: "ServiceTask_1",
      name: "Charge",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{
        implementation: "park-and-wait",
        result_contract: Keyword.get(opts, :result_contract)
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: ["ErrorBE_1"]
    }
  end

  defp build_async_service_with_error_ref_boundary do
    error_boundary = %FlowNode{
      id: "ErrorBE_1",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "ServiceTask_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Error{
          error_ref: "Error_ChargeFailed"
        }
      },
      outgoing: ["Flow_BE"]
    }

    wrap_definitions(
      parking_service_task([]),
      error_boundary,
      errors: [%ErrorDefinition{id: "Error_ChargeFailed", error_code: "CHARGE_FAILED"}]
    )
  end

  defp build_async_service_with_result_contract_and_catch_all do
    error_boundary = %FlowNode{
      id: "ErrorBE_1",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "ServiceTask_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Error{}
      },
      outgoing: ["Flow_BE"]
    }

    wrap_definitions(
      parking_service_task(
        result_contract: %{"type" => "object", "required" => ["transactionId"]}
      ),
      error_boundary
    )
  end

  defp wrap_definitions(activity, error_boundary, opts \\ []) do
    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    end_normal = %FlowNode{
      id: "End_Normal",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    end_error = %FlowNode{
      id: "End_Error",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: activity.id},
      %SequenceFlow{id: "Flow_2", source_ref: activity.id, target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE", source_ref: "ErrorBE_1", target_ref: "End_Error"}
    ]

    process = %BpmnProcess{
      id: "fail-async-error-boundary",
      name: "Fail Async Error Boundary",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: [start, activity, error_boundary, end_normal, end_error],
      sequence_flows: flows
    }

    %Definitions{
      processes: [process],
      errors: Keyword.get(opts, :errors, []),
      raw_xml: ""
    }
  end
end
