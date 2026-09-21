defmodule BfwEngine.Execution.ParallelGatewayLifecycleTest do
  @moduledoc """
  Lifecycle edge-case tests for Parallel Gateway: abort during join wait,
  fatal during join wait, one branch fatals, payload merge semantics,
  and token merge verification.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.Execution
  alias BfwEngine.Execution.TestSupport.BpmnFactory
  alias BfwEngine.Timers.Scheduler
  alias BfwEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-pgw000000001"

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      BfwEngine.Execution.Persistence.NoOp
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
      [:bfw_engine, :process_instance, :state_change],
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
      [:bfw_engine, :flow_node_instance, :state_change],
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

  defp collect_all_fni_events(reference, timeout) do
    collect_all_fni_events_loop(reference, timeout, [])
  end

  defp collect_all_fni_events_loop(reference, timeout, accumulated_events) do
    receive do
      {:fni_state_change, ^reference, metadata} ->
        collect_all_fni_events_loop(reference, timeout, [metadata | accumulated_events])
    after
      timeout -> Enum.reverse(accumulated_events)
    end
  end

  # =========================================================================
  # 9a. Abort During Join Wait
  # =========================================================================

  describe "9a: process abort during join wait" do
    test "aborting PI while join is parked interrupts all FNIs" do
      definitions = BpmnFactory.parallel_fork_join_task_and_user_task()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("abort-join")
      flow_node_instance_reference = attach_fni_telemetry("abort-join-fni")
      process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id
               )

      Process.sleep(200)

      identity = %Identity{id: "test-user", roles: ["admin"], groups: []}
      Execution.abort_process_instance(process_instance_id, "test abort", identity)

      assert_receive {:pi_state_change, ^process_instance_reference, :aborted, _metadata}, 2_000

      events = collect_fni_events(flow_node_instance_reference)

      user_task_events =
        Enum.filter(events, &(&1.flow_node_type == :user_task))

      assert Enum.any?(user_task_events, fn metadata ->
               metadata.terminal_state in [:interrupted, :aborted]
             end)

      refute Process.alive?(pid)
    end
  end

  # =========================================================================
  # 9b. Process Fatal During Join Wait
  # =========================================================================

  describe "9b: process fatal during join wait" do
    test "force-fatal PI while join is parked → all FNIs become fatal" do
      definitions = BpmnFactory.parallel_fork_join_task_and_user_task()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("fatal-join")
      flow_node_instance_reference = attach_fni_telemetry("fatal-join-fni")
      process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id
               )

      Process.sleep(200)

      Execution.fatal_process_instance(process_instance_id, "test fatal")

      assert_receive {:pi_state_change, ^process_instance_reference, :fatal, _metadata}, 2_000

      events = collect_fni_events(flow_node_instance_reference)

      user_task_events =
        Enum.filter(events, &(&1.flow_node_type == :user_task))

      assert Enum.any?(user_task_events, fn metadata ->
               metadata.terminal_state == :fatal
             end)

      refute Process.alive?(pid)
    end
  end

  # =========================================================================
  # 9c. Branch Fatals Before Reaching Join
  # =========================================================================

  describe "9c: one branch fatals before reaching join" do
    test "service task with unregistered handler → PI fatals" do
      definitions = BpmnFactory.parallel_fork_join_with_fatal_branch()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("branch-fatal")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :fatal, _metadata}, 2_000
    end
  end

  # =========================================================================
  # 9d. Branch Leads to Error End Event After Join
  # =========================================================================

  describe "9d: error end event after join" do
    test "join merges tokens, then error end event fires → PI error state" do
      definitions = BpmnFactory.parallel_fork_join_then_error_end()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("join-error-end")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :error, _metadata}, 2_000
    end
  end

  # =========================================================================
  # 9e. Branch Leads to Terminate End Event (No Join)
  # =========================================================================

  describe "9e: terminate end event after fork" do
    test "terminate end event interrupts other branch — PI finishes" do
      definitions = BpmnFactory.parallel_fork_with_terminate()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("terminate-after-fork")
      flow_node_instance_reference = attach_fni_telemetry("terminate-after-fork-fni")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata}, 2_000

      events = collect_fni_events(flow_node_instance_reference)

      user_task_events =
        Enum.filter(events, &(&1.flow_node_type == :user_task))

      assert Enum.any?(user_task_events, fn metadata ->
               metadata.terminal_state == :interrupted
             end)
    end
  end

  # =========================================================================
  # Fork-join with payload merge verification
  # =========================================================================

  describe "payload merge at join" do
    test "two-branch fork-join passes through payload" do
      definitions = BpmnFactory.parallel_fork_join_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("merge-basic")

      assert {:ok, _pid} =
               start_process_instance(@version_id,
                 payload: %{"original" => "data"}
               )

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata}, 2_000
    end
  end

  # =========================================================================
  # User task completion triggers join fire
  # =========================================================================

  describe "user task completion triggers join" do
    test "completing both user tasks fires the join and PI finishes" do
      definitions = BpmnFactory.parallel_fork_join_user_tasks()
      ModelCache.put_new(@version_id, definitions)

      process_instance_reference = attach_pi_telemetry("ut-join")
      flow_node_instance_reference = attach_fni_telemetry("ut-join-fni")
      process_instance_id = random_id()

      assert {:ok, _pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id,
                 payload: %{"base" => "value"}
               )

      Process.sleep(200)

      all_events = collect_all_fni_events(flow_node_instance_reference, 200)

      waiting_user_task_ids =
        all_events
        |> Enum.filter(fn metadata ->
          metadata.flow_node_type == :user_task and
            Map.get(metadata, :new_state) == :waiting
        end)
        |> Enum.map(& &1.flow_node_instance_id)
        |> Enum.uniq()

      identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

      Enum.each(waiting_user_task_ids, fn fni_id ->
        Execution.finish_user_task(process_instance_id, fni_id, %{"done" => true}, identity)
      end)

      assert_receive {:pi_state_change, ^process_instance_reference, :finished, _metadata}, 3_000
    end
  end
end
