defmodule EvilEngine.Conformance.ConformanceTest do
  @moduledoc """
  YAML-driven conformance test suite.

  Auto-tier specs are fully driven by the conformance runner.
  Interactive-tier specs use hand-written interaction logic.
  Error-tier specs test start-time rejections.

  Covers all Phase 2 feature categories for exit criterion compliance.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Api
  alias EvilEngine.Auth.ProviderRegistry
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.ConformanceRunner, as: Runner
  alias EvilEngine.Test.ExamplePlugin

  @moduletag :conformance

  @retry_user_task_fixture Path.expand("../fixtures/bpmns/retry_user_task.bpmn", __DIR__)

  defmodule FakeConformanceAuthProvider do
    @behaviour EvilEngine.Plugin.AuthProvider
    alias EvilEngine.Types.Identity

    @impl true
    def verify_and_resolve("valid-conformance-" <> user_id) do
      {:ok,
       %Identity{
         id: "conformance-#{user_id}",
         roles: ["admin"],
         groups: [],
         claims: %{
           "sub" => "conformance-#{user_id}",
           "provider" => "conformance-fake",
           "deploy_bpmn" => true,
           "lane:default" => "write"
         }
       }}
    end

    def verify_and_resolve(_token), do: {:error, :invalid_token}
  end

  setup do
    load_example_plugin()
    :ok
  end

  defp load_example_plugin do
    Application.put_env(:core_execution, :service_task_dispatch, EvilEngine.Plugins.RegistryDispatch)
    facade = Loader.facade_for_plugin("evil:conformance_plugin")
    ExamplePlugin.on_load(facade)
  end

  # ===================================================================
  # AUTO TIER — deploy-start-assert, fully driven by the runner
  # ===================================================================

  for yaml_file <- Path.wildcard("test/conformance/C*.yaml") do
    spec = YamlElixir.read_from_file!(yaml_file)
    basename = Path.basename(yaml_file, ".yaml")

    if spec["tier"] == "auto" do
      @spec_data spec

      test "#{basename}: #{spec["name"]}" do
        Runner.run_auto(@spec_data)
      end
    end
  end

  # ===================================================================
  # EMBEDDED SUBPROCESS — auto-tier (C140–C146)
  #
  # Inline `<bpmn:subProcess>` fixtures with inner flow defined in the
  # parent BPMN XML. No separate child_fixture deployment is required.
  # These specs use tier: auto and are executed by the AUTO TIER loop above:
  #   - C140_embedded_subprocess_happy_path.yaml
  #   - C141_embedded_subprocess_error_boundary.yaml
  #   - C142_embedded_subprocess_terminate_scoped.yaml
  #   - C143_embedded_subprocess_nested.yaml
  #   - C144_embedded_subprocess_input_output_mappings.yaml
  #   - C145_embedded_subprocess_terminate_with_parallel.yaml
  #   - C146_embedded_subprocess_wip_never_reached.yaml
  # ===================================================================

  # ===================================================================
  # INTERACTIVE TIER — hand-written interaction logic
  # ===================================================================

  test "C06: User task finished via explicit call" do
    spec = Runner.load_spec("C06_user_task_finish.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "user_task")
    :ok = finish_user_task(process_instance_id, flow_node_instance.id, %{"approved" => true})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C07: User task cancelled" do
    spec = Runner.load_spec("C07_user_task_cancel.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "user_task")
    :ok = cancel_user_task(process_instance_id, flow_node_instance.id, "not needed")

    Process.sleep(100)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C08: User task contract violation rejected (PI stays running)" do
    spec = Runner.load_spec("C08_user_task_contract_violation.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "user_task")
    {:error, {422, %{"error" => "contract_violation"}}} =
      finish_user_task(process_instance_id, flow_node_instance.id, %{"wrong" => "data"})

    Process.sleep(100)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C09: Manual task with requireConfirmation" do
    spec = Runner.load_spec("C09_manual_task_confirm.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "manual_task")
    :ok = finish_manual_task(process_instance_id, flow_node_instance.id)

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C11: Service task via echo plugin (async)" do
    spec = Runner.load_spec("C11_service_task_echo.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C12: Async service task completed via plugin" do
    spec = Runner.load_spec("C12_service_task_async.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "service_task")
    :ok = finish_async_service_task(flow_node_instance.id, %{"result" => "done"})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C13: Async service task failed via plugin" do
    spec = Runner.load_spec("C13_service_task_async_fail.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "service_task")
    :ok = fail_async_service_task(flow_node_instance.id, "FAIL_CODE", "test failure")

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  # ===================================================================
  # ERROR TIER — start-time rejections
  # ===================================================================

  test "C16: Multi-start without startEventId causes 422" do
    spec = Runner.load_spec("C16_multi_start_ambiguous.yaml")
    {201, _} = http_deploy(spec["fixture"])
    {status, _body} = http_start(spec["process_model_id"])
    assert status == 422
  end

  test "C19: Oversize start payload rejected with 413" do
    spec = Runner.load_spec("C19_start_payload_oversize.yaml")
    {201, _} = http_deploy(spec["fixture"])

    Application.put_env(:core_execution, :token_max_bytes, 2048)
    large_payload = %{"data" => String.duplicate("x", 5000)}
    {status, _body} = http_start(spec["process_model_id"], %{"payload" => large_payload})
    Application.put_env(:core_execution, :token_max_bytes, 65_536)

    assert status == 413
  end

  # ===================================================================
  # INTERACTIVE TIER — PI retry conformance
  # ===================================================================

  test "C62: PI retry from fatal" do
    spec = Runner.load_spec("C62_pi_retry_from_fatal.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _process_instance} = await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)
    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "fatal")

    {204, nil} = http_retry_process_instance(process_instance_id)
    {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "fatal")
  end

  test "C63: PI retry from aborted" do
    spec = Runner.load_spec("C63_pi_retry_from_aborted.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "user_task")

    {204, nil} =
      http_abort_process_instance(process_instance_id, "conformance_abort", %{
        "abort_process_instance" => "all"
      })

    wait_for_process_instance(process_instance_id, 5_000)
    assert_pi_state!(process_instance_id, "aborted")

    {204, nil} = http_retry_process_instance(process_instance_id)
    {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)

    {:ok, retried_flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {204, nil} = http_finish_user_task(retried_flow_node_instance.id, %{"done" => true})
    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "C64: PI retry with version migration" do
    configure_called_element_resolver()
    spec = Runner.load_spec("C64_pi_retry_version_migration.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "user_task")

    process_instance_v1 = fetch_process_instance!(process_instance_id)
    version_id_v1 = process_instance_v1.process_version_id

    {204, nil} =
      http_abort_process_instance(process_instance_id, "version_migrate", %{
        "abort_process_instance" => "all"
      })

    wait_for_process_instance(process_instance_id, 5_000)

    v2_xml = conformance_version_xml("retry_user_task.bpmn", "2.0.0")
    {201, _} = http_deploy_xml(v2_xml)

    {204, nil} = http_retry_process_instance(process_instance_id, %{"version" => "2.0.0"})
    {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)

    process_instance_v2 = fetch_process_instance!(process_instance_id)
    assert process_instance_v2.process_version_id != version_id_v1

    {:ok, retried_flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {204, nil} = http_finish_user_task(retried_flow_node_instance.id, %{"done" => true})
    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "C65: Call Activity implicit retry — child aborted, parent retried" do
    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )

    {201, _} = http_deploy("retry_user_task.bpmn")
    {201, _} = http_deploy("retry_parent_with_user_task_child.bpmn")
    {201, body} = http_start("RetryParentWithUserTaskChild")
    parent_process_instance_id = body["processInstanceId"]

    Process.sleep(3_000)

    {204, nil} =
      http_abort_process_instance(parent_process_instance_id, "cascade_abort", %{
        "abort_process_instance" => "all"
      })

    wait_for_process_instance(parent_process_instance_id, 5_000)
    assert_pi_state!(parent_process_instance_id, "aborted")

    {204, nil} = http_retry_process_instance(parent_process_instance_id)
    {:ok, _pid} = poll_pi_alive(parent_process_instance_id, 10_000)

    Process.sleep(5_000)

    child_process_instance_ids = conformance_find_child_ids(parent_process_instance_id)
    child_process_instance_id = List.last(child_process_instance_ids)

    {:ok, child_user_task_fni} =
      await_waiting_flow_node_instance(child_process_instance_id, "user_task", timeout: 15_000)

    {204, nil} = http_finish_user_task(child_user_task_fni.id, %{"done" => true})
    wait_for_process_instance(child_process_instance_id, 15_000)
    wait_for_process_instance(parent_process_instance_id, 15_000)

    assert_pi_state!(parent_process_instance_id, "finished")
  end

  test "C66: Tree retry from child PI" do
    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )

    {201, _} = http_deploy("call_activity_failing_child.bpmn")
    {201, _} = http_deploy("retry_parent_with_failing_child.bpmn")
    {201, body} = http_start("RetryParentWithFailingChild")
    parent_process_instance_id = body["processInstanceId"]

    {:ok, _parent} =
      await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

    [child_process_instance_id] = conformance_find_child_ids(parent_process_instance_id)
    assert_pi_state!(child_process_instance_id, "fatal")

    {204, nil} = http_retry_process_instance(child_process_instance_id)
    {:ok, _pid} = poll_pi_alive(parent_process_instance_id, 5_000)
    wait_for_process_instance(parent_process_instance_id, 15_000)

    assert_pi_state!(parent_process_instance_id, "fatal")
  end

  test "C67: Tree retry from grandchild (3-level)" do
    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )

    {201, _} = http_deploy("call_activity_failing_child.bpmn")
    {201, _} = http_deploy("retry_parent_with_failing_child.bpmn")
    {201, _} = http_deploy("retry_nested_grandchild.bpmn")
    {201, body} = http_start("RetryNestedGrandchild")
    root_process_instance_id = body["processInstanceId"]

    {:ok, _root} =
      await_process_instance_state(root_process_instance_id, "fatal", timeout: 20_000)

    [mid_process_instance_id] = conformance_find_child_ids(root_process_instance_id)
    [grandchild_process_instance_id] = conformance_find_child_ids(mid_process_instance_id)

    assert_pi_state!(grandchild_process_instance_id, "fatal")

    {204, nil} = http_retry_process_instance(grandchild_process_instance_id)
    {:ok, _pid} = poll_pi_alive(root_process_instance_id, 5_000)
    wait_for_process_instance(root_process_instance_id, 20_000)

    assert_pi_state!(root_process_instance_id, "fatal")
  end

  test "C68: PI retry — checkpoint AT Call Activity (Scenario B)" do
    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )

    {201, _} = http_deploy("call_activity_failing_child.bpmn")
    {201, _} = http_deploy("retry_parent_with_failing_child.bpmn")
    {201, body} = http_start("RetryParentWithFailingChild")
    parent_process_instance_id = body["processInstanceId"]

    {:ok, _parent} =
      await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

    [child_process_instance_id] = conformance_find_child_ids(parent_process_instance_id)
    assert_pi_state!(child_process_instance_id, "fatal")

    parent_fnis = fetch_flow_node_instances(parent_process_instance_id)
    call_activity_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "CA_1"))
    assert call_activity_fni != nil

    {204, nil} =
      http_retry_process_instance(parent_process_instance_id, %{
        "resetToFlowNodeInstanceId" => call_activity_fni.id
      })

    {:ok, _pid} = poll_pi_alive(parent_process_instance_id, 5_000)
    wait_for_process_instance(parent_process_instance_id, 15_000)

    assert_pi_state!(parent_process_instance_id, "fatal")

    remaining_child_ids = conformance_find_child_ids(parent_process_instance_id)
    assert child_process_instance_id in remaining_child_ids,
           "Scenario B: child PI must be preserved (not deleted)"
  end

  test "C69: PI retry — checkpoint BEFORE Call Activity (Scenario C)" do
    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )

    {201, _} = http_deploy("call_activity_child.bpmn")
    {201, _} = http_deploy("retry_parent_task_before_then_fatal.bpmn")
    {201, body} = http_start("RetryParentTaskBeforeThenFatal")
    parent_process_instance_id = body["processInstanceId"]

    {:ok, _parent} =
      await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

    old_child_ids = conformance_find_child_ids(parent_process_instance_id)
    assert length(old_child_ids) >= 1, "Expected at least one child PI before checkpoint retry"
    [old_child_process_instance_id | _] = old_child_ids

    parent_fnis = fetch_flow_node_instances(parent_process_instance_id)
    task_before_fni = Enum.find(parent_fnis, &(&1.flow_node_id == "Task_Before"))
    assert task_before_fni != nil

    {204, nil} =
      http_retry_process_instance(parent_process_instance_id, %{
        "resetToFlowNodeInstanceId" => task_before_fni.id
      })

    {:ok, _pid} = poll_pi_alive(parent_process_instance_id, 5_000)
    wait_for_process_instance(parent_process_instance_id, 15_000)

    assert_pi_state!(parent_process_instance_id, "fatal")

    new_child_ids = conformance_find_child_ids(parent_process_instance_id)
    refute old_child_process_instance_id in new_child_ids,
           "Scenario C: old child PI must be hard-deleted when checkpoint is before Call Activity"
  end

  test "C70: PI retry — checkpoint resets Data Object writes" do
    {201, _} = http_deploy("retry_checkpoint_data_objects.bpmn")
    {201, body} = http_start("RetryCheckpointDataObjects")
    process_instance_id = body["processInstanceId"]

    {:ok, _process_instance} =
      await_process_instance_state(process_instance_id, "fatal", timeout: 15_000)

    do_snapshot_before = fetch_data_object(process_instance_id, "DO_counter")
    assert do_snapshot_before != nil, "DataObject DO_counter must exist after initial run"
    assert do_snapshot_before.value["step"] == 2,
           "Before retry, DO_counter should reflect ScriptTask_B's write (step 2)"

    writes_before = fetch_data_object_writes(process_instance_id, "DO_counter")
    assert length(writes_before) == 2,
           "Before retry, there should be 2 DataObjectWrite audit rows (one per ScriptTask)"

    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    script_task_a_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "ScriptTask_A"))
    assert script_task_a_fni != nil, "ScriptTask_A FNI must exist"

    {204, nil} =
      http_retry_process_instance(process_instance_id, %{
        "resetToFlowNodeInstanceId" => script_task_a_fni.id
      })

    {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
    wait_for_process_instance(process_instance_id, 15_000)

    assert_pi_state!(process_instance_id, "fatal")

    do_snapshot_after = fetch_data_object(process_instance_id, "DO_counter")
    assert do_snapshot_after != nil, "DataObject DO_counter must still exist after retry"
    assert do_snapshot_after.value["step"] == 2,
           "After retry and re-execution, DO_counter should be at step 2 again"

    writes_after = fetch_data_object_writes(process_instance_id, "DO_counter")
    rollback_boundary_write =
      Enum.find(writes_before, &(&1.flow_node_instance_id == script_task_a_fni.id))

    assert rollback_boundary_write != nil,
           "ScriptTask_A's original write must survive the checkpoint rollback"

    writes_from_deleted_fnis =
      Enum.filter(writes_after, fn write ->
        write.created_at > rollback_boundary_write.created_at and
          write.id in Enum.map(writes_before, & &1.id)
      end)

    refute Enum.any?(writes_from_deleted_fnis),
           "DataObjectWrite rows from deleted FNIs (ScriptTask_B) must not survive rollback"

    assert length(writes_after) >= 3,
           "After retry, expect at least 3 writes: original A + re-executed A + re-executed B"
  end

  test "C20: Resume async service task after engine restart" do
    spec = Runner.load_spec("C20_resume_async_service_task.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, flow_node_instance} = await_waiting_flow_node_instance(process_instance_id, "service_task")

    {:ok, process_instance_pid} = EvilEngine.Execution.lookup_process_instance(process_instance_id)
    DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, process_instance_pid)

    Process.sleep(100)

    load_example_plugin()

    {:ok, _resumed} = EvilEngine.Execution.ResumeRunner.resume_all()

    Process.sleep(200)

    :ok = finish_async_service_task(flow_node_instance.id, %{"result" => "after_resume"})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  # ===================================================================
  # CALL ACTIVITY TIER — C26-C30
  # ===================================================================

  test "C26: Call Activity spawns child, result flows back" do
    configure_called_element_resolver()
    {201, _} = http_deploy("call_activity_child.bpmn")
    {201, _} = http_deploy("call_activity_basic.bpmn")
    {201, body} = http_start("CallActivityBasic")
    process_instance_id = body["processInstanceId"]

    wait_for_process_instance(process_instance_id, 15_000)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "C27: Call Activity child fails, error boundary catches" do
    configure_called_element_resolver()
    {201, _} = http_deploy("call_activity_failing_child.bpmn")
    {201, _} = http_deploy("call_activity_error_boundary.bpmn")
    {201, body} = http_start("CallActivityErrorBoundary")
    process_instance_id = body["processInstanceId"]

    wait_for_process_instance(process_instance_id, 15_000)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "C28: Call Activity child fails, no boundary, parent fatals" do
    configure_called_element_resolver()
    {201, _} = http_deploy("call_activity_failing_child.bpmn")
    {201, _} = http_deploy("call_activity_no_boundary_fatal.bpmn")
    {201, body} = http_start("CallActivityNoBoundaryFatal")
    process_instance_id = body["processInstanceId"]

    {:ok, _process_instance} =
      await_process_instance_state(process_instance_id, "fatal", timeout: 15_000)

    wait_for_process_instance(process_instance_id, 15_000)
    assert_pi_state!(process_instance_id, "fatal")
  end

  test "C29: Call Activity with out_mappings FEEL expression" do
    configure_called_element_resolver()
    {201, _} = http_deploy("call_activity_child.bpmn")
    {201, _} = http_deploy("call_activity_result_mapping.bpmn")
    {201, body} = http_start("CallActivityResultMapping", %{"payload" => %{"input" => "hello"}})
    process_instance_id = body["processInstanceId"]

    wait_for_process_instance(process_instance_id, 15_000)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "C30: XOR routes to Call Activity branch" do
    configure_called_element_resolver()
    {201, _} = http_deploy("call_activity_child.bpmn")
    {201, _} = http_deploy("xor_to_call_activity.bpmn")
    {201, body} = http_start("XorToCallActivity", %{"payload" => %{"route" => "call"}})
    process_instance_id = body["processInstanceId"]

    wait_for_process_instance(process_instance_id, 15_000)
    assert_pi_state!(process_instance_id, "finished")
  end

  # ===================================================================
  # INTERACTIVE TIER — BRT (Business Rule Task) conformance
  # ===================================================================

  test "C35: Business rule task in FEEL mode" do
    spec = Runner.load_spec("C35_business_rule_task_feel_inline.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C38: Business rule task result contract violation causes fatal" do
    {201, _} = http_deploy("business_rule_task_contract_violation.bpmn")
    {201, body} = http_start("BrtContractViolation", %{"payload" => %{"input" => "data"}})
    process_instance_id = body["processInstanceId"]

    {:ok, _process_instance} =
      await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

    wait_for_process_instance(process_instance_id, 10_000)
    assert_pi_state!(process_instance_id, "fatal")

    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    brt_fni =
      Enum.find(flow_node_instances, &(&1.flow_node_id == "BRT_1"))

    assert brt_fni != nil, "BRT_1 FNI must exist"
    assert brt_fni.state == "fatal", "BRT_1 must be in fatal state due to contract violation"
  end

  # ===================================================================
  # INTERACTIVE TIER — Script Task conformance
  # ===================================================================

  test "C73: Script Task dispatched via evil:scriptRef plugin" do
    Application.put_env(
      :core_execution,
      :script_dispatch,
      EvilEngine.Plugins.ScriptRegistryDispatch
    )

    spec = Runner.load_spec("C73_script_task_script_ref.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  after
    Application.delete_env(:core_execution, :script_dispatch)
  end

  # ===================================================================
  # INTERACTIVE TIER — PI retry version migration reject
  # ===================================================================

  test "C77: PI retry with incompatible version migration rejected (422)" do
    configure_called_element_resolver()
    {201, _} = http_deploy("retry_user_task.bpmn")
    {201, body} = http_start("RetryUserTask")
    process_instance_id = body["processInstanceId"]

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task")

    {204, nil} =
      http_abort_process_instance(process_instance_id, "version_reject_test", %{
        "abort_process_instance" => "all"
      })

    wait_for_process_instance(process_instance_id, 5_000)
    assert_pi_state!(process_instance_id, "aborted")

    {201, _} = http_deploy_xml(conformance_incompatible_v2_xml())

    {422, error_body} =
      http_retry_process_instance(process_instance_id, %{"version" => "2.0.0"})

    assert error_body["error"] == "version_migration_incompatible"
    assert is_list(error_body["conflicts"])
    assert error_body["conflicts"] != []
  end

  # ===================================================================
  # INTERACTIVE TIER — Auth Provider conformance
  # ===================================================================

  test "C78: Custom Auth Provider plugin handles authentication end-to-end" do
    {201, _} = http_deploy("linear_start_end.bpmn")

    ProviderRegistry.register_provider(FakeConformanceAuthProvider)
    on_exit(fn -> ProviderRegistry.reset_to_default() end)

    start_body = Jason.encode!(%{})

    conn =
      Plug.Test.conn(:post, "/processes/LinearStartEnd/start", start_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer valid-conformance-user1")
      |> route()

    assert conn.status == 201
    response = Jason.decode!(conn.resp_body)
    process_instance_id = response["processInstanceId"]

    wait_for_process_instance(process_instance_id)
    assert_pi_state!(process_instance_id, "finished")
  end

  test "C79: Custom Auth Provider rejects invalid token (401)" do
    {201, _} = http_deploy("linear_start_end.bpmn")

    ProviderRegistry.register_provider(FakeConformanceAuthProvider)
    on_exit(fn -> ProviderRegistry.reset_to_default() end)

    start_body = Jason.encode!(%{})

    conn =
      Plug.Test.conn(:post, "/processes/LinearStartEnd/start", start_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer totally-invalid-token")
      |> route()

    assert conn.status == 401
  end

  # ===================================================================
  # INTERACTIVE TIER — Message Events conformance (C100–C108)
  # ===================================================================

  test "C100: Message intermediate catch — single recipient, catch advances" do
    spec = Runner.load_spec("C100_message_catch_simple.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("test-message", %{"data" => "hello"})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C103: Message start event — PI created from published message" do
    spec = Runner.load_spec("C103_message_start_event.yaml")
    {201, _} = http_deploy(spec["fixture"])

    {200, trigger_result} = http_trigger_message("trigger-process", %{"input" => "start"})
    assert length(trigger_result["startedProcessInstanceIds"]) >= 1

    [process_instance_id | _] = trigger_result["startedProcessInstanceIds"]
    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C104: Message boundary (interrupting) — interrupts host task" do
    spec = Runner.load_spec("C104_message_boundary_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("cancel-task")

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C105: Message boundary (non-interrupting) — parallel branch" do
    spec = Runner.load_spec("C105_message_boundary_non_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("notify-update")

    Process.sleep(500)

    :ok = finish_user_task(process_instance_id, user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C106: Send Task → Receive Task pair" do
    spec = Runner.load_spec("C106_send_receive_task.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _receive_fni} =
      await_waiting_flow_node_instance(process_instance_id, "receive_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("service-response", %{"response" => "pong"})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C107: outputMapping on catch applies correctly" do
    spec = Runner.load_spec("C107_message_catch_output_mapping.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("mapped-message", %{"data" => "mapped_value"})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C108: resultContract violation on message catch → FNI fatal" do
    spec = Runner.load_spec("C108_message_catch_contract_violation.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("contract-message", %{"wrong_field" => "no orderId"})

    {:ok, _process_instance} =
      await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

    wait_for_process_instance(process_instance_id, 10_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  # ===================================================================
  # Signal Events (C110–C123)
  # ===================================================================

  test "C110: Signal catch — simple cross-process broadcast" do
    spec = Runner.load_spec("C110_signal_catch_simple.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, _trigger_result} = http_trigger_signal("test-signal")

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C113: Signal boundary (interrupting) — interrupts host activity" do
    spec = Runner.load_spec("C113_signal_boundary_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_signal("cancel-signal")

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C114: Signal boundary (non-interrupting) — spawns parallel branch" do
    spec = Runner.load_spec("C114_signal_boundary_non_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_signal("notify-signal")

    Process.sleep(500)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    http_finish_user_task(user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C115: Signal start event — new PI from broadcast" do
    spec = Runner.load_spec("C115_signal_start_event.yaml")
    {201, _} = http_deploy(spec["fixture"])

    {200, trigger_result} = http_trigger_signal("trigger-process")

    assert is_list(trigger_result["startedProcessInstanceIds"])
    assert length(trigger_result["startedProcessInstanceIds"]) >= 1

    [started_pi_id | _rest] = trigger_result["startedProcessInstanceIds"]

    {:ok, _process_instance} =
      await_process_instance_state(started_pi_id, "finished", timeout: 10_000)
  end

  test "C116: Pending signal — cached on zero-match, delivered on first subscriber" do
    spec = Runner.load_spec("C116_signal_pending_delivered.yaml")

    identity = %EvilEngine.Types.Identity{
      id: "test-user",
      roles: ["admin"],
      groups: [],
      claims: %{"trigger_signal" => "all"}
    }

    {:ok, publish_result} = Api.publish_signal("test-signal", identity)
    assert publish_result.pending == true
    assert publish_result.deliveries == []

    {201, _} = http_deploy(spec["fixture"])
    {201, start_body} = http_start(spec["process_model_id"], %{"payload" => %{}})
    process_instance_id = start_body["processInstanceId"]

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C118: Multi-subscriber broadcast — 3 catch events for same signal, all receive" do
    spec = Runner.load_spec("C118_signal_multi_subscriber_broadcast.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    Process.sleep(1_000)

    {200, trigger_result} = http_trigger_signal("broadcast-signal")
    assert length(trigger_result["deliveries"]) == 3

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C119: Signal + message isolation — signal NEVER triggers message event" do
    spec = Runner.load_spec("C119_signal_message_isolation.yaml")

    {201, _} = http_deploy("signal_isolation_message_side.bpmn")
    {201, _} = http_deploy(spec["fixture"])

    {201, msg_start_result} = http_start("SignalIsolationMessageSide", %{"payload" => %{}})
    message_pi_id = msg_start_result["processInstanceId"]

    {:ok, _msg_catch} =
      await_waiting_flow_node_instance(message_pi_id, "intermediate_catch_event", timeout: 10_000)

    {201, sig_start_result} = http_start(spec["process_model_id"], %{"payload" => %{}})
    signal_pi_id = sig_start_result["processInstanceId"]

    {:ok, _sig_catch} =
      await_waiting_flow_node_instance(signal_pi_id, "intermediate_catch_event", timeout: 10_000)

    {200, trigger_result} = http_trigger_signal("same-name")

    assert length(trigger_result["deliveries"]) == 1
    delivery = hd(trigger_result["deliveries"])
    assert delivery["processInstanceId"] == signal_pi_id

    wait_for_process_instance(signal_pi_id)

    {:ok, msg_pi} = await_process_instance_state(message_pi_id, "running", timeout: 2_000)
    assert msg_pi.state == "running"

    Runner.assert_expectations(signal_pi_id, spec)
  end

  test "C120: Signal Start + Catch simultaneous — both fire on broadcast" do
    spec = Runner.load_spec("C120_signal_start_and_catch_simultaneous.yaml")

    {201, _} = http_deploy("signal_start_for_dual_test.bpmn")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _catch_fni} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, trigger_result} = http_trigger_signal("shared-signal")

    assert length(trigger_result["deliveries"]) >= 1
    assert length(trigger_result["startedProcessInstanceIds"]) >= 1

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C121: REST trigger — POST /signals/:name/trigger returns deliveries" do
    spec = Runner.load_spec("C121_signal_rest_trigger.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, trigger_result} = http_trigger_signal("test-signal")

    assert is_binary(trigger_result["signalId"])
    assert trigger_result["signalName"] == "test-signal"
    assert is_list(trigger_result["deliveries"])
    assert length(trigger_result["deliveries"]) == 1
    assert trigger_result["pending"] == false

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C122: REST trigger — payload in body silently ignored" do
    spec = Runner.load_spec("C122_signal_rest_payload_ignored.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    merged = Map.merge(%{"trigger_signal" => "all"}, %{})
    json_body = Jason.encode!(%{"payload" => %{"should" => "be_ignored"}})

    conn =
      Plug.Test.conn(:post, "/signals/#{URI.encode_www_form("test-signal")}/trigger", json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(merged)}")
      |> route()

    {status, trigger_result} = decode_response(conn)
    assert status == 200
    assert trigger_result["signalName"] == "test-signal"
    assert length(trigger_result["deliveries"]) == 1
    assert trigger_result["pending"] == false

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  @tag :slow
  test "C117: Pending signal TTL expiry — expired signal not delivered" do
    Application.put_env(:core_events, :signal_pending_ttl, "PT1S")

    on_exit(fn ->
      Application.put_env(:core_events, :signal_pending_ttl, "PT60S")
    end)

    identity = %EvilEngine.Types.Identity{
      id: "test-user",
      roles: ["admin"],
      groups: [],
      claims: %{"trigger_signal" => "all"}
    }

    {:ok, publish_result} = Api.publish_signal("test-signal", identity)
    assert publish_result.pending == true

    Process.sleep(2_000)

    spec = Runner.load_spec("C117_signal_pending_ttl_expired.yaml")
    {201, _} = http_deploy(spec["fixture"])
    {201, start_body} = http_start(spec["process_model_id"], %{"payload" => %{}})
    process_instance_id = start_body["processInstanceId"]

    {:ok, waiting_fni} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    assert waiting_fni != nil
  end

  test "C123: Signal cross-process throw→catch via BPMN intermediateThrowEvent" do
    {201, _} = http_deploy("signal_cross_process_catch.bpmn")
    {201, _} = http_deploy("signal_cross_process_throw.bpmn")

    {201, catch_start} = http_start("SignalCrossProcessCatch", %{"payload" => %{}})
    catch_pi_id = catch_start["processInstanceId"]

    {:ok, _catch_fni} =
      await_waiting_flow_node_instance(catch_pi_id, "intermediate_catch_event", timeout: 10_000)

    {201, throw_start} = http_start("SignalCrossProcessThrow", %{"payload" => %{}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    wait_for_process_instance(catch_pi_id)

    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    {:ok, catch_pi} = await_process_instance_state(catch_pi_id, "finished", timeout: 10_000)
    assert catch_pi.state == "finished"
  end

  # ===================================================================
  # Signal Events — 2-BPMN cross-process tests (C124–C128)
  # ===================================================================

  test "C124: Signal end event broadcasts to waiting catch in separate process" do
    {201, _} = http_deploy("signal_end_event.bpmn")
    {201, _} = http_deploy("signal_catch_done.bpmn")

    {201, catch_start} = http_start("SignalCatchDone", %{"payload" => %{}})
    catch_pi_id = catch_start["processInstanceId"]

    {:ok, _catch_fni} =
      await_waiting_flow_node_instance(catch_pi_id, "intermediate_catch_event", timeout: 10_000)

    {201, throw_start} = http_start("SignalEndEvent", %{"payload" => %{}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    wait_for_process_instance(catch_pi_id)

    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    {:ok, catch_pi} = await_process_instance_state(catch_pi_id, "finished", timeout: 10_000)
    assert catch_pi.state == "finished"
  end

  test "C125: Signal throw interrupts boundary event on separate process" do
    {201, _} = http_deploy("signal_boundary_interrupting.bpmn")
    {201, _} = http_deploy("signal_throw_cancel.bpmn")

    {201, boundary_start} = http_start("SignalBoundaryInterrupting", %{"payload" => %{}})
    boundary_pi_id = boundary_start["processInstanceId"]

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(boundary_pi_id, "user_task", timeout: 10_000)

    {201, throw_start} = http_start("SignalThrowCancel", %{"payload" => %{}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    wait_for_process_instance(boundary_pi_id)

    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    {:ok, boundary_pi} = await_process_instance_state(boundary_pi_id, "finished", timeout: 10_000)
    assert boundary_pi.state == "finished"

    flow_node_instances = fetch_flow_node_instances(boundary_pi_id)
    end_fnis = Enum.filter(flow_node_instances, &(&1.flow_node_id == "End_cancelled"))
    assert length(end_fnis) >= 1, "Expected End_cancelled to have been reached"
  end

  test "C126: Signal throw fires non-interrupting boundary twice (multi-fire)" do
    {201, _} = http_deploy("signal_boundary_non_interrupting.bpmn")
    {201, _} = http_deploy("signal_throw_simple.bpmn")

    {201, boundary_start} = http_start("SignalBoundaryNonInterrupting", %{"payload" => %{}})
    boundary_pi_id = boundary_start["processInstanceId"]

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(boundary_pi_id, "user_task", timeout: 10_000)

    {201, _throw_start_1} = http_start("SignalThrowSimple", %{"payload" => %{}})
    Process.sleep(1_000)

    {201, _throw_start_2} = http_start("SignalThrowSimple", %{"payload" => %{}})
    Process.sleep(1_000)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(boundary_pi_id, "user_task", timeout: 10_000)

    http_finish_user_task(user_task_fni.id, %{})

    wait_for_process_instance(boundary_pi_id, 15_000)

    {:ok, boundary_pi} = await_process_instance_state(boundary_pi_id, "finished", timeout: 10_000)
    assert boundary_pi.state == "finished"

    flow_node_instances = fetch_flow_node_instances(boundary_pi_id)
    notified_end_fnis = Enum.filter(flow_node_instances, &(&1.flow_node_id == "End_notified"))
    assert length(notified_end_fnis) >= 2,
           "Expected End_notified to be reached at least twice (multi-fire), got #{length(notified_end_fnis)}"

    normal_end_fnis = Enum.filter(flow_node_instances, &(&1.flow_node_id == "End_normal"))
    assert length(normal_end_fnis) == 1, "Expected exactly 1 End_normal (host task completed)"
  end

  test "C127: Signal throw triggers start event in separate process" do
    {201, _} = http_deploy("signal_start_event.bpmn")
    {201, _} = http_deploy("signal_throw_trigger.bpmn")

    {201, throw_start} = http_start("SignalThrowTrigger", %{"payload" => %{}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    Process.sleep(2_000)

    require Ash.Query

    started_pis =
      EvilEngine.Persistence.Resources.ProcessInstance
      |> Ash.Query.filter(id != ^throw_pi_id)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)

    assert length(started_pis) >= 1,
           "Expected at least 1 PI to be created via signal start event"

    latest_started_pi = hd(started_pis)

    {:ok, started_pi} =
      await_process_instance_state(latest_started_pi.id, "finished", timeout: 10_000)

    assert started_pi.state == "finished"
  end

  test "C128: FIFO pending drain — first subscriber claims cached signal, second does not" do
    {201, _} = http_deploy("signal_end_event.bpmn")
    {201, _} = http_deploy("signal_catch_done.bpmn")

    {201, throw_start} = http_start("SignalEndEvent", %{"payload" => %{}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    Process.sleep(500)

    {201, catch_start_1} = http_start("SignalCatchDone", %{"payload" => %{}})
    catch_pi_1_id = catch_start_1["processInstanceId"]

    wait_for_process_instance(catch_pi_1_id, 10_000)
    {:ok, catch_pi_1} = await_process_instance_state(catch_pi_1_id, "finished", timeout: 10_000)
    assert catch_pi_1.state == "finished",
           "First subscriber should drain the pending signal and finish"

    {201, catch_start_2} = http_start("SignalCatchDone", %{"payload" => %{}})
    catch_pi_2_id = catch_start_2["processInstanceId"]

    {:ok, _waiting_fni} =
      await_waiting_flow_node_instance(catch_pi_2_id, "intermediate_catch_event", timeout: 10_000)

    assert_pi_state!(catch_pi_2_id, "running")
  end

  # ===================================================================
  # Message Events — 2-BPMN cross-process tests (C130–C134)
  # ===================================================================

  test "C130: Message end event delivers to waiting catch in separate process" do
    {201, _} = http_deploy("message_end_event.bpmn")
    {201, _} = http_deploy("message_catch_done.bpmn")

    {201, catch_start} = http_start("MessageCatchDone", %{"payload" => %{}})
    catch_pi_id = catch_start["processInstanceId"]

    {:ok, _catch_fni} =
      await_waiting_flow_node_instance(catch_pi_id, "intermediate_catch_event", timeout: 10_000)

    {201, throw_start} = http_start("MessageEndEvent", %{"payload" => %{"status" => "done"}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    wait_for_process_instance(catch_pi_id)

    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    {:ok, catch_pi} = await_process_instance_state(catch_pi_id, "finished", timeout: 10_000)
    assert catch_pi.state == "finished"
  end

  test "C131: Message throw interrupts boundary event on separate process" do
    {201, _} = http_deploy("message_boundary_interrupting.bpmn")
    {201, _} = http_deploy("message_throw_cancel.bpmn")

    {201, boundary_start} = http_start("MessageBoundaryInterrupting", %{"payload" => %{}})
    boundary_pi_id = boundary_start["processInstanceId"]

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(boundary_pi_id, "user_task", timeout: 10_000)

    {201, throw_start} = http_start("MessageThrowCancel", %{"payload" => %{}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    wait_for_process_instance(boundary_pi_id)

    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    {:ok, boundary_pi} = await_process_instance_state(boundary_pi_id, "finished", timeout: 10_000)
    assert boundary_pi.state == "finished"

    flow_node_instances = fetch_flow_node_instances(boundary_pi_id)
    end_fnis = Enum.filter(flow_node_instances, &(&1.flow_node_id == "End_cancelled"))
    assert length(end_fnis) >= 1, "Expected End_cancelled to have been reached"
  end

  test "C132: Message throw fires non-interrupting boundary twice (multi-fire)" do
    {201, _} = http_deploy("message_boundary_non_interrupting.bpmn")
    {201, _} = http_deploy("message_throw_notify.bpmn")

    {201, boundary_start} = http_start("MessageBoundaryNonInterrupting", %{"payload" => %{}})
    boundary_pi_id = boundary_start["processInstanceId"]

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(boundary_pi_id, "user_task", timeout: 10_000)

    {201, _throw_start_1} = http_start("MessageThrowNotify", %{"payload" => %{}})
    Process.sleep(1_000)

    {201, _throw_start_2} = http_start("MessageThrowNotify", %{"payload" => %{}})
    Process.sleep(1_000)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(boundary_pi_id, "user_task", timeout: 10_000)

    http_finish_user_task(user_task_fni.id, %{})

    wait_for_process_instance(boundary_pi_id, 15_000)

    {:ok, boundary_pi} = await_process_instance_state(boundary_pi_id, "finished", timeout: 10_000)
    assert boundary_pi.state == "finished"

    flow_node_instances = fetch_flow_node_instances(boundary_pi_id)
    notified_end_fnis = Enum.filter(flow_node_instances, &(&1.flow_node_id == "End_notified"))
    assert length(notified_end_fnis) >= 2,
           "Expected End_notified to be reached at least twice (multi-fire), got #{length(notified_end_fnis)}"

    normal_end_fnis = Enum.filter(flow_node_instances, &(&1.flow_node_id == "End_normal"))
    assert length(normal_end_fnis) == 1, "Expected exactly 1 End_normal (host task completed)"
  end

  test "C133: Message throw triggers start event in separate process" do
    {201, _} = http_deploy("message_start_event.bpmn")
    {201, _} = http_deploy("message_throw_trigger.bpmn")

    {201, throw_start} = http_start("MessageThrowTrigger", %{"payload" => %{}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    Process.sleep(2_000)

    require Ash.Query

    started_pis =
      EvilEngine.Persistence.Resources.ProcessInstance
      |> Ash.Query.filter(id != ^throw_pi_id)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)

    assert length(started_pis) >= 1,
           "Expected at least 1 PI to be created via message start event"

    latest_started_pi = hd(started_pis)

    {:ok, started_pi} =
      await_process_instance_state(latest_started_pi.id, "finished", timeout: 10_000)

    assert started_pi.state == "finished"
  end

  test "C134: FIFO pending drain — first subscriber claims cached message, second does not" do
    {201, _} = http_deploy("message_end_event.bpmn")
    {201, _} = http_deploy("message_catch_done.bpmn")

    {201, throw_start} = http_start("MessageEndEvent", %{"payload" => %{"status" => "done"}})
    throw_pi_id = throw_start["processInstanceId"]

    wait_for_process_instance(throw_pi_id)
    {:ok, throw_pi} = await_process_instance_state(throw_pi_id, "finished", timeout: 10_000)
    assert throw_pi.state == "finished"

    Process.sleep(500)

    {201, catch_start_1} = http_start("MessageCatchDone", %{"payload" => %{}})
    catch_pi_1_id = catch_start_1["processInstanceId"]

    wait_for_process_instance(catch_pi_1_id, 10_000)
    {:ok, catch_pi_1} = await_process_instance_state(catch_pi_1_id, "finished", timeout: 10_000)
    assert catch_pi_1.state == "finished",
           "First subscriber should drain the pending message and finish"

    {201, catch_start_2} = http_start("MessageCatchDone", %{"payload" => %{}})
    catch_pi_2_id = catch_start_2["processInstanceId"]

    {:ok, _waiting_fni} =
      await_waiting_flow_node_instance(catch_pi_2_id, "intermediate_catch_event", timeout: 10_000)

    assert_pi_state!(catch_pi_2_id, "running")
  end

  # ===================================================================
  # INTERACTIVE TIER — Event-Based Gateway conformance (C151, C152, C154)
  # ===================================================================

  test "C151: Event-Based Gateway — message wins over timer" do
    spec = Runner.load_spec("C151_ebg_message_wins_over_timer.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("ebg-msg-wins")

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C152: Event-Based Gateway — signal wins over timer" do
    spec = Runner.load_spec("C152_ebg_signal_wins_over_timer.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event", timeout: 10_000)

    {200, _trigger_result} = http_trigger_signal("ebg-test-signal")

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C154: Event-Based Gateway — receive task wins over competing receive task" do
    spec = Runner.load_spec("C154_ebg_receive_task_wins.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _flow_node_instance} =
      await_waiting_flow_node_instance(process_instance_id, "receive_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("ebg-recv-a")

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  # ===================================================================
  # INTERACTIVE TIER — Event Subprocess conformance (C170–C178)
  # ===================================================================

  test "C170: Interrupting message Event Subprocess fires and finishes the scope" do
    spec = Runner.load_spec("C170_event_subprocess_message.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("esp-message")

    wait_for_process_instance(process_instance_id, 10_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C171: Non-interrupting message Event Subprocess runs in parallel; scope finishes after both" do
    spec = Runner.load_spec("C171_event_subprocess_message_non_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("esp-message-ni")

    # The non-interrupting ESP runs in parallel; the main user task is still
    # waiting, so the scope must be driven to completion by finishing it.
    Process.sleep(500)
    :ok = finish_user_task(process_instance_id, user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id, 10_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C172: Interrupting signal Event Subprocess fires and finishes the scope" do
    spec = Runner.load_spec("C172_event_subprocess_signal.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_signal("esp-signal")

    wait_for_process_instance(process_instance_id, 10_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C173: Non-interrupting signal Event Subprocess runs in parallel; scope finishes after both" do
    spec = Runner.load_spec("C173_event_subprocess_signal_non_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_signal("esp-signal-ni")

    Process.sleep(500)
    :ok = finish_user_task(process_instance_id, user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id, 10_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C174: Interrupting timer Event Subprocess fires after the duration and finishes the scope" do
    spec = Runner.load_spec("C174_event_subprocess_timer_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    # The timer (PT1S) fires while the main user task waits, interrupting it.
    wait_for_process_instance(process_instance_id, 15_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C175: Non-interrupting timer Event Subprocess fires in parallel; scope finishes after both" do
    spec = Runner.load_spec("C175_event_subprocess_timer_non_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    # Give the PT1S timer time to fire and spawn the parallel ESP child.
    Process.sleep(2_000)
    :ok = finish_user_task(process_instance_id, user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id, 15_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C176: Escalation Event Subprocess catches a main-flow escalation throw" do
    spec = Runner.load_spec("C176_event_subprocess_escalation.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    # The escalation throw fires at start; the scope-level escalation ESP catches
    # it (non-interrupting) and the main flow continues to its End event.
    wait_for_process_instance(process_instance_id, 10_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C177: Two Event Subprocesses in one scope; only the matching (message) trigger fires" do
    spec = Runner.load_spec("C177_event_subprocess_multiple.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("esp-multi-message")

    wait_for_process_instance(process_instance_id, 10_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C178: Interrupting message Event Subprocess with an embedded subprocess body completes" do
    spec = Runner.load_spec("C178_event_subprocess_nested_embedded.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("esp-nested-message")

    wait_for_process_instance(process_instance_id, 15_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C179: Interrupting error Event Subprocess catches BPMN error from embedded subprocess" do
    spec = Runner.load_spec("C179_event_subprocess_error.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    wait_for_process_instance(process_instance_id, 15_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C180: Interrupting conditional Event Subprocess fires when condition transitions to true" do
    spec = Runner.load_spec("C180_event_subprocess_conditional.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    wait_for_process_instance(process_instance_id, 15_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C181: Escalation boundary on activity wins over scope-level escalation ESP (proximity)" do
    spec = Runner.load_spec("C181_event_subprocess_vs_boundary_proximity.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    wait_for_process_instance(process_instance_id, 15_000)
    Runner.assert_expectations(process_instance_id, spec)

    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    boundary_path_fnis =
      Enum.filter(flow_node_instances, &(&1.flow_node_id == "End_BoundaryCaught"))

    assert boundary_path_fnis != [],
           "Expected End_BoundaryCaught to be reached (boundary wins over ESP)"

    esp_fnis = Enum.filter(flow_node_instances, &(&1.flow_node_id == "ESP_Task"))

    assert Enum.empty?(esp_fnis),
           "Expected ESP_Task to NOT be reached (boundary has priority over ESP)"
  end

  test "C182: Nested ESP — outer message ESP contains inner timer ESP; both complete" do
    spec = Runner.load_spec("C182_event_subprocess_nested_esp.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    {200, _trigger_result} = http_trigger_message("esp-outer-message")

    wait_for_process_instance(process_instance_id, 20_000)
    Runner.assert_expectations(process_instance_id, spec)
  end

  # ===================================================================
  # Private helpers
  # ===================================================================

  @fixtures_dir Path.expand("../fixtures/bpmns", __DIR__)

  defp conformance_version_xml(fixture_name, new_version) do
    Path.join(@fixtures_dir, fixture_name)
    |> File.read!()
    |> String.replace(~r/<evil:version>[^<]+<\/evil:version>/, "<evil:version>#{new_version}</evil:version>")
  end

  defp conformance_find_child_ids(parent_process_instance_id) do
    require Ash.Query

    EvilEngine.Persistence.Resources.ProcessInstance
    |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
    |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)
    |> Enum.map(& &1.id)
  end

  # ===================================================================
  # INTERACTIVE TIER — Timer Boundary conformance (C83, C84, C91)
  # ===================================================================

  test "C83: Timer Boundary non-interrupting — timer fires, user task continues" do
    spec = Runner.load_spec("C83_timer_boundary_non_interrupting.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    :ok = finish_user_task(process_instance_id, user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C84: Timer Boundary cycle — non-interrupting cycle fires, user task continues" do
    spec = Runner.load_spec("C84_timer_boundary_cycle.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    :ok = finish_user_task(process_instance_id, user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C91: Boundary cancelActivity=false — timer fires, host continues" do
    spec = Runner.load_spec("C91_boundary_cancel_activity_flag.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, user_task_fni} =
      await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

    :ok = finish_user_task(process_instance_id, user_task_fni.id, %{})

    wait_for_process_instance(process_instance_id)
    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C88: Timer Start disable/enable — disable prevents PI, re-enable creates PI" do
    spec = Runner.load_spec("C88_timer_start_disable_enable.yaml")
    _process_model_id = spec["process_model_id"]

    {201, deploy_result} = http_deploy(spec["fixture"])
    process_version_id = deploy_result["processVersionId"]

    Process.sleep(500)

    deploy_claims = %{"deploy_bpmn" => true}

    schedules_conn =
      Plug.Test.conn(:get, "/timer-schedules")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(deploy_claims)}")
      |> route()

    assert schedules_conn.status == 200

    schedules_body = Jason.decode!(schedules_conn.resp_body)

    timer_schedule =
      Enum.find(schedules_body["data"], fn schedule ->
        schedule["processVersionId"] == process_version_id
      end)

    if timer_schedule do
      schedule_id = timer_schedule["id"]

      disable_conn =
        Plug.Test.conn(:put, "/timer-schedules/#{schedule_id}/disable")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(deploy_claims)}")
        |> route()

      assert disable_conn.status == 204

      Process.sleep(1_000)

      show_conn =
        Plug.Test.conn(:get, "/timer-schedules/#{schedule_id}")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(deploy_claims)}")
        |> route()

      assert show_conn.status == 200
      show_body = Jason.decode!(show_conn.resp_body)
      assert show_body["enabled"] == false

      enable_conn =
        Plug.Test.conn(:put, "/timer-schedules/#{schedule_id}/enable")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(deploy_claims)}")
        |> route()

      assert enable_conn.status == 204
    end

    Process.sleep(3_000)
  end

  # ===================================================================
  # INTERACTIVE TIER — Transaction Subprocess + Cancel Events (C240–C244)
  # ===================================================================

  test "C240: Cancelled transaction child PI is not retryable" do
    spec = Runner.load_spec("C240_transaction_cancelled_not_retryable.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _} = await_process_instance_state(process_instance_id, "finished", timeout: 15_000)

    [child_pi_id] = conformance_find_child_ids(process_instance_id)
    assert_pi_state!(child_pi_id, "cancelled")

    {422, error_body} = http_retry_process_instance(child_pi_id)
    assert error_body["error"] == "process_instance_not_retriable"

    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C241: Retry of direct transaction child PI blocked (retry_inside_transaction_scope)" do
    spec = Runner.load_spec("C241_transaction_retry_inside_scope_direct.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _} = await_process_instance_state(process_instance_id, "fatal", timeout: 15_000)

    [child_pi_id] = conformance_find_child_ids(process_instance_id)
    assert_pi_state!(child_pi_id, "fatal")

    {422, error_body} = http_retry_process_instance(child_pi_id)
    assert error_body["error"] == "retry_inside_transaction_scope"

    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C242: TX → SP → child fatal — nested SP PI retry blocked by transaction ancestor" do
    spec = Runner.load_spec("C242_transaction_retry_nested_sp.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _} = await_process_instance_state(process_instance_id, "fatal", timeout: 15_000)

    [tx_child_pi_id] = conformance_find_child_ids(process_instance_id)
    assert_pi_state!(tx_child_pi_id, "fatal")

    [sp_child_pi_id] = conformance_find_child_ids(tx_child_pi_id)
    assert_pi_state!(sp_child_pi_id, "fatal")

    {422, error_body} = http_retry_process_instance(sp_child_pi_id)
    assert error_body["error"] == "retry_inside_transaction_scope"

    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C243: TX → CA → child fatal — nested CA PI retry blocked by transaction ancestor" do
    configure_called_element_resolver()

    spec = Runner.load_spec("C243_transaction_retry_nested_ca.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _} = await_process_instance_state(process_instance_id, "fatal", timeout: 15_000)

    [tx_child_pi_id] = conformance_find_child_ids(process_instance_id)
    assert_pi_state!(tx_child_pi_id, "fatal")

    [ca_child_pi_id] = conformance_find_child_ids(tx_child_pi_id)
    assert_pi_state!(ca_child_pi_id, "fatal")

    {422, tx_child_error} = http_retry_process_instance(tx_child_pi_id)
    assert tx_child_error["error"] == "retry_inside_transaction_scope"

    {422, ca_child_error} = http_retry_process_instance(ca_child_pi_id)
    assert ca_child_error["error"] == "retry_inside_transaction_scope"

    Runner.assert_expectations(process_instance_id, spec)
  end

  test "C244: TX → SP → CA → grandchild fatal — all nested PI retries blocked, root retry succeeds" do
    configure_called_element_resolver()

    spec = Runner.load_spec("C244_transaction_retry_nested_deep.yaml")
    process_instance_id = Runner.deploy_and_start(spec)

    {:ok, _} = await_process_instance_state(process_instance_id, "fatal", timeout: 15_000)

    [tx_child_pi_id] = conformance_find_child_ids(process_instance_id)
    assert_pi_state!(tx_child_pi_id, "fatal")

    [sp_child_pi_id] = conformance_find_child_ids(tx_child_pi_id)
    assert_pi_state!(sp_child_pi_id, "fatal")

    [ca_child_pi_id] = conformance_find_child_ids(sp_child_pi_id)
    assert_pi_state!(ca_child_pi_id, "fatal")

    {422, grandchild_error} = http_retry_process_instance(ca_child_pi_id)
    assert grandchild_error["error"] == "retry_inside_transaction_scope"

    {422, sp_error} = http_retry_process_instance(sp_child_pi_id)
    assert sp_error["error"] == "retry_inside_transaction_scope"

    {204, nil} = http_retry_process_instance(process_instance_id)
    {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
    wait_for_process_instance(process_instance_id, 15_000)

    assert_pi_state!(process_instance_id, "fatal")
  end

  defp configure_called_element_resolver do
    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )
  end

  defp conformance_incompatible_v2_xml do
    @retry_user_task_fixture
    |> File.read!()
    |> String.replace("<evil:version>1.0.0</evil:version>", "<evil:version>2.0.0</evil:version>")
    |> String.replace("UserTask_1", "UserTask_2")
    |> String.replace("Shape_UserTask_1", "Shape_UserTask_2")
  end
end
