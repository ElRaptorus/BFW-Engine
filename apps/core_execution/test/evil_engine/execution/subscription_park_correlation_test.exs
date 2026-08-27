defmodule EvilEngine.Execution.SubscriptionParkCorrelationTest do
  @moduledoc """
  Workstream 7 — live subscription persistence after non-interrupting
  boundary re-register, Receive Task unregister on park failure, Service
  Task park-before-dispatch, and fatal correlation FEEL errors.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.MessageDefinition
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.MessagePublisher
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Execution
  alias EvilEngine.Execution.FlowNodes
  alias EvilEngine.Execution.HandlerContext
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Identity
  alias EvilEngine.Types.Token

  defmodule FailingWaitingAdapter do
    @moduledoc false
    @behaviour EvilEngine.Execution.Persistence

    alias EvilEngine.Execution.Persistence.NoOp

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
    defdelegate write_data_object(params), to: NoOp

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
    def update_flow_node_instance(_id, :update_waiting, _changes), do: {:error, :db_unavailable}

    @impl true
    def update_flow_node_instance(id, action, changes) do
      NoOp.update_flow_node_instance(id, action, changes)
    end
  end

  defmodule TrackingServiceTaskHandler do
    @moduledoc false
    @behaviour EvilEngine.Plugin.ServiceTaskHandler

    @impl true
    def handle_enter(_flow_node, _token, context) do
      Agent.update(__MODULE__, fn count -> count + 1 end)
      {:async, context.flow_node_instance_id}
    end
  end

  defmodule TrackingServiceTaskDispatch do
    @moduledoc false
    @behaviour EvilEngine.Execution.ServiceTaskDispatch

    @impl true
    def lookup_handler("track-enter"), do: {:ok, TrackingServiceTaskHandler}
    def lookup_handler(_implementation), do: {:error, :not_found}
  end

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()
    MessageSubscriptions.reset_state()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :service_task_dispatch)
      Application.delete_env(:core_execution, :persistence_retry_max_attempts)
      Application.delete_env(:core_execution, :persistence_retry_initial_backoff_ms)
      ModelCache.reset_state()
      MessageSubscriptions.reset_state()
    end)

    :ok
  end

  test "non-interrupting message boundary leaves no subscription after host completes" do
    version_id = random_id()
    message_name = "boundary-cleanup-#{version_id}"

    definitions =
      BpmnFactory.user_task_with_message_boundary(
        process_id: "message-boundary-cleanup",
        cancel_activity: false,
        message_name: message_name
      )

    ModelCache.put_new(version_id, definitions)
    MessageSubscriptions.mark_ready()

    process_instance_id = random_id()
    ref = attach_fni_telemetry()

    assert {:ok, process_instance_pid} =
             start_process_instance(version_id, process_instance_id)

    user_task_fni_id = await_waiting_user_task(ref, process_instance_id)

    wait_until(fn ->
      subscriptions_for_process_instance(process_instance_id) != []
    end)

    assert length(subscriptions_for_process_instance(process_instance_id)) == 1

    {:ok, _publish_result} =
      MessagePublisher.publish_message(%{
        name: message_name,
        payload: %{"fired" => true},
        correlation_value: nil,
        origin: %{source: "test"}
      })

    wait_until(fn ->
      [subscription] = subscriptions_for_process_instance(process_instance_id)
      subscription.subscription_id != nil
    end)

    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    assert :ok =
             ProcessInstance.finish_user_task(
               process_instance_pid,
               user_task_fni_id,
               %{},
               identity
             )

    await_process_death(process_instance_pid)

    assert subscriptions_for_process_instance(process_instance_id) == []
  end

  test "ReceiveTask unregisters the subscription when park_async fails" do
    Application.put_env(:core_execution, :persistence_adapter, FailingWaitingAdapter)
    Application.put_env(:core_execution, :persistence_retry_max_attempts, 1)
    Application.put_env(:core_execution, :persistence_retry_initial_backoff_ms, 1)

    MessageSubscriptions.reset_state()
    MessageSubscriptions.mark_ready()

    {flow_node, context} = receive_task_context()

    token = %Token{
      id: "token-1",
      process_instance_id: "pi-1",
      payload: %{},
      created_at: DateTime.utc_now()
    }

    assert {:error, :persistence_failed} =
             FlowNodes.ReceiveTask.handle_enter(flow_node, token, context)

    assert subscriptions_for_process_instance("pi-1") == []
  end

  test "ServiceTask park failure never invokes the plugin handler" do
    {:ok, _agent} = Agent.start_link(fn -> 0 end, name: TrackingServiceTaskHandler)

    on_exit(fn ->
      if Process.whereis(TrackingServiceTaskHandler) do
        Agent.stop(TrackingServiceTaskHandler)
      end
    end)

    Application.put_env(:core_execution, :persistence_adapter, FailingWaitingAdapter)
    Application.put_env(:core_execution, :persistence_retry_max_attempts, 1)
    Application.put_env(:core_execution, :persistence_retry_initial_backoff_ms, 1)
    Application.put_env(:core_execution, :service_task_dispatch, TrackingServiceTaskDispatch)

    flow_node = %FlowNode{
      id: "ServiceTask_1",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: "track-enter"},
      outgoing: ["Flow_2"]
    }

    target = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{}
    }

    sequence_flow = %SequenceFlow{
      id: "Flow_2",
      source_ref: "ServiceTask_1",
      target_ref: "End_1"
    }

    process_model = %BpmnProcess{
      id: "proc-park-order",
      flow_nodes: [flow_node, target],
      sequence_flows: [sequence_flow]
    }

    context = %HandlerContext{
      flow_node_instance_id: "fni-park-order",
      process_instance_id: "pi-park-order",
      process_model: process_model
    }

    token = %Token{
      id: "token-1",
      process_instance_id: "pi-park-order",
      payload: %{},
      created_at: DateTime.utc_now()
    }

    assert {:error, :persistence_failed} =
             FlowNodes.ServiceTask.handle_enter(flow_node, token, context)

    assert Agent.get(TrackingServiceTaskHandler, & &1) == 0
  end

  test "throw with a failing correlation retrieval expression fatals and does not publish" do
    version_id = random_id()

    definitions =
      BpmnFactory.message_throw_process(
        process_id: "correlation-fatal",
        correlation_retrieval_expression: "for x in [1] return if x then"
      )

    ModelCache.put_new(version_id, definitions)

    test_pid = self()
    telemetry_id = "message-published-#{inspect(make_ref())}"

    :telemetry.attach(
      telemetry_id,
      [:evil_engine, :message, :published],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, :message_published)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    process_instance_id = random_id()
    pi_ref = attach_pi_telemetry()

    assert {:ok, process_instance_pid} =
             start_process_instance(version_id, process_instance_id)

    assert_receive {:pi_state_change, ^pi_ref, :fatal, _}, 2_000
    refute_received :message_published
    await_process_death(process_instance_pid)
  end

  defp receive_task_context do
    message_definition = %MessageDefinition{id: "Message_1", name: "receive-park-fail"}

    flow_node = %FlowNode{
      id: "Receive_1",
      type: :receive_task,
      type_data: %FlowNodeData.ReceiveTask{message_ref: "Message_1"},
      outgoing: ["Flow_2"]
    }

    target = %FlowNode{
      id: "End_1",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{}
    }

    sequence_flow = %SequenceFlow{
      id: "Flow_2",
      source_ref: "Receive_1",
      target_ref: "End_1"
    }

    process_model = %BpmnProcess{
      id: "proc-receive-park",
      flow_nodes: [flow_node, target],
      sequence_flows: [sequence_flow]
    }

    definitions = %Definitions{
      processes: [process_model],
      messages: [message_definition],
      raw_xml: ""
    }

    context = %HandlerContext{
      flow_node_instance_id: "fni-receive-park",
      process_instance_id: "pi-1",
      process_model: process_model,
      definitions: definitions
    }

    {flow_node, context}
  end

  defp start_process_instance(version_id, process_instance_id) do
    Execution.start_process_instance(%{
      process_instance_id: process_instance_id,
      process_version_id: version_id,
      payload: %{},
      identity: %Identity{id: "test-user", roles: ["admin"], groups: []}
    })
  end

  defp attach_pi_telemetry do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "pi-ws7-#{inspect(reference)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:pi_state_change, reference, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pi-ws7-#{inspect(reference)}") end)

    reference
  end

  defp attach_fni_telemetry do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "fni-ws7-#{inspect(reference)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:fni_state_change, reference, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fni-ws7-#{inspect(reference)}") end)

    reference
  end

  defp await_waiting_user_task(ref, process_instance_id) do
    assert_receive {:fni_state_change, ^ref,
                    %{
                      process_instance_id: ^process_instance_id,
                      flow_node_type: :user_task,
                      new_state: :waiting,
                      flow_node_instance_id: user_task_fni_id
                    }},
                   2_000

    user_task_fni_id
  end

  defp await_process_death(pid) do
    monitor_ref = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _}, 2_000
  end

  defp wait_until(predicate) do
    Enum.reduce_while(1..50, :not_ready, fn _attempt, _acc ->
      if predicate.() do
        {:halt, :ok}
      else
        Process.sleep(20)
        {:cont, :not_ready}
      end
    end)
  end

  defp subscriptions_for_process_instance(process_instance_id) do
    :ets.tab2list(:evil_engine_message_subscriptions)
    |> Enum.map(fn {_key, subscription} -> subscription end)
    |> Enum.filter(fn subscription ->
      subscription.process_instance_id == process_instance_id
    end)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
