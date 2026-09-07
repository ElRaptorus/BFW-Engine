defmodule EvilEngine.Execution.EventBasedGatewayTest do
  @moduledoc """
  Comprehensive tests for Event-Based Gateway: handler correctness,
  orchestrator sibling cancellation, race scenarios, lifecycle edge cases,
  and Receive Task support.
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Events.MessagePublisher
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalPublisher
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Execution
  alias EvilEngine.Execution.ProcessInstance.EventBasedGatewayOrchestrator
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Execution.TestSupport.SchedulerWait
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-ebg000000001"

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()
    Scheduler.reset_state()
    MessageSubscriptions.reset_state()
    SignalSubscriptions.reset_state()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
      Scheduler.reset_state()
      MessageSubscriptions.reset_state()
      SignalSubscriptions.reset_state()
    end)
  end

  defp start_process_instance(version_id \\ @version_id, opts \\ []) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    process_instance_options = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: version_id,
      start_event_id: opts[:start_event_id],
      payload: opts[:payload] || %{},
      identity: identity
    }

    Execution.start_process_instance(process_instance_options)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp attach_pi_telemetry(label) do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "pi-#{label}-#{inspect(reference)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:pi_state_change, reference, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pi-#{label}-#{inspect(reference)}") end)

    reference
  end

  defp attach_fni_telemetry(label) do
    test_process = self()
    reference = make_ref()

    :telemetry.attach(
      "fni-#{label}-#{inspect(reference)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_process, {:fni_state_change, reference, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fni-#{label}-#{inspect(reference)}") end)

    reference
  end

  defp collect_fni_events(reference, timeout \\ 200) do
    collect_fni_events(reference, timeout, [])
  end

  defp collect_fni_events(reference, timeout, accumulated_events) do
    receive do
      {:fni_state_change, ^reference, metadata} ->
        if Map.has_key?(metadata, :terminal_state) do
          collect_fni_events(reference, timeout, [metadata | accumulated_events])
        else
          collect_fni_events(reference, timeout, accumulated_events)
        end
    after
      timeout -> Enum.reverse(accumulated_events)
    end
  end

  defp publish_message(message_name, payload \\ %{}, correlation \\ nil) do
    MessagePublisher.publish_message(%{
      name: message_name,
      payload: payload,
      correlation_value: correlation,
      origin: %{source: "test"}
    })
  end

  defp publish_signal(signal_name) do
    SignalPublisher.publish_signal(%{
      name: signal_name,
      origin: %{source: "test"}
    })
  end

  # ===========================================================================
  # Step 4: Handler + Orchestrator tests
  # ===========================================================================

  describe "handler — fork dispatches all outgoing targets" do
    test "timer + message: both catches are dispatched, timer PT0S wins" do
      definitions =
        BpmnFactory.event_based_gateway_timer_message_process(time_duration: "PT0S")

      ModelCache.put_new(@version_id, definitions)

      pi_ref = attach_pi_telemetry("fork-timer-message")
      fni_ref = attach_fni_telemetry("fork-timer-message-fni")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 2_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, fn metadata ->
          metadata.flow_node_type == :intermediate_catch_event
        end)

      catch_terminal_states = Enum.map(catch_events, & &1.terminal_state)
      assert :finished in catch_terminal_states
      assert :interrupted in catch_terminal_states
    end

    test "handler rejects converging gateway (>1 incoming) — PI fatals" do
      definitions =
        BpmnFactory.event_based_gateway_converging_process()

      ModelCache.put_new(@version_id, definitions)

      pi_ref = attach_pi_telemetry("converging-reject")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^pi_ref, :fatal, _}, 2_000
    end

    test "handler rejects dead-end gateway (0 outgoing) — PI fatals" do
      definitions =
        BpmnFactory.event_based_gateway_dead_end_process()

      ModelCache.put_new(@version_id, definitions)

      pi_ref = attach_pi_telemetry("dead-end")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^pi_ref, :fatal, _}, 2_000
    end
  end

  # ===========================================================================
  # Step 5: Integration tests — race scenarios
  # ===========================================================================

  describe "message wins over timer" do
    test "publishing message before timer fires makes message catch win" do
      definitions =
        BpmnFactory.event_based_gateway_timer_message_process(
          time_duration: "PT30S",
          message_name: "msg-wins"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()

      pi_ref = attach_pi_telemetry("message-wins")
      fni_ref = attach_fni_telemetry("message-wins-fni")

      assert {:ok, _pid} = start_process_instance()

      assert :ok = await_message_subscription("msg-wins")
      publish_message("msg-wins")

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      catch_terminal_states = Enum.map(catch_events, & &1.terminal_state)
      assert :finished in catch_terminal_states
      assert :interrupted in catch_terminal_states
    end
  end

  describe "signal wins over timer" do
    test "publishing signal before timer fires makes signal catch win" do
      definitions =
        BpmnFactory.event_based_gateway_signal_timer_process(
          time_duration: "PT30S",
          signal_name: "sig-wins"
        )

      ModelCache.put_new(@version_id, definitions)
      SignalSubscriptions.mark_ready()

      pi_ref = attach_pi_telemetry("signal-wins")
      fni_ref = attach_fni_telemetry("signal-wins-fni")

      assert {:ok, _pid} = start_process_instance()

      assert :ok = await_signal_subscription("sig-wins")
      publish_signal("sig-wins")

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      catch_terminal_states = Enum.map(catch_events, & &1.terminal_state)
      assert :finished in catch_terminal_states
      assert :interrupted in catch_terminal_states
    end
  end

  describe "three-way race" do
    test "timer PT0S wins, two other catches aborted" do
      definitions =
        BpmnFactory.event_based_gateway_three_branches_process(time_duration: "PT0S")

      ModelCache.put_new(@version_id, definitions)

      pi_ref = attach_pi_telemetry("three-way")
      fni_ref = attach_fni_telemetry("three-way-fni")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 2_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      finished_count =
        Enum.count(catch_events, &(&1.terminal_state == :finished))

      interrupted_count =
        Enum.count(catch_events, &(&1.terminal_state == :interrupted))

      assert finished_count == 1
      assert interrupted_count == 2
    end
  end

  describe "Receive Task wins" do
    test "Receive Task receives message, timer catch cancelled" do
      definitions =
        BpmnFactory.event_based_gateway_receive_task_timer_process(
          time_duration: "PT30S",
          message_name: "recv-wins"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()

      pi_ref = attach_pi_telemetry("recv-wins")
      fni_ref = attach_fni_telemetry("recv-wins-fni")

      assert {:ok, _pid} = start_process_instance()

      assert :ok = await_message_subscription("recv-wins")
      publish_message("recv-wins")

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000

      events = collect_fni_events(fni_ref)

      recv_task_events =
        Enum.filter(events, &(&1.flow_node_type == :receive_task))

      timer_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      assert Enum.any?(recv_task_events, &(&1.terminal_state == :finished))
      assert Enum.any?(timer_events, &(&1.terminal_state == :interrupted))
    end
  end

  # ===========================================================================
  # Step 6: Lifecycle edge-case tests
  # ===========================================================================

  describe "abort during EBG wait" do
    test "aborting PI while catches are waiting interrupts all catches" do
      definitions =
        BpmnFactory.event_based_gateway_timer_message_process(
          time_duration: "PT30S",
          message_name: "abort-test"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()

      pi_ref = attach_pi_telemetry("abort-wait")
      fni_ref = attach_fni_telemetry("abort-wait-fni")
      process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id
               )

      assert :ok = await_message_subscription("abort-test")
      assert :ok = SchedulerWait.wait_until_armed(1)

      identity = %Identity{id: "test-user", roles: ["admin"], groups: []}
      Execution.abort_process_instance(process_instance_id, "test abort", identity)

      assert_receive {:pi_state_change, ^pi_ref, :aborted, _}, 2_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, fn metadata ->
          metadata.flow_node_type in [:intermediate_catch_event, :receive_task]
        end)

      terminal_states = Enum.map(catch_events, & &1.terminal_state)
      assert Enum.all?(terminal_states, &(&1 in [:interrupted, :aborted]))

      refute Process.alive?(pid)
    end
  end

  describe "fatal during EBG wait" do
    test "force-fatal PI while catches are waiting → all catches become fatal" do
      definitions =
        BpmnFactory.event_based_gateway_timer_message_process(
          time_duration: "PT30S",
          message_name: "fatal-test"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()

      pi_ref = attach_pi_telemetry("fatal-wait")
      fni_ref = attach_fni_telemetry("fatal-wait-fni")
      process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id
               )

      assert :ok = await_message_subscription("fatal-test")
      assert :ok = SchedulerWait.wait_until_armed(1)

      Execution.fatal_process_instance(process_instance_id, %{reason: :test_forced_fatal})

      assert_receive {:pi_state_change, ^pi_ref, :fatal, _}, 2_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, fn metadata ->
          metadata.flow_node_type in [:intermediate_catch_event, :receive_task]
        end)

      terminal_states = Enum.map(catch_events, & &1.terminal_state)
      assert Enum.all?(terminal_states, &(&1 in [:fatal, :interrupted, :aborted]))

      refute Process.alive?(pid)
    end
  end

  describe "simultaneous event race (stale guard)" do
    test "timer PT0S + pending message — first wins, second dropped" do
      definitions =
        BpmnFactory.event_based_gateway_timer_message_process(
          time_duration: "PT0S",
          message_name: "race-msg"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()

      publish_message("race-msg")

      pi_ref = attach_pi_telemetry("race-simultaneous")
      fni_ref = attach_fni_telemetry("race-simultaneous-fni")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      finished_count = Enum.count(catch_events, &(&1.terminal_state == :finished))
      interrupted_count = Enum.count(catch_events, &(&1.terminal_state == :interrupted))

      assert finished_count == 1
      assert interrupted_count == 1
    end
  end

  describe "message wins over signal (uses message_signal factory)" do
    test "publishing message makes message catch win, signal catch aborted" do
      definitions =
        BpmnFactory.event_based_gateway_message_signal_process(
          message_name: "msg-over-sig",
          signal_name: "sig-over-msg"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()
      SignalSubscriptions.mark_ready()

      pi_ref = attach_pi_telemetry("msg-over-sig")
      fni_ref = attach_fni_telemetry("msg-over-sig-fni")

      assert {:ok, _pid} = start_process_instance()

      assert :ok = await_message_subscription("msg-over-sig")
      publish_message("msg-over-sig")

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      catch_terminal_states = Enum.map(catch_events, & &1.terminal_state)
      assert :finished in catch_terminal_states
      assert :interrupted in catch_terminal_states
    end
  end

  describe "dual receive tasks (uses receive_task factory)" do
    test "publishing message A makes ReceiveTask A win, ReceiveTask B aborted" do
      definitions =
        BpmnFactory.event_based_gateway_receive_task_process(
          message_name_a: "recv-a",
          message_name_b: "recv-b"
        )

      ModelCache.put_new(@version_id, definitions)
      MessageSubscriptions.mark_ready()

      pi_ref = attach_pi_telemetry("dual-recv")
      fni_ref = attach_fni_telemetry("dual-recv-fni")

      assert {:ok, _pid} = start_process_instance()

      assert :ok = await_message_subscription("recv-a")
      publish_message("recv-a")

      assert_receive {:pi_state_change, ^pi_ref, :finished, _}, 3_000

      events = collect_fni_events(fni_ref)

      recv_events =
        Enum.filter(events, &(&1.flow_node_type == :receive_task))

      assert Enum.any?(recv_events, &(&1.terminal_state == :finished))
      assert Enum.any?(recv_events, &(&1.terminal_state == :interrupted))
    end
  end

  describe "winning catch leads to Error End Event" do
    test "timer wins → Error End Event → PI state :error, message catch aborted" do
      definitions =
        BpmnFactory.event_based_gateway_timer_to_error_end_process(time_duration: "PT0S")

      ModelCache.put_new(@version_id, definitions)

      pi_ref = attach_pi_telemetry("error-end")
      fni_ref = attach_fni_telemetry("error-end-fni")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^pi_ref, :error, _}, 2_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      catch_terminal_states = Enum.map(catch_events, & &1.terminal_state)

      assert :finished in catch_terminal_states

      aborted_or_interrupted =
        Enum.filter(catch_events, &(&1.terminal_state in [:aborted, :interrupted]))

      assert aborted_or_interrupted != []
    end
  end

  describe "winning catch leads to fatal successor" do
    test "timer wins → fatal ScriptTask → PI fatals, message catch aborted" do
      definitions =
        BpmnFactory.event_based_gateway_timer_to_fatal_script_process(time_duration: "PT0S")

      ModelCache.put_new(@version_id, definitions)

      pi_ref = attach_pi_telemetry("fatal-successor")
      fni_ref = attach_fni_telemetry("fatal-successor-fni")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^pi_ref, :fatal, _}, 2_000

      events = collect_fni_events(fni_ref)

      catch_events =
        Enum.filter(events, &(&1.flow_node_type == :intermediate_catch_event))

      script_events =
        Enum.filter(events, &(&1.flow_node_type == :script_task))

      catch_terminal_states = Enum.map(catch_events, & &1.terminal_state)
      assert :finished in catch_terminal_states

      aborted_or_interrupted =
        Enum.filter(catch_events, &(&1.terminal_state in [:aborted, :interrupted]))

      assert aborted_or_interrupted != []
      assert Enum.any?(script_events, &(&1.terminal_state == :fatal))
    end
  end

  describe "orchestrator — defer interrupt of :active siblings" do
    test "does not kill an :active sibling; stamps ebg_pending_cancel" do
      dummy = spawn(fn -> receive do: (:stop -> :ok) end)
      data = ebg_orchestrator_fixture(dummy, :active)

      updated =
        EventBasedGatewayOrchestrator.cancel_sibling_catch_flow_node_instances(data, "fni-timer")

      sibling = updated.flow_node_instance_states["fni-msg"]
      assert sibling.state == :active
      assert sibling.pid == dummy
      assert sibling.type_properties.ebg_pending_cancel == true
      assert Process.alive?(dummy)

      finalized = EventBasedGatewayOrchestrator.interrupt_pending_loser(updated, "fni-msg")
      assert finalized.flow_node_instance_states["fni-msg"].state == :interrupted
      refute Process.alive?(dummy)
    end

    test "waiting sibling is interrupted immediately" do
      dummy = spawn(fn -> receive do: (:stop -> :ok) end)
      data = ebg_orchestrator_fixture(dummy, :waiting)

      updated =
        EventBasedGatewayOrchestrator.cancel_sibling_catch_flow_node_instances(data, "fni-timer")

      assert updated.flow_node_instance_states["fni-msg"].state == :interrupted
      refute Process.alive?(dummy)
    end

    test "take_ready_deferred_dispatch waits while a sibling is still :active" do
      dummy = spawn(fn -> receive do: (:stop -> :ok) end)
      data = ebg_orchestrator_fixture(dummy, :active)

      stamped =
        EventBasedGatewayOrchestrator.cancel_sibling_catch_flow_node_instances(data, "fni-timer")

      deferred =
        EventBasedGatewayOrchestrator.defer_successor_dispatch(
          stamped,
          "fni-timer",
          %{"order" => 1},
          ["ErrorEnd_1"]
        )

      assert EventBasedGatewayOrchestrator.has_active_pending_cancel_siblings?(deferred)

      {still_waiting, nil_dispatch} =
        EventBasedGatewayOrchestrator.take_ready_deferred_dispatch(deferred)

      assert nil_dispatch == nil
      assert still_waiting.event_based_gateway_deferred_dispatch != nil

      interrupted =
        EventBasedGatewayOrchestrator.interrupt_pending_loser(still_waiting, "fni-msg")

      {flushed, ready} = EventBasedGatewayOrchestrator.take_ready_deferred_dispatch(interrupted)
      assert ready.winning_flow_node_instance_id == "fni-timer"
      assert ready.next_flow_node_ids == ["ErrorEnd_1"]
      assert flushed.event_based_gateway_deferred_dispatch == nil
    end
  end

  defp ebg_orchestrator_fixture(sibling_pid, sibling_state) do
    process_model = %{
      flow_nodes: [
        %FlowNode{
          id: "EBG_1",
          type: :event_based_gateway,
          type_data: %FlowNodeData.EventBasedGateway{}
        },
        %FlowNode{
          id: "TimerCatch_1",
          type: :intermediate_catch_event,
          type_data: %FlowNodeData.IntermediateCatchEvent{}
        },
        %FlowNode{
          id: "MsgCatch_1",
          type: :task,
          type_data: %FlowNodeData.Task{}
        }
      ],
      lanes: []
    }

    %{
      process_instance_id: "pi-ebg",
      root_process_instance_id: "pi-ebg",
      process_model: process_model,
      conditional_waiters: %{},
      flow_node_instance_states: %{
        "fni-gw" => %{
          flow_node_id: "EBG_1",
          state: :finished,
          previous_flow_node_instance_ids: [],
          pid: nil,
          type_properties: %{}
        },
        "fni-timer" => %{
          flow_node_id: "TimerCatch_1",
          state: :finished,
          previous_flow_node_instance_ids: ["fni-gw"],
          pid: nil,
          type_properties: %{}
        },
        "fni-msg" => %{
          flow_node_id: "MsgCatch_1",
          state: sibling_state,
          previous_flow_node_instance_ids: ["fni-gw"],
          pid: sibling_pid,
          type_properties: %{}
        }
      }
    }
  end

  defp await_message_subscription(message_name, timeout \\ 2_000) do
    case SchedulerWait.wait_until(
           fn -> MessageSubscriptions.has_subscriptions_for_message?(message_name) end,
           timeout
         ) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk(
          "message subscription for #{inspect(message_name)} was not registered within #{timeout}ms"
        )
    end
  end

  defp await_signal_subscription(signal_name, timeout \\ 2_000) do
    case SchedulerWait.wait_until(
           fn -> SignalSubscriptions.lookup(signal_name) != [] end,
           timeout
         ) do
      :ok ->
        :ok

      {:error, :timeout} ->
        flunk(
          "signal subscription for #{inspect(signal_name)} was not registered within #{timeout}ms"
        )
    end
  end
end
