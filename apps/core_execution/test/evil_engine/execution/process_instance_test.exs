defmodule EvilEngine.Execution.ProcessInstanceTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Identity

  @version_id "00000000-0000-0000-0000-000000000001"

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()

    on_exit(fn ->
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
    end)
  end

  defp start_process_instance(version_id \\ @version_id, opts \\ []) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    pi_opts = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: version_id,
      start_event_id: opts[:start_event_id],
      payload: opts[:payload] || %{"input" => "data"},
      identity: identity
    }

    Execution.start_process_instance(pi_opts)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp attach_pi_telemetry(label) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "pi-#{label}-#{inspect(ref)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pi_state_change, ref, metadata.new_state, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("pi-#{label}-#{inspect(ref)}") end)

    ref
  end

  defp attach_fni_telemetry(label) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "fni-#{label}-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state_change, ref, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("fni-#{label}-#{inspect(ref)}") end)

    ref
  end

  # -------------------------------------------------------------------
  # Integration: Start → End (minimal linear)
  # -------------------------------------------------------------------

  describe "Start → End (minimal linear)" do
    test "PI runs to finished" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("linear-start-end")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end
  end

  # -------------------------------------------------------------------
  # Integration: Start → Task → End
  # -------------------------------------------------------------------

  describe "Start → Task → End (3-node linear)" do
    test "PI runs to finished" do
      definitions = BpmnFactory.linear_three_node()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("linear-three-node")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end
  end

  # -------------------------------------------------------------------
  # Integration: Start → UserTask → End
  # -------------------------------------------------------------------

  describe "Start → UserTask → End" do
    test "PI pauses at UserTask, completes after finish call" do
      definitions = BpmnFactory.user_task_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      Process.sleep(100)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)

      waiting_flow_node_instances =
        Enum.filter(state.flow_node_instance_states, fn {_id, entry} ->
          entry.state == :waiting
        end)

      assert [{flow_node_instance_id, _entry}] = waiting_flow_node_instances

      identity = %Identity{id: "finisher"}

      ref = attach_pi_telemetry("user-task-finish")

      assert :ok =
               ProcessInstance.finish_user_task(
                 process_instance_pid,
                 flow_node_instance_id,
                 %{"approved" => true},
                 identity
               )

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end

    test "finish_async_service_task on a waiting user task returns fni_not_service_task" do
      definitions = BpmnFactory.user_task_process()
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      Process.sleep(100)
      {:running, state} = :sys.get_state(process_instance_pid)

      [{flow_node_instance_id, _entry}] =
        Enum.filter(state.flow_node_instance_states, fn {_id, entry} ->
          entry.state == :waiting
        end)

      assert {:error, :fni_not_service_task} =
               ProcessInstance.finish_async_service_task(
                 process_instance_pid,
                 flow_node_instance_id,
                 %{"approved" => true}
               )
    end
  end

  # -------------------------------------------------------------------
  # Integration: UserTask contract violation → PI stays running
  # -------------------------------------------------------------------

  describe "UserTask contract violation" do
    test "PI stays running and FNI stays waiting on contract violation" do
      contract = %{
        "type" => "object",
        "required" => ["approved"],
        "properties" => %{
          "approved" => %{"type" => "boolean"}
        }
      }

      definitions = BpmnFactory.user_task_process(result_contract: contract)
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      Process.sleep(100)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)

      [{flow_node_instance_id, _}] =
        Enum.filter(state.flow_node_instance_states, fn {_id, e} -> e.state == :waiting end)

      identity = %Identity{id: "finisher"}

      assert {:error, {:contract_violation, _}} =
               ProcessInstance.finish_user_task(
                 process_instance_pid,
                 flow_node_instance_id,
                 %{"wrong" => "data"},
                 identity
               )

      Process.sleep(100)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)
      assert %{state: :waiting} = Map.get(state.flow_node_instance_states, flow_node_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # Integration: ManualTask with requireConfirmation
  # -------------------------------------------------------------------

  describe "ManualTask with requireConfirmation" do
    test "PI pauses at ManualTask, completes after finish call" do
      definitions = BpmnFactory.manual_task_process(true)
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      Process.sleep(100)
      assert Process.alive?(process_instance_pid)

      {:running, state} = :sys.get_state(process_instance_pid)

      [{flow_node_instance_id, _}] =
        Enum.filter(state.flow_node_instance_states, fn {_id, e} -> e.state == :waiting end)

      identity = %Identity{id: "user"}

      ref = attach_pi_telemetry("manual-task-finish")

      assert :ok =
               ProcessInstance.finish_user_task(
                 process_instance_pid,
                 flow_node_instance_id,
                 %{},
                 identity
               )

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end

    test "ManualTask without confirmation passes through immediately" do
      definitions = BpmnFactory.manual_task_process(false)
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("manual-task-passthrough")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end
  end

  # -------------------------------------------------------------------
  # Integration: Implicit split at runtime → PI fatal
  # -------------------------------------------------------------------

  describe "implicit split at runtime" do
    test "PI goes fatal when non-gateway has >1 outgoing" do
      definitions = BpmnFactory.implicit_split_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("implicit-split")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :fatal, meta}, 2_000
      assert meta.process_instance_id
    end
  end

  # -------------------------------------------------------------------
  # Integration: Dead end at runtime → PI fatal
  # -------------------------------------------------------------------

  describe "dead end at runtime" do
    test "PI goes fatal when non-End-Event has 0 outgoing" do
      definitions = BpmnFactory.dead_end_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("dead-end")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :fatal, meta}, 2_000
      assert meta.process_instance_id
    end
  end

  # -------------------------------------------------------------------
  # Integration: Unsupported element → PI fatal
  # -------------------------------------------------------------------

  describe "unsupported element reached" do
    test "PI goes fatal when an unsupported element is dispatched" do
      definitions = BpmnFactory.unsupported_element_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("unsupported-element")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :fatal, meta}, 2_000
      assert meta.process_instance_id
    end
  end

  # -------------------------------------------------------------------
  # Parallel branch fatal: all active/waiting FNIs must transition to fatal
  # -------------------------------------------------------------------

  describe "parallel fork with dead-end branch" do
    test "PI goes fatal when a branch has a dead end" do
      definitions = BpmnFactory.parallel_fork_with_dead_end()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("parallel-dead-end")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :fatal, meta}, 2_000
      assert meta.process_instance_id
    end
  end

  # -------------------------------------------------------------------
  # Start Event resolution
  # -------------------------------------------------------------------

  describe "Start Event resolution" do
    test "single start, no ID provided → OK" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, _pid} = start_process_instance(@version_id, start_event_id: nil)
    end

    test "single start, matching ID → OK" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, _pid} = start_process_instance(@version_id, start_event_id: "Start_1")
    end

    test "single start, wrong ID → fails to start" do
      definitions = BpmnFactory.linear_start_end()
      ModelCache.put_new(@version_id, definitions)

      assert {:error, {{:start_event_not_found, _msg}, _data}} =
               start_process_instance(@version_id, start_event_id: "Wrong_Id")
    end

    test "multiple starts, no ID → fails to start" do
      definitions = BpmnFactory.multi_start_process()
      ModelCache.put_new(@version_id, definitions)

      assert {:error, {{:ambiguous_start_event, _msg}, _data}} =
               start_process_instance(@version_id, start_event_id: nil)
    end

    test "multiple starts, valid ID → OK" do
      definitions = BpmnFactory.multi_start_process()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, _pid} = start_process_instance(@version_id, start_event_id: "Start_2")
    end

    test "multiple starts, wrong ID → fails to start" do
      definitions = BpmnFactory.multi_start_process()
      ModelCache.put_new(@version_id, definitions)

      assert {:error, {{:start_event_not_found, _msg}, _data}} =
               start_process_instance(@version_id, start_event_id: "Nonexistent_Start")
    end
  end

  # -------------------------------------------------------------------
  # Integration: XOR Gateway — split
  # -------------------------------------------------------------------

  describe "XOR split — exactly one truthy condition" do
    test "PI finishes when amount > 100 (routes to End_A)" do
      definitions = BpmnFactory.xor_split_process()
      ModelCache.put_new(@version_id, definitions)

      pi_ref = attach_pi_telemetry("xor-end-a")
      fni_ref = attach_fni_telemetry("xor-end-a-fni")

      assert {:ok, _pid} =
               start_process_instance(@version_id, payload: %{"amount" => 200})

      assert_receive {:pi_state_change, ^pi_ref, :finished, _meta}, 2_000

      end_event_finished =
        collect_fni_events(fni_ref)
        |> Enum.find(fn meta ->
          meta.flow_node_type == :end_event and meta.terminal_state == :finished
        end)

      assert end_event_finished, "expected an end event FNI to finish"
    end

    test "PI finishes when amount <= 100 (routes to End_B)" do
      definitions = BpmnFactory.xor_split_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("xor-end-b")

      assert {:ok, _pid} =
               start_process_instance(@version_id, payload: %{"amount" => 50})

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end
  end

  describe "XOR split — default flow fallback" do
    test "PI finishes via default when no conditional flow is truthy" do
      definitions = BpmnFactory.xor_split_with_default_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("xor-default")

      assert {:ok, _pid} =
               start_process_instance(@version_id, payload: %{"amount" => 5})

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end

    test "PI finishes via conditional when truthy, ignoring default" do
      definitions = BpmnFactory.xor_split_with_default_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("xor-conditional")

      assert {:ok, _pid} =
               start_process_instance(@version_id, payload: %{"amount" => 5000})

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end
  end

  describe "XOR split — ambiguous conditions cause fatal" do
    test "PI goes fatal when multiple conditions are truthy" do
      definitions = BpmnFactory.xor_split_ambiguous_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("xor-ambiguous")

      assert {:ok, _pid} =
               start_process_instance(@version_id, payload: %{"amount" => 50})

      assert_receive {:pi_state_change, ^ref, :fatal, _meta}, 2_000
    end
  end

  describe "XOR split — no matching condition causes fatal" do
    test "PI goes fatal when no condition matches and no default" do
      definitions = BpmnFactory.xor_split_no_match_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("xor-no-match")

      assert {:ok, _pid} =
               start_process_instance(@version_id, payload: %{"amount" => 1})

      assert_receive {:pi_state_change, ^ref, :fatal, _meta}, 2_000
    end
  end

  # -------------------------------------------------------------------
  # Integration: XOR Gateway — join
  # -------------------------------------------------------------------

  describe "XOR join — converging gateway" do
    test "PI finishes through a join gateway" do
      definitions = BpmnFactory.xor_join_process()
      ModelCache.put_new(@version_id, definitions)

      ref = attach_pi_telemetry("xor-join")

      assert {:ok, _pid} = start_process_instance()

      assert_receive {:pi_state_change, ^ref, :finished, _meta}, 2_000
    end
  end

  # -------------------------------------------------------------------
  # Helper to drain FNI telemetry events
  # -------------------------------------------------------------------

  defp collect_fni_events(ref, timeout \\ 200) do
    collect_fni_events(ref, timeout, [])
  end

  defp collect_fni_events(ref, timeout, acc) do
    receive do
      {:fni_state_change, ^ref, meta} ->
        if Map.has_key?(meta, :terminal_state) do
          collect_fni_events(ref, timeout, [meta | acc])
        else
          collect_fni_events(ref, timeout, acc)
        end
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
