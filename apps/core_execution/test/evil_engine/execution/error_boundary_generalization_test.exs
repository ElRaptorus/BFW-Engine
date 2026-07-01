defmodule EvilEngine.Execution.ErrorBoundaryGeneralizationTest do
  @moduledoc """
  Integration tests for Phase E: Error Boundary Generalization.

  Verifies that the BoundaryAwareHandler wrapper correctly intercepts
  {:error, ...} returns from activity handlers and routes them through
  matching error boundary events at the PI level.

  Covers all five activity types the user requested:
  - ServiceTask (via failing dispatch handler)
  - ScriptTask (via missing script)
  - BusinessRuleTask (via unknown implementation)
  - CallActivity (via failing CalledElementResolver)
  - UserTask (via payload_contract violation on input)
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Types.Identity

  @version_id "test-version-error-boundary"

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()

    ref = make_ref()
    subscribe_pi_events(ref)
    subscribe_fni_events(ref)

    on_exit(fn ->
      unsubscribe_pi_events(ref)
      unsubscribe_fni_events(ref)
      Application.delete_env(:core_execution, :persistence_adapter)
      Application.delete_env(:core_execution, :service_task_dispatch)
      Application.delete_env(:core_execution, :called_element_resolver)
      ModelCache.reset_state()
    end)

    {:ok, ref: ref}
  end

  # ===================================================================
  # Mock handlers and dispatchers
  # ===================================================================

  defmodule FailingServiceTaskHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler

    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:error, {:service_execution_failed, "external API returned 500"}}
    end
  end

  defmodule StructuredErrorServiceTaskHandler do
    @behaviour EvilEngine.Execution.FlowNodeHandler

    @impl true
    def handle_enter(_flow_node, _token, _context) do
      {:error, %{error_code: "PAYMENT_DECLINED", error_message: "card expired"}}
    end
  end

  defmodule FailingServiceTaskDispatch do
    @behaviour EvilEngine.Execution.ServiceTaskDispatch

    @impl true
    def lookup_handler("always-fail"), do: {:ok, FailingServiceTaskHandler}
    def lookup_handler("structured-error"), do: {:ok, StructuredErrorServiceTaskHandler}
    def lookup_handler(_implementation), do: {:error, :not_found}
  end

  defmodule FailingCalledElementResolver do
    @behaviour EvilEngine.Execution.CalledElementResolver

    @impl true
    def resolve_latest_version(_process_model_id) do
      {:error, :process_not_found}
    end

    @impl true
    def resolve_specific_version(_process_model_id, _version) do
      {:error, :version_not_found}
    end

    @impl true
    def resolve_latest_version_for_process_id(_process_id) do
      {:error, :process_not_found}
    end
  end

  # ===================================================================
  # Generic BPMN model builder
  # ===================================================================

  defp build_activity_with_error_boundary(activity_node, opts \\ []) do
    error_code = Keyword.get(opts, :error_code, nil)
    error_message = Keyword.get(opts, :error_message, nil)
    cancel_activity = Keyword.get(opts, :cancel_activity, true)
    activity_id = activity_node.id

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    error_boundary = %FlowNode{
      id: "ErrorBE_1",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: activity_id,
        cancel_activity: cancel_activity,
        event_definition: %EventDefinition.Error{
          error_code: error_code,
          error_message: error_message
        }
      },
      outgoing: ["Flow_BE"]
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
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: activity_id},
      %SequenceFlow{id: "Flow_2", source_ref: activity_id, target_ref: "End_Normal"},
      %SequenceFlow{id: "Flow_BE", source_ref: "ErrorBE_1", target_ref: "End_Error"}
    ]

    activity_with_boundary = %{activity_node | boundary_event_refs: ["ErrorBE_1"]}

    wrap_definitions(
      [start, activity_with_boundary, error_boundary, end_normal, end_error],
      flows
    )
  end

  defp build_activity_without_boundary(activity_node) do
    activity_id = activity_node.id

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

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: activity_id},
      %SequenceFlow{id: "Flow_2", source_ref: activity_id, target_ref: "End_Normal"}
    ]

    activity_bare = %{activity_node | boundary_event_refs: []}

    wrap_definitions([start, activity_bare, end_normal], flows)
  end

  defp wrap_definitions(nodes, flows) do
    process = %BpmnProcess{
      id: "error-boundary-test",
      name: "Error Boundary Test",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: nodes,
      sequence_flows: flows
    }

    %EvilEngine.BPMN.Model.Definitions{processes: [process], raw_xml: ""}
  end

  # ===================================================================
  # Activity node builders
  # ===================================================================

  defp failing_service_task do
    %FlowNode{
      id: "ServiceTask_1",
      name: "Failing Service",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: "always-fail"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: []
    }
  end

  defp structured_error_service_task do
    %FlowNode{
      id: "ServiceTask_1",
      name: "Structured Error Service",
      type: :service_task,
      type_data: %FlowNodeData.ServiceTask{implementation: "structured-error"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: []
    }
  end

  defp failing_script_task do
    %FlowNode{
      id: "ScriptTask_1",
      name: "Failing Script",
      type: :script_task,
      type_data: %FlowNodeData.ScriptTask{script: nil, script_ref: nil},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: []
    }
  end

  defp failing_business_rule_task do
    %FlowNode{
      id: "BRT_1",
      name: "Failing Business Rule",
      type: :business_rule_task,
      type_data: %FlowNodeData.BusinessRuleTask{implementation: "unsupported_mode"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: []
    }
  end

  defp failing_call_activity do
    %FlowNode{
      id: "CA_1",
      name: "Failing Call Activity",
      type: :call_activity,
      type_data: %FlowNodeData.CallActivity{called_element: "nonexistent-process"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: []
    }
  end

  defp failing_user_task do
    %FlowNode{
      id: "UserTask_1",
      name: "Failing User Task",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{
        form_schema: %{"fields" => []},
        payload_contract: %{"type" => "object", "required" => ["mandatory_field"]}
      },
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: []
    }
  end

  # ===================================================================
  # Helpers
  # ===================================================================

  defp start_process_instance(version_id, opts) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    process_instance_options = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: version_id,
      payload: opts[:payload] || %{},
      identity: identity
    }

    Execution.start_process_instance(process_instance_options)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp await_process_death(pid) do
    monitor_ref = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _}, 2_000
  end

  defp subscribe_pi_events(ref) do
    test_pid = self()

    :telemetry.attach(
      "pi-state-ebg-#{inspect(ref)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pi_state, ref, metadata})
      end,
      nil
    )
  end

  defp unsubscribe_pi_events(ref) do
    :telemetry.detach("pi-state-ebg-#{inspect(ref)}")
  end

  defp subscribe_fni_events(ref) do
    test_pid = self()

    :telemetry.attach(
      "fni-started-ebg-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :started],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_started, ref, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "fni-state-ebg-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state_change, ref, metadata})
      end,
      nil
    )
  end

  defp unsubscribe_fni_events(ref) do
    :telemetry.detach("fni-started-ebg-#{inspect(ref)}")
    :telemetry.detach("fni-state-ebg-#{inspect(ref)}")
  end

  defp collect_fni_events(ref, event_tag, timeout \\ 100) do
    collect_fni_events_loop(ref, event_tag, timeout, [])
  end

  defp collect_fni_events_loop(ref, event_tag, timeout, accumulator) do
    receive do
      {^event_tag, ^ref, metadata} ->
        if event_tag == :fni_state_change and not Map.has_key?(metadata, :terminal_state) do
          collect_fni_events_loop(ref, event_tag, timeout, accumulator)
        else
          collect_fni_events_loop(ref, event_tag, timeout, [metadata | accumulator])
        end
    after
      timeout -> Enum.reverse(accumulator)
    end
  end

  # ===================================================================
  # ServiceTask Tests
  # ===================================================================

  describe "ServiceTask — catch-all error boundary" do
    setup do
      Application.put_env(:core_execution, :service_task_dispatch, FailingServiceTaskDispatch)
      :ok
    end

    test "PI routes through error boundary and finishes", %{ref: ref} do
      definitions = build_activity_with_error_boundary(failing_service_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end

    test "error boundary FNI is created and immediately finished", %{ref: ref} do
      definitions = build_activity_with_error_boundary(failing_service_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)

      started_events = collect_fni_events(ref, :fni_started)
      state_events = collect_fni_events(ref, :fni_state_change)

      boundary_started =
        Enum.find(started_events, fn metadata ->
          metadata.flow_node_type == :boundary_event
        end)

      assert boundary_started != nil,
             "Expected a FlowNodeInstanceStarted telemetry event for the error boundary element"

      boundary_finished =
        Enum.find(state_events, fn metadata ->
          metadata.flow_node_type == :boundary_event and metadata.terminal_state == :finished
        end)

      assert boundary_finished != nil,
             "Expected a FlowNodeInstanceFinished telemetry event for the error boundary element"

      assert boundary_started.flow_node_instance_id == boundary_finished.flow_node_instance_id
    end

    test "downstream node chains from error boundary FNI, not host activity", %{ref: ref} do
      definitions = build_activity_with_error_boundary(failing_service_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)

      started_events = collect_fni_events(ref, :fni_started)

      boundary_event =
        Enum.find(started_events, fn metadata ->
          metadata.flow_node_type == :boundary_event
        end)

      assert boundary_event != nil, "Expected a boundary event FNI to be created"

      boundary_fni_id = boundary_event.flow_node_instance_id

      end_error_events =
        Enum.filter(started_events, fn metadata ->
          metadata.flow_node_type == :end_event and
            metadata[:previous_flow_node_instance_ids] == [boundary_fni_id]
        end)

      assert length(end_error_events) == 1,
             "Expected exactly one End Event whose predecessor is the error boundary FNI " <>
               "(#{boundary_fni_id}), but found #{length(end_error_events)}"
    end
  end

  describe "ServiceTask — non-matching error boundary" do
    setup do
      Application.put_env(:core_execution, :service_task_dispatch, FailingServiceTaskDispatch)
      :ok
    end

    test "PI goes fatal when error boundary code doesn't match", %{ref: ref} do
      definitions =
        build_activity_with_error_boundary(
          failing_service_task(),
          error_code: "VERY_SPECIFIC_CODE_THAT_WONT_MATCH"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "ServiceTask — no boundary at all" do
    setup do
      Application.put_env(:core_execution, :service_task_dispatch, FailingServiceTaskDispatch)
      :ok
    end

    test "PI goes fatal when no error boundary is attached", %{ref: ref} do
      definitions = build_activity_without_boundary(failing_service_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "ServiceTask — structured error code matches specific boundary" do
    setup do
      Application.put_env(:core_execution, :service_task_dispatch, FailingServiceTaskDispatch)
      :ok
    end

    test "PI routes to boundary when structured error code matches", %{ref: ref} do
      definitions =
        build_activity_with_error_boundary(
          structured_error_service_task(),
          error_code: "PAYMENT_DECLINED"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end

    test "PI fatals when structured error code does not match boundary", %{ref: ref} do
      definitions =
        build_activity_with_error_boundary(
          structured_error_service_task(),
          error_code: "WRONG_CODE"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # ===================================================================
  # ScriptTask Tests
  # ===================================================================

  describe "ScriptTask — catch-all error boundary catches missing script" do
    test "PI routes through error boundary and finishes", %{ref: ref} do
      definitions = build_activity_with_error_boundary(failing_script_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "ScriptTask — non-matching error boundary" do
    test "PI goes fatal when boundary code doesn't match missing script error", %{ref: ref} do
      definitions =
        build_activity_with_error_boundary(
          failing_script_task(),
          error_code: "SPECIFIC_CODE"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "ScriptTask — no boundary at all" do
    test "PI goes fatal when no error boundary is attached", %{ref: ref} do
      definitions = build_activity_without_boundary(failing_script_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # ===================================================================
  # BusinessRuleTask Tests
  # ===================================================================

  describe "BusinessRuleTask — catch-all error boundary catches unknown implementation" do
    test "PI routes through error boundary and finishes", %{ref: ref} do
      definitions = build_activity_with_error_boundary(failing_business_rule_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "BusinessRuleTask — non-matching error boundary" do
    test "PI goes fatal when boundary code doesn't match", %{ref: ref} do
      definitions =
        build_activity_with_error_boundary(
          failing_business_rule_task(),
          error_code: "SPECIFIC_CODE"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "BusinessRuleTask — no boundary at all" do
    test "PI goes fatal when no error boundary is attached", %{ref: ref} do
      definitions = build_activity_without_boundary(failing_business_rule_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # ===================================================================
  # CallActivity Tests
  # ===================================================================

  describe "CallActivity — catch-all error boundary catches calledElement resolution failure" do
    setup do
      Application.put_env(:core_execution, :called_element_resolver, FailingCalledElementResolver)
      :ok
    end

    test "PI routes through error boundary and finishes", %{ref: ref} do
      definitions = build_activity_with_error_boundary(failing_call_activity())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "CallActivity — non-matching error boundary" do
    setup do
      Application.put_env(:core_execution, :called_element_resolver, FailingCalledElementResolver)
      :ok
    end

    test "PI goes fatal when boundary code doesn't match resolution error", %{ref: ref} do
      definitions =
        build_activity_with_error_boundary(
          failing_call_activity(),
          error_code: "SPECIFIC_CODE"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "CallActivity — no boundary at all" do
    setup do
      Application.put_env(:core_execution, :called_element_resolver, FailingCalledElementResolver)
      :ok
    end

    test "PI goes fatal when no error boundary is attached", %{ref: ref} do
      definitions = build_activity_without_boundary(failing_call_activity())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # ===================================================================
  # UserTask Tests
  # ===================================================================

  describe "UserTask — catch-all error boundary catches input contract violation" do
    test "PI routes through error boundary and finishes", %{ref: ref} do
      definitions = build_activity_with_error_boundary(failing_user_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "UserTask — non-matching error boundary" do
    test "PI goes fatal when boundary code doesn't match contract violation", %{ref: ref} do
      definitions =
        build_activity_with_error_boundary(
          failing_user_task(),
          error_code: "SPECIFIC_CODE"
        )

      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  describe "UserTask — no boundary at all" do
    test "PI goes fatal when no error boundary is attached", %{ref: ref} do
      definitions = build_activity_without_boundary(failing_user_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id,
                 process_instance_id: process_instance_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :fatal}},
                     2_000

      await_process_death(process_instance_pid)
    end
  end

  # ===================================================================
  # Pre-spawned error boundary cancellation on normal completion
  # ===================================================================

  describe "Pre-spawned error boundary — normal host completion" do
    test "error boundary FNI is pre-spawned then aborted when host succeeds", %{ref: ref} do
      definitions = build_activity_with_error_boundary(succeeding_task())
      ModelCache.put_new(@version_id, definitions)

      process_instance_id = random_id()

      assert {:ok, process_instance_pid} =
               start_process_instance(@version_id, process_instance_id: process_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^process_instance_id, new_state: :finished}},
                     2_000

      await_process_death(process_instance_pid)

      started_events = collect_fni_events(ref, :fni_started)
      state_events = collect_fni_events(ref, :fni_state_change)

      boundary_started =
        Enum.find(started_events, fn metadata ->
          metadata.flow_node_type == :boundary_event
        end)

      assert boundary_started != nil,
             "Expected error boundary FNI to be pre-spawned (FlowNodeInstanceStarted)"

      boundary_interrupted =
        Enum.find(state_events, fn metadata ->
          metadata.flow_node_instance_id == boundary_started.flow_node_instance_id and
            metadata.terminal_state == :interrupted
        end)

      assert boundary_interrupted != nil,
             "Expected error boundary FNI to be interrupted when host completed normally"
    end
  end

  # ===================================================================
  # Additional activity node builder for normal-completion test
  # ===================================================================

  defp succeeding_task do
    %FlowNode{
      id: "Task_Success",
      name: "Succeeding Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: []
    }
  end
end
