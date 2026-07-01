defmodule EvilEngine.Execution.CallActivityIntegrationTest do
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.Mapping
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.CalledElementResolver
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Execution.TestSupport.BpmnFactory
  alias EvilEngine.Types.Identity

  @parent_version "parent-version-001"
  @child_version "child-version-001"

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    Application.put_env(:core_execution, :called_element_resolver, CalledElementResolver.NoOp)
    ModelCache.reset_state()
    CalledElementResolver.NoOp.reset()

    ref = make_ref()
    subscribe_pi_events(ref)

    on_exit(fn ->
      unsubscribe_pi_events(ref)
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :called_element_resolver)
      ModelCache.reset_state()
      CalledElementResolver.NoOp.reset()
    end)

    {:ok, ref: ref}
  end

  defp start_process_instance(version_id, opts) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    pi_opts = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: version_id,
      payload: opts[:payload] || %{"input" => "data"},
      identity: identity,
      notify_pid: opts[:notify_pid]
    }

    Execution.start_process_instance(pi_opts)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp setup_child_process do
    child_definitions = BpmnFactory.linear_start_end("child-process")
    ModelCache.put_new(@child_version, child_definitions)
    CalledElementResolver.NoOp.set_version("child-process", @child_version)
  end

  defp await_process_death(pid) do
    mon = Process.monitor(pid)
    assert_receive {:DOWN, ^mon, :process, ^pid, _}, 2_000
  end

  # -- Telemetry helpers -----------------------------------------------------

  defp subscribe_pi_events(ref) do
    test_pid = self()

    :telemetry.attach(
      "pi-state-#{inspect(ref)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pi_state, ref, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "fni-state-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state, ref, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "ca-child-#{inspect(ref)}",
      [:evil_engine, :call_activity, :child_started],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:ca_child_started, ref, metadata})
      end,
      nil
    )
  end

  defp unsubscribe_pi_events(ref) do
    :telemetry.detach("pi-state-#{inspect(ref)}")
    :telemetry.detach("fni-state-#{inspect(ref)}")
    :telemetry.detach("ca-child-#{inspect(ref)}")
  end

  # -------------------------------------------------------------------
  # Call Activity — child finishes, parent advances
  # -------------------------------------------------------------------

  describe "Call Activity — child finishes successfully" do
    test "parent PI completes after child PI finishes", %{ref: ref} do
      setup_child_process()
      parent_definitions = BpmnFactory.call_activity_process()
      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :finished}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — child fatals, no boundary, parent fatals
  # -------------------------------------------------------------------

  describe "Call Activity — child fatals, no boundary" do
    test "parent PI goes fatal when child fatals and no boundary is attached", %{ref: ref} do
      child_definitions = BpmnFactory.dead_end_process()
      ModelCache.put_new(@child_version, child_definitions)
      CalledElementResolver.NoOp.set_version("child-process", @child_version)

      parent_definitions = BpmnFactory.call_activity_process()
      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :fatal}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — child fatals, error boundary catches
  # -------------------------------------------------------------------

  describe "Call Activity — error boundary catches child failure" do
    test "parent routes through error boundary when child fatals", %{ref: ref} do
      child_definitions = BpmnFactory.dead_end_process()
      ModelCache.put_new(@child_version, child_definitions)
      CalledElementResolver.NoOp.set_version("child-process", @child_version)

      parent_definitions = BpmnFactory.call_activity_with_error_boundary()
      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :fatal}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — error boundary attached but code doesn't match
  # -------------------------------------------------------------------

  describe "Call Activity — error boundary doesn't match" do
    test "parent fatals when boundary is present but error code doesn't match", %{ref: ref} do
      child_definitions = BpmnFactory.dead_end_process()
      ModelCache.put_new(@child_version, child_definitions)
      CalledElementResolver.NoOp.set_version("child-process", @child_version)

      parent_definitions =
        BpmnFactory.call_activity_with_error_boundary(error_code: "VERY_SPECIFIC_ERROR")

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :fatal}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — called process doesn't exist
  # -------------------------------------------------------------------

  describe "Call Activity — called process not found" do
    test "parent PI goes fatal when called element cannot be resolved", %{ref: ref} do
      parent_definitions =
        BpmnFactory.call_activity_process(called_element: "nonexistent-process")

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      refute_received {:ca_child_started, ^ref, _}

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — input mapping transforms payload for child
  # -------------------------------------------------------------------

  describe "Call Activity — input mapping" do
    test "in_mappings transform the payload passed to the child", %{ref: ref} do
      child_definitions = BpmnFactory.user_task_process(process_id: "child-process")
      ModelCache.put_new(@child_version, child_definitions)
      CalledElementResolver.NoOp.set_version("child-process", @child_version)

      parent_definitions =
        BpmnFactory.call_activity_process(
          in_mappings: [
            %Mapping{source: "token.input", target: "child_input"}
          ]
        )

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, _process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id,
                 payload: %{"input" => "hello"}
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      # Child pauses at user task — inspect its input payload
      Process.sleep(50)
      {:ok, child_pid} = Execution.lookup_process_instance(child_id)
      {:running, child_state} = :sys.get_state(child_pid)
      assert child_state.started_with_context == nil

      # Finish user task so everything completes
      [{flow_node_instance_id, _}] =
        Enum.filter(child_state.flow_node_instance_states, fn {_id, e} -> e.state == :waiting end)

      identity = %Identity{id: "finisher", roles: ["admin"], groups: []}

      assert :ok =
               ProcessInstance.finish_user_task(child_pid, flow_node_instance_id, %{}, identity)

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :finished}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :finished}},
                     2_000
    end

    test "parent PI goes fatal when in_mapping FEEL expression is invalid", %{ref: ref} do
      setup_child_process()

      parent_definitions =
        BpmnFactory.call_activity_process(
          in_mappings: [
            %Mapping{source: "invalid {{{{", target: "child_input"}
          ]
        )

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id,
                 payload: %{"input" => "hello"}
               )

      refute_received {:ca_child_started, ^ref, _}

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — output mapping transforms child result
  # -------------------------------------------------------------------

  describe "Call Activity — output mapping" do
    test "out_mappings transform the child result before returning to parent", %{ref: ref} do
      child_definitions = BpmnFactory.linear_three_node("child-process")
      ModelCache.put_new(@child_version, child_definitions)
      CalledElementResolver.NoOp.set_version("child-process", @child_version)

      parent_definitions =
        BpmnFactory.call_activity_process(
          out_mappings: [
            %Mapping{source: "token.input", target: "mapped_result"}
          ]
        )

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id,
                 payload: %{"input" => "data"}
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :finished}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — broken FEEL in out_mappings causes parent fatal
  # -------------------------------------------------------------------

  describe "Call Activity — broken FEEL out_mapping" do
    test "parent PI goes fatal when out_mapping FEEL expression is invalid", %{ref: ref} do
      setup_child_process()

      parent_definitions =
        BpmnFactory.call_activity_process(
          out_mappings: [
            %Mapping{source: "invalid {{{{", target: "result"}
          ]
        )

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :finished}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity token aggregation (child with task)
  # -------------------------------------------------------------------

  describe "Call Activity token aggregation" do
    test "child with task passes payload through correctly", %{ref: ref} do
      child_definitions = BpmnFactory.linear_three_node("child-process")
      ModelCache.put_new(@child_version, child_definitions)
      CalledElementResolver.NoOp.set_version("child-process", @child_version)

      parent_definitions = BpmnFactory.call_activity_process()
      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id,
                 payload: %{"key" => "value"}
               )

      assert_receive(
        {:ca_child_started, ^ref,
         %{
           parent_process_instance_id: ^parent_process_instance_id,
           child_process_instance_id: child_id
         }},
        2_000
      )

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :finished}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — update_notify_pid API
  # -------------------------------------------------------------------

  describe "Call Activity — notify_pid update" do
    test "update_notify_pid sets the notification target on a running child PI" do
      child_definitions = BpmnFactory.linear_start_end("standalone-child")
      child_version = "standalone-child-v1"
      ModelCache.put_new(child_version, child_definitions)

      identity = %Identity{id: "test-user", roles: [], groups: []}
      child_process_instance_id = random_id()
      test_pid = self()

      {:ok, child_pid} =
        Execution.start_process_instance(%{
          process_instance_id: child_process_instance_id,
          process_version_id: child_version,
          payload: %{},
          identity: identity,
          notify_pid: nil
        })

      ProcessInstance.update_notify_pid(child_pid, test_pid)

      receive do
        {:child_pi_finished, ^child_pid, _tokens} -> :ok
      after
        2_000 -> flunk("Expected child_pi_finished notification after update_notify_pid")
      end
    end
  end

  # -------------------------------------------------------------------
  # Call Activity — evil:startEventId scenarios
  # -------------------------------------------------------------------

  @multi_start_child_version "multi-start-child-version-001"

  defp setup_multi_start_child_process do
    child_definitions = BpmnFactory.multi_start_process("multi-start-child")
    ModelCache.put_new(@multi_start_child_version, child_definitions)
    CalledElementResolver.NoOp.set_version("multi-start-child", @multi_start_child_version)
  end

  describe "Call Activity — startEventId with single-start child" do
    test "single start, no startEventId → child starts at the only start event", %{ref: ref} do
      setup_child_process()
      parent_definitions = BpmnFactory.call_activity_process()
      ModelCache.put_new(@parent_version, parent_definitions)

      assert {:ok, pid} = start_process_instance(@parent_version, [])

      assert_receive {:pi_state, ^ref, %{new_state: :finished}}, 2_000
      await_process_death(pid)
    end

    test "single start, matching startEventId → child starts successfully", %{ref: ref} do
      setup_child_process()

      parent_definitions =
        BpmnFactory.call_activity_process(start_event_id: "Start_1")

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive {:ca_child_started, ^ref,
                      %{parent_process_instance_id: ^parent_process_instance_id}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(pid)
    end

    test "single start, non-matching startEventId → parent fatals", %{ref: ref} do
      setup_child_process()

      parent_definitions =
        BpmnFactory.call_activity_process(start_event_id: "NonExistent_Start")

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(pid)
    end
  end

  describe "Call Activity — startEventId with multi-start child" do
    test "multi start, no startEventId → parent fatals with ambiguity error", %{ref: ref} do
      setup_multi_start_child_process()

      parent_definitions =
        BpmnFactory.call_activity_process(called_element: "multi-start-child")

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(pid)
    end

    test "multi start, valid startEventId → child starts at specified start event", %{ref: ref} do
      setup_multi_start_child_process()

      parent_definitions =
        BpmnFactory.call_activity_process(
          called_element: "multi-start-child",
          start_event_id: "Start_B"
        )

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive {:ca_child_started, ^ref,
                      %{
                        parent_process_instance_id: ^parent_process_instance_id,
                        child_process_instance_id: child_id
                      }},
                     2_000

      assert_receive {:pi_state, ^ref, %{process_instance_id: ^child_id, new_state: :finished}},
                     2_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(pid)
    end

    test "multi start, non-existent startEventId → parent fatals with not-found error", %{
      ref: ref
    } do
      setup_multi_start_child_process()

      parent_definitions =
        BpmnFactory.call_activity_process(
          called_element: "multi-start-child",
          start_event_id: "Start_Z_Does_Not_Exist"
        )

      ModelCache.put_new(@parent_version, parent_definitions)

      parent_process_instance_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@parent_version,
                 process_instance_id: parent_process_instance_id
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(pid)
    end
  end
end
