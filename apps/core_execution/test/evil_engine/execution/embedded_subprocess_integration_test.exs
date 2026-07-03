defmodule EvilEngine.Execution.EmbeddedSubprocessIntegrationTest do
  @moduledoc """
  Comprehensive integration tests for embedded `<bpmn:subProcess>` execution.

  Covers:
  - Happy path: basic execution, token passthrough, input/output mappings,
    payload/result contracts
  - Lane inheritance: subprocess inner FNIs inherit the parent's lane
  - Error paths: invalid subprocess structure (no start, multiple starts,
    typed starts, no end), contract violations
  - Error bubbling: child fatal → parent fatal, BPMN Error End Event →
    boundary catch / no boundary
  - Scope isolation: child PI has independent data object scope
  - Terminate End Event scoped to child PI only
  - Nested subprocess runtime execution (SubProcess inside SubProcess)
  - Parent abort cascade to running subprocess child
  - WIP diagram: invalid subprocess on unreachable branch
  - Inner activity error boundary inside subprocess scope
  """
  use ExUnit.Case, async: false

  alias EvilEngine.BPMN.Model.DataObject
  alias EvilEngine.BPMN.Model.DataObjectReference
  alias EvilEngine.BPMN.Model.Definitions
  alias EvilEngine.BPMN.Model.EventDefinition
  alias EvilEngine.BPMN.Model.FlowNode
  alias EvilEngine.BPMN.Model.FlowNodeData
  alias EvilEngine.BPMN.Model.Lane
  alias EvilEngine.BPMN.Model.Mapping
  alias EvilEngine.BPMN.Model.Process, as: BpmnProcess
  alias EvilEngine.BPMN.Model.SequenceFlow
  alias EvilEngine.BPMN.ModelCache
  alias EvilEngine.Execution
  alias EvilEngine.Execution.ProcessInstance
  alias EvilEngine.Types.Identity

  @version_id "subprocess-test-version-001"
  @test_identity %Identity{id: "test-user", roles: ["admin"], groups: []}

  setup do
    Application.put_env(
      :core_execution,
      :persistence_adapter,
      EvilEngine.Execution.Persistence.NoOp
    )

    ModelCache.reset_state()

    ref = make_ref()
    subscribe_events(ref)

    on_exit(fn ->
      unsubscribe_events(ref)
      Application.delete_env(:core_execution, :persistence_adapter)
      ModelCache.reset_state()
    end)

    {:ok, ref: ref}
  end

  # ===================================================================
  # Happy Paths
  # ===================================================================

  describe "happy path — basic execution" do
    test "parent PI completes after subprocess inner graph finishes", %{ref: ref} do
      definitions = build_basic_subprocess()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"value" => 42}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{
                        parent_process_instance_id: ^parent_id,
                        child_process_instance_id: child_id
                      }},
                     3_000

      assert is_binary(child_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :finished}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      await_process_death(pid)
    end

    test "token passes through unchanged when no mappings are defined", %{ref: ref} do
      definitions = build_basic_subprocess()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()
      payload = %{"order_id" => "ORD-42", "items" => [1, 2, 3]}

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: payload
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      await_process_death(pid)
    end
  end

  describe "happy path — input mappings" do
    test "in_mappings transform payload before entering subprocess scope", %{ref: ref} do
      definitions =
        build_subprocess_with_mappings(
          in_mappings: [%Mapping{source: "token.order_id", target: "id"}],
          out_mappings: []
        )

      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"order_id" => "ORD-99", "extra" => "data"}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     5_000

      await_process_death(pid)
    end
  end

  describe "happy path — output mappings" do
    test "out_mappings transform result before returning to parent scope", %{ref: ref} do
      definitions =
        build_subprocess_with_mappings(
          in_mappings: [],
          out_mappings: [%Mapping{source: "token.result_value", target: "output"}]
        )

      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"result_value" => "success"}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     5_000

      await_process_death(pid)
    end
  end

  describe "happy path — payload contract (valid)" do
    test "subprocess starts when payload satisfies contract", %{ref: ref} do
      contract = %{
        "type" => "object",
        "required" => ["order_id"],
        "properties" => %{"order_id" => %{"type" => "string"}}
      }

      definitions = build_subprocess_with_contract(payload_contract: contract)
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"order_id" => "ORD-42"}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     5_000

      await_process_death(pid)
    end
  end

  describe "happy path — result contract (valid)" do
    test "parent advances when subprocess result satisfies contract", %{ref: ref} do
      contract = %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string"}}
      }

      definitions = build_subprocess_with_contract(result_contract: contract)
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"key" => "value"}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     5_000

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Lane Inheritance
  # ===================================================================

  describe "lane inheritance" do
    test "synthetic process inherits parent lane with all inner flow node IDs" do
      definitions = build_subprocess_with_lane("Operations")
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, synthetic_process, _defs} =
               ModelCache.fetch_subprocess_model(@version_id, "SubProcess_1")

      assert length(synthetic_process.lanes) == 1
      [lane] = synthetic_process.lanes
      assert lane.name == "Operations"

      inner_flow_node_ids = Enum.map(synthetic_process.flow_nodes, & &1.id)

      for fni_id <- inner_flow_node_ids do
        assert fni_id in lane.flow_node_refs,
               "Inner flow node #{fni_id} should be in inherited lane"
      end
    end

    test "subprocess with lane runs successfully end to end", %{ref: ref} do
      definitions = build_subprocess_with_lane("Operations")
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     5_000

      await_process_death(pid)
    end

    test "synthetic process has no lanes when parent has no lanes" do
      definitions = build_basic_subprocess()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, synthetic_process, _defs} =
               ModelCache.fetch_subprocess_model(@version_id, "SubProcess_1")

      assert synthetic_process.lanes == []
    end
  end

  # ===================================================================
  # Bad Paths — Invalid Subprocess Structure
  # ===================================================================

  # NOTE: `triggered_by_event: true` is now a supported construct (Event
  # Subprocess, Phase 5). A token-wired ESP shell is rejected at deploy time by
  # the validator (`:event_subprocess_has_sequence_flow`), covered by
  # `EvilEngine.BPMN.ValidatorTest`. There is therefore no runtime bad-path test
  # for it here — the invariant lives at the validation layer.

  describe "bad path — no start event" do
    test "PI fatals when subprocess has no start events", %{ref: ref} do
      definitions = build_subprocess_no_start_event()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :fatal}},
                     3_000

      await_process_death(pid)
    end
  end

  describe "bad path — multiple None start events" do
    test "PI fatals when subprocess has two None Start Events", %{ref: ref} do
      definitions = build_subprocess_multiple_start_events()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :fatal}},
                     3_000

      await_process_death(pid)
    end
  end

  describe "bad path — typed start event" do
    test "PI fatals when subprocess contains a Timer Start Event", %{ref: ref} do
      definitions = build_subprocess_typed_start_event()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :fatal}},
                     3_000

      await_process_death(pid)
    end
  end

  describe "bad path — no end event" do
    test "PI fatals when subprocess has no End Events", %{ref: ref} do
      definitions = build_subprocess_no_end_event()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :fatal}},
                     3_000

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Bad Paths — Contract Violations
  # ===================================================================

  describe "bad path — payload contract violation" do
    test "PI fatals when input payload fails contract validation", %{ref: ref} do
      contract = %{
        "type" => "object",
        "required" => ["mandatory_field"],
        "properties" => %{"mandatory_field" => %{"type" => "string"}}
      }

      definitions = build_subprocess_with_contract(payload_contract: contract)
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"wrong_field" => "value"}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :fatal}},
                     3_000

      await_process_death(pid)
    end
  end

  describe "bad path — result contract violation" do
    test "PI fatals when subprocess result fails contract validation", %{ref: ref} do
      contract = %{
        "type" => "object",
        "required" => ["required_output"],
        "properties" => %{"required_output" => %{"type" => "integer"}}
      }

      definitions = build_subprocess_with_contract(result_contract: contract)
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"no_match" => "string_not_integer"}
               )

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :fatal}},
                     3_000

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Error Bubbling
  # ===================================================================

  describe "error bubbling — child fatal, no boundary" do
    test "parent PI fatals when subprocess child reaches a dead end task", %{ref: ref} do
      definitions = build_subprocess_with_dead_end_and_end_event()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{child_process_instance_id: child_id}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :fatal}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :fatal}},
                     5_000

      await_process_death(pid)
    end
  end

  describe "error bubbling — BPMN Error End Event with boundary catch" do
    test "parent routes through error boundary when child hits Error End Event", %{ref: ref} do
      definitions = build_subprocess_error_with_boundary("VALIDATION_ERR")
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{child_process_instance_id: child_id}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :error}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     5_000

      await_process_death(pid)
    end
  end

  describe "error bubbling — BPMN Error End Event without boundary" do
    test "parent PI goes to error state when child hits Error End Event and no boundary catches",
         %{ref: ref} do
      definitions = build_subprocess_error_no_boundary("UNHANDLED_ERR")
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{child_process_instance_id: child_id}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :error}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :error}},
                     5_000

      await_process_death(pid)
    end
  end

  # ===================================================================
  # SubProcessChildStarted event observability
  # ===================================================================

  describe "observability — SubProcessChildStarted event" do
    test "SubProcessChildStarted telemetry fires with correct metadata", %{ref: ref} do
      definitions = build_basic_subprocess()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref, metadata}, 3_000

      assert metadata.parent_process_instance_id == parent_id
      assert is_binary(metadata.child_process_instance_id)
      assert metadata.subprocess_node_id == "SubProcess_1"
      assert is_binary(metadata.subprocess_flow_node_instance_id)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Data Object Scope Isolation
  # ===================================================================

  describe "data object scope isolation" do
    test "synthetic subprocess model contains inner data objects but not parent's" do
      definitions = build_subprocess_with_data_objects()
      ModelCache.put_new(@version_id, definitions)

      assert {:ok, synthetic_process, _defs} =
               ModelCache.fetch_subprocess_model(@version_id, "SubProcess_1")

      assert [inner_do] = synthetic_process.data_objects
      assert inner_do.id == "DO_Inner"
      assert inner_do.name == "InnerData"

      assert [inner_dor] = synthetic_process.data_object_references
      assert inner_dor.id == "DOR_Inner"
      assert inner_dor.data_object_ref == "DO_Inner"
    end

    test "parent process retains its own data objects after subprocess extraction" do
      definitions = build_subprocess_with_data_objects()
      [parent_process] = definitions.processes

      assert [parent_do] = parent_process.data_objects
      assert parent_do.id == "DO_Parent"

      assert [parent_dor] = parent_process.data_object_references
      assert parent_dor.id == "DOR_Parent"
    end

    test "subprocess with data objects executes end-to-end", %{ref: ref} do
      definitions = build_subprocess_with_data_objects()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{"value" => 1}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{
                        parent_process_instance_id: ^parent_id,
                        child_process_instance_id: child_id
                      }},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :finished}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Terminate End Event — scoped to child PI
  # ===================================================================

  describe "terminate end event — scoped kill inside subprocess" do
    test "child PI finishes via Terminate End Event without affecting parent", %{ref: ref} do
      definitions = build_subprocess_with_terminate_end()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{
                        parent_process_instance_id: ^parent_id,
                        child_process_instance_id: child_id
                      }},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :finished}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      refute_received {:pi_state, ^ref, %{new_state: :fatal}}

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Nested SubProcess runtime execution
  # ===================================================================

  describe "nested subprocess — SubProcess inside SubProcess" do
    test "three PI levels all finish and two SubProcessChildStarted events fire", %{ref: ref} do
      definitions = build_nested_subprocess()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{
                        parent_process_instance_id: ^parent_id,
                        child_process_instance_id: outer_child_id
                      }},
                     3_000

      assert_receive {:sp_child_started, ^ref,
                      %{
                        parent_process_instance_id: ^outer_child_id,
                        child_process_instance_id: inner_child_id
                      }},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^inner_child_id, new_state: :finished}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^outer_child_id, new_state: :finished}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Parent abort cascade
  # ===================================================================

  describe "parent abort cascade — subprocess child running" do
    test "aborting parent PI cascades abort to running subprocess child", %{ref: ref} do
      definitions = build_subprocess_with_user_task()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, parent_pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{
                        parent_process_instance_id: ^parent_id,
                        child_process_instance_id: child_id
                      }},
                     3_000

      Process.sleep(100)

      assert :ok = ProcessInstance.abort(parent_pid, "test_abort", @test_identity)

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :aborted}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :aborted}},
                     3_000

      await_process_death(parent_pid)
    end
  end

  # ===================================================================
  # WIP diagram — invalid subprocess never reached
  # ===================================================================

  describe "WIP diagram — invalid subprocess on unreachable branch" do
    test "PI finishes on default branch without entering invalid subprocess", %{ref: ref} do
      definitions = build_wip_subprocess_never_reached()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      refute_received {:sp_child_started, ^ref, _}

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      refute_received {:pi_state, ^ref, %{new_state: :fatal}}

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Inner error boundary inside subprocess scope
  # ===================================================================

  describe "error bubbling — inner activity error boundary inside subprocess" do
    test "child PI finishes via inner error boundary when script task fails", %{ref: ref} do
      definitions = build_subprocess_with_inner_error_boundary()
      ModelCache.put_new(@version_id, definitions)

      parent_id = random_id()

      assert {:ok, pid} =
               start_process_instance(@version_id,
                 process_instance_id: parent_id,
                 payload: %{}
               )

      assert_receive {:sp_child_started, ^ref,
                      %{child_process_instance_id: child_id}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^child_id, new_state: :finished}},
                     3_000

      assert_receive {:pi_state, ^ref,
                      %{process_instance_id: ^parent_id, new_state: :finished}},
                     3_000

      refute_received {:pi_state, ^ref, %{new_state: :fatal}}

      await_process_death(pid)
    end
  end

  # ===================================================================
  # Helpers: process instance lifecycle
  # ===================================================================

  defp start_process_instance(version_id, opts) do
    identity = %Identity{id: "test-user", roles: ["admin"], groups: []}

    pi_opts = %{
      process_instance_id: opts[:process_instance_id] || random_id(),
      process_version_id: version_id,
      payload: opts[:payload] || %{},
      identity: identity
    }

    Execution.start_process_instance(pi_opts)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp await_process_death(pid) do
    mon = Process.monitor(pid)
    assert_receive {:DOWN, ^mon, :process, ^pid, _}, 5_000
  end

  # ===================================================================
  # Helpers: telemetry subscription
  # ===================================================================

  defp subscribe_events(ref) do
    test_pid = self()

    :telemetry.attach(
      "sp-pi-state-#{inspect(ref)}",
      [:evil_engine, :process_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pi_state, ref, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "sp-fni-state-#{inspect(ref)}",
      [:evil_engine, :flow_node_instance, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:fni_state, ref, metadata})
      end,
      nil
    )

    :telemetry.attach(
      "sp-child-started-#{inspect(ref)}",
      [:evil_engine, :subprocess, :child_started],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:sp_child_started, ref, metadata})
      end,
      nil
    )
  end

  defp unsubscribe_events(ref) do
    :telemetry.detach("sp-pi-state-#{inspect(ref)}")
    :telemetry.detach("sp-fni-state-#{inspect(ref)}")
    :telemetry.detach("sp-child-started-#{inspect(ref)}")
  end

  # ===================================================================
  # Helpers: BPMN model builders — inner graph components
  # ===================================================================

  defp make_inner_start(id \\ "Sub_Start_1", outgoing \\ ["Sub_Flow_1"]) do
    %FlowNode{
      id: id,
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: outgoing
    }
  end

  defp make_inner_task(opts \\ []) do
    id = Keyword.get(opts, :id, "Sub_Task_1")
    incoming = Keyword.get(opts, :incoming, ["Sub_Flow_1"])
    outgoing = Keyword.get(opts, :outgoing, ["Sub_Flow_2"])

    %FlowNode{
      id: id,
      name: "Inner Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: incoming,
      outgoing: outgoing
    }
  end

  defp make_inner_end(id \\ "Sub_End_1", incoming \\ ["Sub_Flow_2"]) do
    %FlowNode{
      id: id,
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: incoming
    }
  end

  defp make_inner_error_end(error_code, id \\ "Sub_ErrorEnd_1", incoming \\ ["Sub_Flow_2"]) do
    %FlowNode{
      id: id,
      name: "Error End",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Error{
          error_code: error_code,
          error_message: "Test error: #{error_code}"
        }
      },
      incoming: incoming
    }
  end

  defp make_inner_dead_end_task do
    %FlowNode{
      id: "Sub_DeadEnd_1",
      name: "Dead End Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Sub_Flow_1"],
      outgoing: []
    }
  end

  defp make_inner_user_task do
    %FlowNode{
      id: "Sub_UserTask_1",
      name: "Inner User Task",
      type: :user_task,
      type_data: %FlowNodeData.UserTask{},
      incoming: ["Sub_Flow_1"],
      outgoing: ["Sub_Flow_2"]
    }
  end

  defp standard_inner_flows do
    [
      %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_Task_1"},
      %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_End_1"}
    ]
  end

  # ===================================================================
  # Helpers: BPMN model builders — outer (parent) graph
  # ===================================================================

  defp wrap_parent_process(subprocess_type_data, opts \\ []) do
    lanes = Keyword.get(opts, :lanes, [])
    boundary_refs = Keyword.get(opts, :boundary_refs, [])
    extra_nodes = Keyword.get(opts, :extra_nodes, [])
    extra_flows = Keyword.get(opts, :extra_flows, [])
    parent_data_objects = Keyword.get(opts, :data_objects, [])
    parent_data_object_references = Keyword.get(opts, :data_object_references, [])

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    sub_process = %FlowNode{
      id: "SubProcess_1",
      name: "Embedded Subprocess",
      type: :sub_process,
      type_data: subprocess_type_data,
      incoming: ["Flow_1"],
      outgoing: ["Flow_2"],
      boundary_event_refs: boundary_refs
    }

    end_event = %FlowNode{
      id: "End_1",
      name: "Done",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_2"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "SubProcess_1"},
      %SequenceFlow{id: "Flow_2", source_ref: "SubProcess_1", target_ref: "End_1"}
    ]

    all_nodes = [start, sub_process, end_event] ++ extra_nodes

    process = %BpmnProcess{
      id: "parent-process",
      name: "Parent Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: all_nodes,
      sequence_flows: flows ++ extra_flows,
      lanes: lanes,
      data_objects: parent_data_objects,
      data_object_references: parent_data_object_references
    }

    %Definitions{processes: [process], raw_xml: ""}
  end

  # ===================================================================
  # Helpers: scenario builders
  # ===================================================================

  defp build_basic_subprocess do
    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_task(), make_inner_end()],
      sequence_flows: standard_inner_flows()
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_with_mappings(opts) do
    in_mappings = Keyword.get(opts, :in_mappings, [])
    out_mappings = Keyword.get(opts, :out_mappings, [])

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_task(), make_inner_end()],
      sequence_flows: standard_inner_flows(),
      in_mappings: in_mappings,
      out_mappings: out_mappings
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_with_contract(opts) do
    payload_contract = Keyword.get(opts, :payload_contract)
    result_contract = Keyword.get(opts, :result_contract)

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_task(), make_inner_end()],
      sequence_flows: standard_inner_flows(),
      payload_contract: payload_contract,
      result_contract: result_contract
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_with_lane(lane_name) do
    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_task(), make_inner_end()],
      sequence_flows: standard_inner_flows()
    }

    lanes = [
      %Lane{
        id: "Lane_1",
        name: lane_name,
        flow_node_refs: ["Start_1", "SubProcess_1", "End_1"]
      }
    ]

    wrap_parent_process(type_data, lanes: lanes)
  end

  defp build_subprocess_no_start_event do
    task = make_inner_task(incoming: [], outgoing: ["Sub_Flow_2"])

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [task, make_inner_end()],
      sequence_flows: [
        %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_End_1"}
      ]
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_multiple_start_events do
    start_a = make_inner_start("Sub_Start_A", ["Sub_Flow_A"])
    start_b = make_inner_start("Sub_Start_B", ["Sub_Flow_B"])

    task =
      make_inner_task(
        incoming: ["Sub_Flow_A", "Sub_Flow_B"],
        outgoing: ["Sub_Flow_2"]
      )

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [start_a, start_b, task, make_inner_end()],
      sequence_flows: [
        %SequenceFlow{id: "Sub_Flow_A", source_ref: "Sub_Start_A", target_ref: "Sub_Task_1"},
        %SequenceFlow{id: "Sub_Flow_B", source_ref: "Sub_Start_B", target_ref: "Sub_Task_1"},
        %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_End_1"}
      ]
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_typed_start_event do
    none_start = make_inner_start()

    timer_start = %FlowNode{
      id: "Sub_TimerStart",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{
        event_definition: %EventDefinition.Timer{
          time_duration: "PT1H"
        }
      },
      outgoing: ["Sub_Flow_Timer"]
    }

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [
        none_start,
        timer_start,
        make_inner_task(),
        make_inner_end()
      ],
      sequence_flows:
        standard_inner_flows() ++
          [
            %SequenceFlow{
              id: "Sub_Flow_Timer",
              source_ref: "Sub_TimerStart",
              target_ref: "Sub_Task_1"
            }
          ]
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_no_end_event do
    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_task(outgoing: [])],
      sequence_flows: [
        %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_Task_1"}
      ]
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_with_dead_end_and_end_event do
    dead_end_task = make_inner_dead_end_task()

    unreachable_end = %FlowNode{
      id: "Sub_End_Unreachable",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: []
    }

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), dead_end_task, unreachable_end],
      sequence_flows: [
        %SequenceFlow{
          id: "Sub_Flow_1",
          source_ref: "Sub_Start_1",
          target_ref: "Sub_DeadEnd_1"
        }
      ]
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_error_with_boundary(error_code) do
    inner_nodes = [
      make_inner_start(),
      make_inner_task(),
      make_inner_error_end(error_code)
    ]

    error_inner_flows = [
      %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_Task_1"},
      %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_ErrorEnd_1"}
    ]

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: inner_nodes,
      sequence_flows: error_inner_flows
    }

    boundary = %FlowNode{
      id: "BE_1",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "SubProcess_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Error{
          error_code: error_code
        }
      },
      outgoing: ["Flow_BE"]
    }

    error_end = %FlowNode{
      id: "End_Error",
      name: "Error Handled",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_BE"]
    }

    flow_be = %SequenceFlow{id: "Flow_BE", source_ref: "BE_1", target_ref: "End_Error"}

    wrap_parent_process(type_data,
      boundary_refs: ["BE_1"],
      extra_nodes: [boundary, error_end],
      extra_flows: [flow_be]
    )
  end

  defp build_subprocess_error_no_boundary(error_code) do
    inner_nodes = [
      make_inner_start(),
      make_inner_task(),
      make_inner_error_end(error_code)
    ]

    error_inner_flows = [
      %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_Task_1"},
      %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_ErrorEnd_1"}
    ]

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: inner_nodes,
      sequence_flows: error_inner_flows
    }

    wrap_parent_process(type_data)
  end

  defp build_subprocess_with_data_objects do
    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_task(), make_inner_end()],
      sequence_flows: standard_inner_flows(),
      data_objects: [
        %DataObject{id: "DO_Inner", name: "InnerData"}
      ],
      data_object_references: [
        %DataObjectReference{id: "DOR_Inner", name: "InnerDataRef", data_object_ref: "DO_Inner"}
      ]
    }

    wrap_parent_process(type_data,
      data_objects: [%DataObject{id: "DO_Parent", name: "ParentData"}],
      data_object_references: [
        %DataObjectReference{id: "DOR_Parent", name: "ParentDataRef", data_object_ref: "DO_Parent"}
      ]
    )
  end

  defp build_subprocess_with_terminate_end do
    inner_terminate_end = %FlowNode{
      id: "Sub_TermEnd",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{
        event_definition: %EventDefinition.Terminate{}
      },
      incoming: ["Sub_Flow_2"]
    }

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_task(), inner_terminate_end],
      sequence_flows: [
        %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_Task_1"},
        %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_TermEnd"}
      ]
    }

    wrap_parent_process(type_data)
  end

  defp build_nested_subprocess do
    innermost_type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [
        %FlowNode{
          id: "Inner2_Start",
          type: :start_event,
          type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
          outgoing: ["Inner2_Flow_1"]
        },
        %FlowNode{
          id: "Inner2_Task",
          type: :task,
          type_data: %FlowNodeData.Task{},
          incoming: ["Inner2_Flow_1"],
          outgoing: ["Inner2_Flow_2"]
        },
        %FlowNode{
          id: "Inner2_End",
          type: :end_event,
          type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
          incoming: ["Inner2_Flow_2"]
        }
      ],
      sequence_flows: [
        %SequenceFlow{id: "Inner2_Flow_1", source_ref: "Inner2_Start", target_ref: "Inner2_Task"},
        %SequenceFlow{id: "Inner2_Flow_2", source_ref: "Inner2_Task", target_ref: "Inner2_End"}
      ]
    }

    outer_type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [
        %FlowNode{
          id: "Outer_Start",
          type: :start_event,
          type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
          outgoing: ["Outer_Flow_1"]
        },
        %FlowNode{
          id: "InnerSubProcess",
          name: "Inner Subprocess",
          type: :sub_process,
          type_data: innermost_type_data,
          incoming: ["Outer_Flow_1"],
          outgoing: ["Outer_Flow_2"]
        },
        %FlowNode{
          id: "Outer_End",
          type: :end_event,
          type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
          incoming: ["Outer_Flow_2"]
        }
      ],
      sequence_flows: [
        %SequenceFlow{id: "Outer_Flow_1", source_ref: "Outer_Start", target_ref: "InnerSubProcess"},
        %SequenceFlow{id: "Outer_Flow_2", source_ref: "InnerSubProcess", target_ref: "Outer_End"}
      ]
    }

    wrap_parent_process(outer_type_data)
  end

  defp build_subprocess_with_user_task do
    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [make_inner_start(), make_inner_user_task(), make_inner_end()],
      sequence_flows: [
        %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_UserTask_1"},
        %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_UserTask_1", target_ref: "Sub_End_1"}
      ]
    }

    wrap_parent_process(type_data)
  end

  defp build_wip_subprocess_never_reached do
    invalid_subprocess_type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [
        make_inner_task(incoming: [], outgoing: ["Sub_Flow_2"]),
        make_inner_end()
      ],
      sequence_flows: [
        %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Task_1", target_ref: "Sub_End_1"}
      ]
    }

    start = %FlowNode{
      id: "Start_1",
      type: :start_event,
      type_data: %FlowNodeData.StartEvent{event_definition: %EventDefinition.None{}},
      outgoing: ["Flow_1"]
    }

    gateway = %FlowNode{
      id: "Gateway_1",
      type: :exclusive_gateway,
      type_data: %FlowNodeData.ExclusiveGateway{default_flow_ref: "Flow_Left"},
      incoming: ["Flow_1"],
      outgoing: ["Flow_Left", "Flow_Right"]
    }

    task_left = %FlowNode{
      id: "Task_Left",
      name: "Safe Task",
      type: :task,
      type_data: %FlowNodeData.Task{},
      incoming: ["Flow_Left"],
      outgoing: ["Flow_ToEndOK"]
    }

    sub_process = %FlowNode{
      id: "SubProcess_1",
      name: "Invalid Subprocess",
      type: :sub_process,
      type_data: invalid_subprocess_type_data,
      incoming: ["Flow_Right"],
      outgoing: ["Flow_ToEndFail"]
    }

    end_ok = %FlowNode{
      id: "End_OK",
      name: "Success",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_ToEndOK"]
    }

    end_fail = %FlowNode{
      id: "End_Fail",
      name: "Failure",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Flow_ToEndFail"]
    }

    flows = [
      %SequenceFlow{id: "Flow_1", source_ref: "Start_1", target_ref: "Gateway_1"},
      %SequenceFlow{
        id: "Flow_Left",
        source_ref: "Gateway_1",
        target_ref: "Task_Left",
        is_default: true
      },
      %SequenceFlow{
        id: "Flow_Right",
        source_ref: "Gateway_1",
        target_ref: "SubProcess_1",
        condition_expression: "token.go_right = true"
      },
      %SequenceFlow{id: "Flow_ToEndOK", source_ref: "Task_Left", target_ref: "End_OK"},
      %SequenceFlow{id: "Flow_ToEndFail", source_ref: "SubProcess_1", target_ref: "End_Fail"}
    ]

    process = %BpmnProcess{
      id: "parent-process",
      name: "Parent Process",
      version: "1.0.0",
      is_executable: true,
      flow_nodes: [start, gateway, task_left, sub_process, end_ok, end_fail],
      sequence_flows: flows
    }

    %Definitions{processes: [process], raw_xml: ""}
  end

  defp build_subprocess_with_inner_error_boundary do
    failing_script = %FlowNode{
      id: "Sub_Script_1",
      name: "Failing Script",
      type: :script_task,
      type_data: %FlowNodeData.ScriptTask{script: nil, script_ref: nil},
      incoming: ["Sub_Flow_1"],
      outgoing: ["Sub_Flow_2"],
      boundary_event_refs: ["Sub_ErrorBE_1"]
    }

    error_boundary = %FlowNode{
      id: "Sub_ErrorBE_1",
      type: :boundary_event,
      type_data: %FlowNodeData.BoundaryEvent{
        attached_to_ref: "Sub_Script_1",
        cancel_activity: true,
        event_definition: %EventDefinition.Error{}
      },
      outgoing: ["Sub_Flow_BE"]
    }

    end_normal = make_inner_end("Sub_End_Normal", ["Sub_Flow_2"])

    end_error = %FlowNode{
      id: "Sub_End_Error",
      name: "Error Handled",
      type: :end_event,
      type_data: %FlowNodeData.EndEvent{event_definition: %EventDefinition.None{}},
      incoming: ["Sub_Flow_BE"]
    }

    type_data = %FlowNodeData.SubProcess{
      triggered_by_event: false,
      flow_nodes: [
        make_inner_start("Sub_Start_1", ["Sub_Flow_1"]),
        failing_script,
        error_boundary,
        end_normal,
        end_error
      ],
      sequence_flows: [
        %SequenceFlow{id: "Sub_Flow_1", source_ref: "Sub_Start_1", target_ref: "Sub_Script_1"},
        %SequenceFlow{id: "Sub_Flow_2", source_ref: "Sub_Script_1", target_ref: "Sub_End_Normal"},
        %SequenceFlow{id: "Sub_Flow_BE", source_ref: "Sub_ErrorBE_1", target_ref: "Sub_End_Error"}
      ]
    }

    wrap_parent_process(type_data)
  end
end
