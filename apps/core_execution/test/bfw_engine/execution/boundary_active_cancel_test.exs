defmodule BfwEngine.Execution.BoundaryActiveCancelTest do
  @moduledoc """
  A boundary handler that is still `:active` (inside its `waiting` write) when
  its host completes or a sibling boundary fires is not killed: it finishes
  its enter path, releases what it registered, and exits on the `:cancel` gate.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Execution
  alias BfwEngine.Execution.ServiceReset
  alias BfwEngine.Execution.TestSupport.BpmnFactory
  alias BfwEngine.Types.Identity

  @test_process_key {__MODULE__, :test_process}

  defmodule ParkingGateAdapter do
    @moduledoc false
    @behaviour BfwEngine.Execution.Persistence

    alias BfwEngine.Execution.Persistence.NoOp

    @impl true
    defdelegate create_process_instance(attributes), to: NoOp

    @impl true
    defdelegate update_process_instance(id, changes), to: NoOp

    @impl true
    defdelegate create_flow_node_instance(attributes), to: NoOp

    @impl true
    defdelegate list_running_process_instances(opts), to: NoOp

    @impl true
    defdelegate list_flow_node_instances(process_instance_id), to: NoOp

    @impl true
    defdelegate finish_fni_with_data_objects(fni_id, fni_changes, intents), to: NoOp

    @impl true
    defdelegate list_data_objects(process_instance_id), to: NoOp

    @impl true
    defdelegate cleanup_orphaned_flow_node_instances(), to: NoOp

    @impl true
    defdelegate cleanup_orphaned_process_instances(), to: NoOp

    @impl true
    defdelegate get_process_instance_for_retry(process_instance_id), to: NoOp

    @impl true
    defdelegate list_all_flow_node_instances(process_instance_id), to: NoOp

    @impl true
    defdelegate count_all_flow_node_instances(process_instance_id), to: NoOp

    @impl true
    defdelegate get_flow_node_instance_by_id(fni_id), to: NoOp

    @impl true
    defdelegate list_child_process_instances(parent_process_instance_id), to: NoOp

    @impl true
    defdelegate patch_fni_type_properties(flow_node_instance_id, patch), to: NoOp

    @impl true
    defdelegate execute_retry_reset(process_instance_id, opts), to: NoOp

    @impl true
    defdelegate revert_retry(process_instance_id, original_state, original_finished_at), to: NoOp

    @impl true
    defdelegate create_gateway_pending_arrival(params), to: NoOp

    @impl true
    defdelegate list_gateway_pending_arrivals(process_instance_id), to: NoOp

    @impl true
    defdelegate delete_gateway_pending_arrivals_for_gateway(gateway_flow_node_instance_id),
      to: NoOp

    @impl true
    def update_flow_node_instance(
          id,
          :update_waiting,
          %{type_properties: %{"host_flow_node_instance_id" => _host}} = changes
        ) do
      test_process =
        :persistent_term.get({BfwEngine.Execution.BoundaryActiveCancelTest, :test_process})

      send(test_process, {:parking, self(), id})

      receive do
        :release -> NoOp.update_flow_node_instance(id, :update_waiting, changes)
      after
        5_000 -> {:error, :parking_gate_timeout}
      end
    end

    def update_flow_node_instance(id, action, changes) do
      NoOp.update_flow_node_instance(id, action, changes)
    end

    @impl true
    def finish_flow_node_instance(flow_node_instance_id, changes) do
      NoOp.finish_flow_node_instance(flow_node_instance_id, changes)
    end
  end

  setup do
    message_adapter = Application.get_env(:core_events, :message_persistence_adapter)
    Application.put_env(:core_events, :message_persistence_adapter, nil)
    Application.put_env(:core_execution, :persistence_adapter, ParkingGateAdapter)
    :persistent_term.put(@test_process_key, self())

    ServiceReset.bpmn_model_cache()
    ServiceReset.message_subscriptions()
    MessageSubscriptions.mark_ready()

    on_exit(fn ->
      Application.put_env(:core_events, :message_persistence_adapter, message_adapter)
      Application.delete_env(:core_execution, :persistence_adapter)
      :persistent_term.erase(@test_process_key)
      ServiceReset.bpmn_model_cache()
      ServiceReset.message_subscriptions()
    end)

    :ok
  end

  test "host completion leaves a parking message boundary alive and releases it afterwards" do
    process_instance_id = random_id()
    fni_reference = attach_fni_telemetry()

    process_instance_pid =
      start_process(process_instance_id, script: "{ instant: true }")

    assert_receive {:parking, boundary_pid, boundary_fni_id}, 2_000
    await_waiting_user_task(fni_reference, process_instance_id)

    assert Process.alive?(boundary_pid)
    assert subscriptions_for_process_instance(process_instance_id) == []

    # Stands in for a registration the handler makes after the cancel.
    {:ok, _subscription_id} =
      MessageSubscriptions.register(%{
        process_instance_id: process_instance_id,
        root_process_instance_id: process_instance_id,
        flow_node_instance_id: boundary_fni_id,
        flow_node_id: "MessageBE_1",
        message_name: "late-registration",
        expected_correlation_value: :none,
        kind: :boundary,
        via_pid: boundary_pid,
        lane_name: nil
      })

    release_and_await_exit(boundary_pid)

    assert subscriptions_for_process_instance(process_instance_id) == []
    assert Process.alive?(process_instance_pid)
  end

  test "a caught error leaves the parking message sibling alive and releases it afterwards" do
    process_instance_id = random_id()
    fni_reference = attach_fni_telemetry()
    process_instance_reference = attach_process_instance_telemetry()

    process_instance_pid =
      start_process(process_instance_id, script: "this_will_fail(", with_error_boundary: true)

    assert_receive {:parking, first_boundary_pid, _first_fni_id}, 2_000
    assert_receive {:parking, second_boundary_pid, _second_fni_id}, 2_000

    # The failing script reaches the User Task only through the Error boundary.
    await_waiting_user_task(fni_reference, process_instance_id)

    assert Process.alive?(first_boundary_pid)
    assert Process.alive?(second_boundary_pid)
    assert subscriptions_for_process_instance(process_instance_id) == []

    release_and_await_exit(first_boundary_pid)
    release_and_await_exit(second_boundary_pid)

    assert subscriptions_for_process_instance(process_instance_id) == []
    assert Process.alive?(process_instance_pid)
    refute_received {:process_instance_state_change, ^process_instance_reference, :fatal}
  end

  defp start_process(process_instance_id, factory_options) do
    version_id = random_id()
    message_name = "active-boundary-#{version_id}"

    definitions =
      BpmnFactory.script_task_with_message_boundary(
        [process_id: "active-boundary-cancel", message_name: message_name] ++ factory_options
      )

    ModelCache.put_new(version_id, definitions)

    {:ok, process_instance_pid} =
      Execution.start_process_instance(%{
        process_instance_id: process_instance_id,
        process_version_id: version_id,
        payload: %{},
        identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
      })

    process_instance_pid
  end

  defp release_and_await_exit(boundary_pid) do
    monitor_reference = Process.monitor(boundary_pid)
    send(boundary_pid, :release)
    assert_receive {:DOWN, ^monitor_reference, :process, ^boundary_pid, :normal}, 2_000
  end

  defp attach_fni_telemetry do
    test_process = self()
    reference = make_ref()
    handler_id = "active-boundary-fni-#{inspect(reference)}"

    :telemetry.attach(
      handler_id,
      [:bfw_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:fni_state_change, reference, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    reference
  end

  defp attach_process_instance_telemetry do
    test_process = self()
    reference = make_ref()
    handler_id = "active-boundary-pi-#{inspect(reference)}"

    :telemetry.attach(
      handler_id,
      [:bfw_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:process_instance_state_change, reference, metadata.new_state})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    reference
  end

  defp await_waiting_user_task(reference, process_instance_id) do
    assert_receive {:fni_state_change, ^reference,
                    %{
                      process_instance_id: ^process_instance_id,
                      flow_node_type: :user_task,
                      new_state: :waiting
                    }},
                   2_000
  end

  defp subscriptions_for_process_instance(process_instance_id) do
    :ets.tab2list(:bfw_engine_message_subscriptions)
    |> Enum.map(fn {_key, subscription} -> subscription end)
    |> Enum.filter(&(&1.process_instance_id == process_instance_id))
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
