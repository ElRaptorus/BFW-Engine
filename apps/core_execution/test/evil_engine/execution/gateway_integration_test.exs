defmodule EvilEngine.Execution.GatewayIntegrationTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Timers.Scheduler
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000002"

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()
    Scheduler.reset_state()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
      Scheduler.reset_state()
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

  describe "Parallel Gateway — fork and join" do
    test "PI finishes when both branches merge at a parallel join gateway" do
      definitions = BpmnFactory.parallel_fork_join_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("parallel-fork-join")
      flow_node_instance_reference = attach_fni_telemetry("parallel-fork-join-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata},
                     2_000

      finished_flow_node_events =
        collect_fni_events(flow_node_instance_reference)
        |> Enum.filter(fn metadata -> metadata.terminal_state == :finished end)

      assert Enum.count(finished_flow_node_events, fn metadata ->
               metadata.flow_node_type == :task
             end) == 2

      assert Enum.any?(finished_flow_node_events, fn metadata ->
               metadata.flow_node_type == :end_event
             end)
    end
  end

  describe "Parallel Gateway — fork and join with three branches" do
    test "PI finishes when all three branches merge at a parallel join gateway" do
      definitions = BpmnFactory.parallel_fork_join_three_branches()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("parallel-3-branch")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata},
                     2_000
    end
  end

  describe "Parallel Gateway — nested fork-join" do
    test "PI finishes with nested parallel fork-join" do
      definitions = BpmnFactory.parallel_gateway_nested()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("parallel-nested")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata},
                     2_000
    end
  end

  describe "Parallel Gateway — mixed gateway rejection" do
    test "PI goes fatal when gateway has both multiple incoming and outgoing" do
      definitions = BpmnFactory.parallel_gateway_mixed()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("parallel-mixed")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :fatal, _metadata}, 2_000
    end
  end

  describe "Parallel Gateway — fork with dead end" do
    test "PI goes fatal when one branch ends at a dead-end task" do
      definitions = BpmnFactory.parallel_fork_end_and_dead_end_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("parallel-fork-dead-end")
      flow_node_instance_reference = attach_fni_telemetry("parallel-fork-dead-end-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :fatal, metadata}, 2_000
      assert metadata.process_instance_id

      fatal_flow_node_events =
        collect_fni_events(flow_node_instance_reference)
        |> Enum.filter(fn metadata -> metadata.terminal_state == :fatal end)

      assert Enum.any?(fatal_flow_node_events, fn metadata ->
               metadata.flow_node_type == :task
             end)
    end
  end

  describe "Event-Based Gateway — timer wins over message catch" do
    test "PI finishes when the timer catch fires before the message catch" do
      definitions = BpmnFactory.event_based_gateway_timer_message_process(time_duration: "PT0S")
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("event-based-timer-wins")
      flow_node_instance_reference = attach_fni_telemetry("event-based-timer-wins-fni")

      assert {:ok, _process_instance_pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata},
                     2_000

      flow_node_instance_events = collect_fni_events(flow_node_instance_reference)

      catch_event_outcomes =
        flow_node_instance_events
        |> Enum.filter(fn metadata -> metadata.flow_node_type == :intermediate_catch_event end)
        |> Enum.map(& &1.terminal_state)

      assert :finished in catch_event_outcomes
      assert :interrupted in catch_event_outcomes

      assert Enum.any?(flow_node_instance_events, fn metadata ->
               metadata.flow_node_type == :end_event and metadata.terminal_state == :finished
             end)
    end
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
end
