defmodule EvilEngine.Integration.Execution.RetryTest do
  @moduledoc """
  Integration tests for `PUT /process-instances/:id/retry` (PI retry/restart).

  Exercises terminal-state retry, version migration, authorization, Call Activity
  tree semantics, and concurrent retry rejection — all via authenticated HTTP.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Persistence.Resources.FlowNodeInstance, as: FlowNodeInstanceResource
  alias EvilEngine.Persistence.Resources.ProcessInstance, as: ProcessInstanceResource

  @bpmn_fixtures_dir Path.expand("../../fixtures/bpmns", __DIR__)
  @retry_user_task_fixture Path.join(@bpmn_fixtures_dir, "retry_user_task.bpmn")
  @retry_fatal_dead_end_fixture Path.join(@bpmn_fixtures_dir, "retry_fatal_dead_end.bpmn")
  @retry_checkpoint_linear_fixture Path.join(@bpmn_fixtures_dir, "retry_checkpoint_linear.bpmn")
  @persistence_domain EvilEngine.Persistence.Api

  setup do
    original_resolver = Application.get_env(:core_execution, :called_element_resolver)

    Application.put_env(
      :core_execution,
      :called_element_resolver,
      EvilEngine.Persistence.CalledElementResolverImpl
    )

    on_exit(fn ->
      if original_resolver do
        Application.put_env(:core_execution, :called_element_resolver, original_resolver)
      else
        Application.delete_env(:core_execution, :called_element_resolver)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # I1–I2, I7–I9: Basic retry
  # ---------------------------------------------------------------------------

  describe "I1: basic retry from fatal" do
    test "retries a fatal PI and re-executes until fatal again" do
      process_instance_id = deploy_and_fatal("retry_fatal_dead_end.bpmn", "RetryFatalDeadEnd")

      process_instance_before = assert_pi_state!(process_instance_id, "fatal")
      finished_at_before = process_instance_before.finished_at
      assert finished_at_before != nil

      {204, nil} = http_retry_process_instance(process_instance_id)

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
      wait_for_process_instance(process_instance_id, 10_000)

      process_instance_after = assert_pi_state!(process_instance_id, "fatal")
      assert process_instance_after.finished_at != nil
      assert DateTime.compare(process_instance_after.finished_at, finished_at_before) in [:gt, :eq]
    end
  end

  describe "I2: basic retry from aborted" do
    test "retries an aborted PI, resumes at UserTask, and can finish" do
      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, body} = http_start("RetryUserTask")
      process_instance_id = body["processInstanceId"]

      {:ok, _user_task_fni} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      {204, nil} =
        http_abort_process_instance(process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, 5_000)
      assert_pi_state!(process_instance_id, "aborted")

      {204, nil} = http_retry_process_instance(process_instance_id)

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)

      {:ok, waiting_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      assert waiting_user_task_fni.state == "waiting"

      {204, nil} = http_finish_user_task(waiting_user_task_fni.id, %{"done" => true})
      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  describe "I6: retry from checkpoint FNI" do
    test "resets at Task_A, deletes downstream FNIs, and re-fatals at Task_DeadEnd" do
      process_instance_id = deploy_and_fatal("retry_checkpoint_linear.bpmn", "RetryCheckpointLinear")

      flow_node_instances_before = fetch_flow_node_instances(process_instance_id)

      task_a_flow_node_instance =
        find_fni_by_flow_node_id(process_instance_id, "Task_A")

      task_b_flow_node_instance =
        find_fni_by_flow_node_id(process_instance_id, "Task_B")

      task_dead_end_flow_node_instance =
        find_fni_by_flow_node_id(process_instance_id, "Task_DeadEnd")

      assert task_a_flow_node_instance != nil
      assert task_b_flow_node_instance != nil
      assert task_dead_end_flow_node_instance != nil

      task_a_flow_node_instance_id = task_a_flow_node_instance.id
      task_b_flow_node_instance_id = task_b_flow_node_instance.id
      task_dead_end_flow_node_instance_id = task_dead_end_flow_node_instance.id

      {204, nil} =
        http_retry_process_instance(process_instance_id, %{
          "resetToFlowNodeInstanceId" => task_a_flow_node_instance_id
        })

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
      wait_for_process_instance(process_instance_id, 10_000)

      assert_pi_state!(process_instance_id, "fatal")

      flow_node_instances_after = fetch_flow_node_instances(process_instance_id)
      flow_node_instance_ids_after = Enum.map(flow_node_instances_after, & &1.id)

      refute task_b_flow_node_instance_id in flow_node_instance_ids_after
      refute task_dead_end_flow_node_instance_id in flow_node_instance_ids_after

      task_a_flow_node_instance_after =
        Enum.find(flow_node_instances_after, &(&1.flow_node_id == "Task_A"))

      assert task_a_flow_node_instance_after != nil
      assert task_a_flow_node_instance_after.id == task_a_flow_node_instance_id

      assert Enum.count(flow_node_instances_after) > length(flow_node_instances_before) - 2
    end
  end

  describe "I7: retry of running PI" do
    test "returns 422 process_instance_not_retriable" do
      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, body} = http_start("RetryUserTask")
      process_instance_id = body["processInstanceId"]

      {:ok, _user_task_fni} = await_waiting_flow_node_instance(process_instance_id, "user_task")
      assert_pi_state!(process_instance_id, "running")

      {422, error_body} = http_retry_process_instance(process_instance_id)
      assert error_body["error"] == "process_instance_not_retriable"
    end
  end

  describe "I8: retry of finished PI" do
    test "returns 422 process_instance_not_retriable" do
      process_instance_id = http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")
      wait_for_process_instance(process_instance_id, 5_000)
      assert_pi_state!(process_instance_id, "finished")

      {422, error_body} = http_retry_process_instance(process_instance_id)
      assert error_body["error"] == "process_instance_not_retriable"
    end
  end

  describe "I9: retry of deleted PI" do
    test "returns 404 not_found" do
      process_instance_id = http_deploy_and_start("linear_start_end.bpmn", "LinearStartEnd")
      wait_for_process_instance(process_instance_id, 5_000)

      {204, nil} = http_delete_process_instance(process_instance_id)

      {404, error_body} = http_retry_process_instance(process_instance_id)
      assert error_body["error"] == "not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # I3–I5, I16, I29: Version migration
  # ---------------------------------------------------------------------------

  describe "I3: compatible version migration" do
    test "retries onto a new compatible version" do
      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, body} = http_start("RetryUserTask")
      process_instance_id = body["processInstanceId"]

      {:ok, _user_task_fni} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      process_instance_v1 = fetch_process_instance!(process_instance_id)
      version_id_v1 = process_instance_v1.process_version_id

      {204, nil} =
        http_abort_process_instance(process_instance_id, "migrate test", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, 5_000)
      assert_pi_state!(process_instance_id, "aborted")

      {201, _} = http_deploy_xml(retry_user_task_version_xml("2.0.0"))
      version_id_v2 = version_id_for("RetryUserTask", "2.0.0")
      assert version_id_v2 != version_id_v1

      {204, nil} =
        http_retry_process_instance(process_instance_id, %{"version" => "2.0.0"})

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)

      process_instance_running = fetch_process_instance!(process_instance_id)
      assert process_instance_running.state == "running"
      assert process_instance_running.process_version_id == version_id_v2

      {:ok, waiting_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      {204, nil} = http_finish_user_task(waiting_user_task_fni.id, %{"done" => true})
      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  describe "I4: incompatible version migration" do
    test "returns 422 version_migration_incompatible" do
      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, body} = http_start("RetryUserTask")
      process_instance_id = body["processInstanceId"]

      {:ok, _user_task_fni} = await_waiting_flow_node_instance(process_instance_id, "user_task")

      {204, nil} =
        http_abort_process_instance(process_instance_id, "migrate test", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, 5_000)
      assert_pi_state!(process_instance_id, "aborted")

      {201, _} = http_deploy_xml(retry_user_task_incompatible_v2_xml())

      {422, error_body} =
        http_retry_process_instance(process_instance_id, %{"version" => "2.0.0"})

      assert error_body["error"] == "version_migration_incompatible"
      assert is_list(error_body["conflicts"])
      assert error_body["conflicts"] != []
    end
  end

  describe "I5: retry with latest version" do
    test "migrates to the latest deployed version" do
      {201, _} = http_deploy("retry_fatal_dead_end.bpmn")
      {201, body} = http_start("RetryFatalDeadEnd")
      process_instance_id = body["processInstanceId"]

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      version_id_v1 = fetch_process_instance!(process_instance_id).process_version_id

      {201, _} = http_deploy_xml(retry_fatal_dead_end_version_xml("2.0.0"))
      version_id_v2 = version_id_for("RetryFatalDeadEnd", "2.0.0")
      assert version_id_v2 != version_id_v1

      {204, nil} = http_retry_process_instance(process_instance_id, %{"version" => "latest"})

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
      wait_for_process_instance(process_instance_id, 10_000)

      process_instance_after = assert_pi_state!(process_instance_id, "fatal")
      assert process_instance_after.process_version_id == version_id_v2
    end
  end

  describe "I16: retry with checkpoint and version migration" do
    test "checkpoints at Task_A and migrates to compatible v2" do
      {201, _} = http_deploy("retry_checkpoint_linear.bpmn")
      {201, body} = http_start("RetryCheckpointLinear")
      process_instance_id = body["processInstanceId"]

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      wait_for_process_instance(process_instance_id, 10_000)

      process_instance_v1 = fetch_process_instance!(process_instance_id)
      version_id_v1 = process_instance_v1.process_version_id

      task_a_flow_node_instance =
        find_fni_by_flow_node_id(process_instance_id, "Task_A")

      assert task_a_flow_node_instance != nil

      {201, _} = http_deploy_xml(retry_checkpoint_linear_version_xml("2.0.0"))
      version_id_v2 = version_id_for("RetryCheckpointLinear", "2.0.0")
      assert version_id_v2 != version_id_v1

      {204, nil} =
        http_retry_process_instance(process_instance_id, %{
          "version" => "2.0.0",
          "resetToFlowNodeInstanceId" => task_a_flow_node_instance.id
        })

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
      wait_for_process_instance(process_instance_id, 10_000)

      process_instance_after = assert_pi_state!(process_instance_id, "fatal")
      assert process_instance_after.process_version_id == version_id_v2

      task_a_flow_node_instance_after =
        find_fni_by_flow_node_id(process_instance_id, "Task_A")

      assert task_a_flow_node_instance_after != nil
      assert task_a_flow_node_instance_after.id == task_a_flow_node_instance.id
    end
  end

  describe "I29: retry with disabled process" do
    test "returns 422 version_disabled when target process is disabled" do
      {201, _} = http_deploy("retry_fatal_dead_end.bpmn")
      {201, _} = http_deploy_xml(retry_fatal_dead_end_version_xml("2.0.0"))

      {201, body} = http_start("RetryFatalDeadEnd")
      process_instance_id = body["processInstanceId"]

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      {204, _} = http_disable("RetryFatalDeadEnd")

      {422, error_body} =
        http_retry_process_instance(process_instance_id, %{"version" => "2.0.0"})

      assert error_body["error"] == "version_disabled"
    end
  end

  # ---------------------------------------------------------------------------
  # I10–I13: Authorization
  # ---------------------------------------------------------------------------

  describe "I10: retry auth — no claim" do
    test "returns 403 forbidden" do
      process_instance_id = deploy_and_fatal("retry_fatal_dead_end.bpmn", "RetryFatalDeadEnd")

      {403, error_body} =
        http_retry_process_instance(process_instance_id, %{}, %{
          "retry_process_instance" => "none"
        })

      assert error_body["error"] == "forbidden"
      assert error_body["requiredClaim"] == "retry_process_instance"
    end
  end

  describe "I11: retry auth — own claim on own PI" do
    test "returns 204 when starter matches caller" do
      owner_claims = %{"sub" => "retry-owner"}

      {201, _} = http_deploy("retry_fatal_dead_end.bpmn")
      {201, body} = http_start("RetryFatalDeadEnd", %{}, owner_claims)
      process_instance_id = body["processInstanceId"]

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      retry_claims = %{"sub" => "retry-owner", "retry_process_instance" => "own"}

      {204, nil} = http_retry_process_instance(process_instance_id, %{}, retry_claims)
      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
    end
  end

  describe "I12: retry auth — own claim on other's PI" do
    test "returns 403 forbidden" do
      {201, _} = http_deploy("retry_fatal_dead_end.bpmn")
      {201, body} = http_start("RetryFatalDeadEnd", %{}, %{"sub" => "pi-owner"})
      process_instance_id = body["processInstanceId"]

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      {403, error_body} =
        http_retry_process_instance(process_instance_id, %{}, %{
          "sub" => "different-user",
          "retry_process_instance" => "own"
        })

      assert error_body["error"] == "forbidden"
    end
  end

  describe "I13: retry auth — all claim" do
    test "returns 204 regardless of starter" do
      {201, _} = http_deploy("retry_fatal_dead_end.bpmn")
      {201, body} = http_start("RetryFatalDeadEnd", %{}, %{"sub" => "original-starter"})
      process_instance_id = body["processInstanceId"]

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      {204, nil} =
        http_retry_process_instance(process_instance_id, %{}, %{
          "sub" => "admin-retrier",
          "retry_process_instance" => "all"
        })

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # I14–I15d, I22–I25, I23, I26, I32: Call Activity tree retry
  # ---------------------------------------------------------------------------

  describe "I14: implicit retry at Call Activity (child fatal)" do
    test "retrying parent resets fatal child in place (Scenario A)" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("retry_parent_with_failing_child.bpmn")

      {201, body} = http_start("RetryParentWithFailingChild")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _parent} =
        await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

      wait_for_process_instance(parent_process_instance_id, 15_000)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "fatal")

      child_start_fni =
        fetch_flow_node_instance_with_state!(child_process_instance_id, "Start_1", "finished")

      child_task_fni =
        fetch_flow_node_instance_with_state!(child_process_instance_id, "Task_1", "fatal")

      assert child_start_fni.id != child_task_fni.id

      {204, nil} = http_retry_process_instance(parent_process_instance_id)

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 5_000)

      wait_for_process_instance(parent_process_instance_id, 15_000)

      assert_pi_state!(parent_process_instance_id, "fatal")

      # Scenario A: child PI is reset in place, not hard-deleted.
      assert_pi_state!(child_process_instance_id, "fatal")

      child_flow_node_instances_after =
        fetch_flow_node_instances(child_process_instance_id)

      assert Enum.any?(child_flow_node_instances_after, &(&1.flow_node_id == "Start_1"))
      assert Enum.any?(child_flow_node_instances_after, &(&1.flow_node_id == "Task_1"))
    end
  end

  describe "I15: implicit retry at Call Activity (child aborted)" do
    test "retrying aborted parent restores child UserTask and completes tree" do
      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, _} = http_deploy("retry_parent_with_user_task_child.bpmn")

      {201, body} = http_start("RetryParentWithUserTaskChild")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)

      {204, nil} =
        http_abort_process_instance(parent_process_instance_id, "cascade abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "aborted")

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "aborted")

      {204, nil} = http_retry_process_instance(parent_process_instance_id)

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 5_000)

      {:ok, child_user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id, timeout: 15_000)

      child_process_instance_id = child_user_task_fni.process_instance_id
      assert {:ok, _child_pid} = poll_pi_alive(child_process_instance_id, 15_000)

      call_activity_fni_after_retry =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_fni_after_retry != nil
      assert call_activity_fni_after_retry.state == "waiting",
             "Call Activity FNI should be waiting while child runs, got: #{call_activity_fni_after_retry.state}"

      {204, nil} = http_finish_user_task(child_user_task_fni.id, %{"approved" => true})

      wait_for_process_instance(child_process_instance_id, 15_000)
      wait_for_process_instance(parent_process_instance_id, 15_000)

      assert_pi_state!(child_process_instance_id, "finished")
      assert_pi_state!(parent_process_instance_id, "finished")
    end
  end

  describe "I15b: finished child preserved on parent retry" do
    test "does not re-execute a child that already finished" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy("retry_parent_then_fatal.bpmn")

      {201, body} = http_start("RetryParentThenFatal")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _parent} =
        await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      child_before = assert_pi_state!(child_process_instance_id, "finished")
      child_finished_at_before = child_before.finished_at
      child_fni_count_before = length(fetch_flow_node_instances(child_process_instance_id))

      {204, nil} = http_retry_process_instance(parent_process_instance_id)

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 5_000)
      wait_for_process_instance(parent_process_instance_id, 15_000)

      assert_pi_state!(parent_process_instance_id, "fatal")

      child_after = assert_pi_state!(child_process_instance_id, "finished")
      assert child_after.finished_at == child_finished_at_before
      assert length(fetch_flow_node_instances(child_process_instance_id)) == child_fni_count_before
    end
  end

  describe "I15c: explicit retry at Call Activity checkpoint (Scenario B)" do
    test "checkpoint at Call Activity preserves child PI and resets it via Phase 2b" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("retry_parent_with_failing_child.bpmn")

      {201, body} = http_start("RetryParentWithFailingChild")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _parent} =
        await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

      wait_for_process_instance(parent_process_instance_id, 15_000)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "fatal")

      call_activity_flow_node_instance =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_flow_node_instance != nil
      call_activity_flow_node_instance_id = call_activity_flow_node_instance.id

      {204, nil} =
        http_retry_process_instance(parent_process_instance_id, %{
          "resetToFlowNodeInstanceId" => call_activity_flow_node_instance_id
        })

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 5_000)

      wait_for_process_instance(parent_process_instance_id, 15_000)

      # Scenario B: Call Activity FNI survives; child PI is preserved (not hard-deleted).
      assert fetch_process_instance!(child_process_instance_id) != nil

      assert_pi_state!(parent_process_instance_id, "fatal")
      assert_pi_state!(child_process_instance_id, "fatal")

      call_activity_flow_node_instance_after =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_flow_node_instance_after != nil
      assert call_activity_flow_node_instance_after.id == call_activity_flow_node_instance_id
    end
  end

  describe "I15d: retry before Call Activity checkpoint (Scenario C)" do
    test "checkpoint at Task_Before hard-deletes child PI and re-executes from Task_Before" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy("retry_parent_task_before_then_fatal.bpmn")

      {201, body} = http_start("RetryParentTaskBeforeThenFatal")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _parent} =
        await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

      wait_for_process_instance(parent_process_instance_id, 15_000)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "finished")

      task_before_flow_node_instance =
        find_fni_by_flow_node_id(parent_process_instance_id, "Task_Before")

      call_activity_flow_node_instance_before =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert task_before_flow_node_instance != nil
      assert call_activity_flow_node_instance_before != nil

      task_before_flow_node_instance_id = task_before_flow_node_instance.id
      call_activity_flow_node_instance_id_before = call_activity_flow_node_instance_before.id

      child_fni_ids_before = Enum.map(fetch_flow_node_instances(child_process_instance_id), & &1.id)

      {204, nil} =
        http_retry_process_instance(parent_process_instance_id, %{
          "resetToFlowNodeInstanceId" => task_before_flow_node_instance_id
        })

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 5_000)
      wait_for_process_instance(parent_process_instance_id, 15_000)

      # Re-run still reaches Task_DeadEnd (no outgoing flow) and fatals again.
      assert_pi_state!(parent_process_instance_id, "fatal")

      # Scenario C: old Call Activity FNI and everything after it were deleted; child PI cascade-deleted.
      assert_no_pi!(child_process_instance_id)

      Enum.each(child_fni_ids_before, fn child_fni_id ->
        assert fetch_flow_node_instance(child_fni_id) == nil
      end)

      assert fetch_flow_node_instance(call_activity_flow_node_instance_id_before) == nil

      parent_flow_node_instances_after = fetch_flow_node_instances(parent_process_instance_id)
      parent_flow_node_ids_after = Enum.map(parent_flow_node_instances_after, & &1.flow_node_id)

      assert "Task_Before" in parent_flow_node_ids_after
      assert "CA_1" in parent_flow_node_ids_after
      assert "Task_DeadEnd" in parent_flow_node_ids_after

      new_child_process_instance_ids =
        find_child_process_instance_ids(parent_process_instance_id)

      assert length(new_child_process_instance_ids) == 1
      refute hd(new_child_process_instance_ids) == child_process_instance_id
      assert_pi_state!(hd(new_child_process_instance_ids), "finished")
    end
  end

  describe "I22: tree retry from child PI" do
    test "retrying child PI also restarts parent and preserves child PI id" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("retry_parent_with_failing_child.bpmn")

      {201, body} = http_start("RetryParentWithFailingChild")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _parent} =
        await_process_instance_state(parent_process_instance_id, "fatal", timeout: 15_000)

      wait_for_process_instance(parent_process_instance_id, 15_000)

      assert_pi_state!(parent_process_instance_id, "fatal")

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "fatal")

      {204, nil} = http_retry_process_instance(child_process_instance_id)

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 5_000)

      wait_for_process_instance(parent_process_instance_id, 15_000)

      assert_pi_state!(parent_process_instance_id, "fatal")

      child_process_instance_ids_after =
        find_child_process_instance_ids(parent_process_instance_id)

      assert child_process_instance_id in child_process_instance_ids_after
      assert fetch_process_instance!(child_process_instance_id) != nil
    end
  end

  describe "I23: tree retry from child PI with checkpoint" do
    test "child checkpoint deletes downstream FNIs and restarts ancestor tree" do
      {201, _} = http_deploy("retry_checkpoint_linear.bpmn")
      {201, _} = http_deploy_xml(retry_parent_calling_process_xml("RetryParentWithCheckpointChild", "RetryCheckpointLinear"))

      {201, body} = http_start("RetryParentWithCheckpointChild")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _parent} =
        await_process_instance_state(parent_process_instance_id, "fatal", timeout: 20_000)

      wait_for_process_instance(parent_process_instance_id, 20_000)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "fatal")

      task_a_flow_node_instance =
        find_fni_by_flow_node_id(child_process_instance_id, "Task_A")

      task_b_flow_node_instance =
        find_fni_by_flow_node_id(child_process_instance_id, "Task_B")

      task_dead_end_flow_node_instance =
        find_fni_by_flow_node_id(child_process_instance_id, "Task_DeadEnd")

      assert task_a_flow_node_instance != nil
      assert task_b_flow_node_instance != nil
      assert task_dead_end_flow_node_instance != nil

      task_a_flow_node_instance_id = task_a_flow_node_instance.id
      task_b_flow_node_instance_id = task_b_flow_node_instance.id
      task_dead_end_flow_node_instance_id = task_dead_end_flow_node_instance.id

      {204, nil} =
        http_retry_process_instance(child_process_instance_id, %{
          "resetToFlowNodeInstanceId" => task_a_flow_node_instance_id
        })

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 5_000)

      wait_for_process_instance(parent_process_instance_id, 20_000)

      assert_pi_state!(parent_process_instance_id, "fatal")

      child_flow_node_instance_ids_after =
        fetch_flow_node_instances(child_process_instance_id) |> Enum.map(& &1.id)

      refute task_b_flow_node_instance_id in child_flow_node_instance_ids_after
      refute task_dead_end_flow_node_instance_id in child_flow_node_instance_ids_after

      task_a_flow_node_instance_after =
        find_fni_by_flow_node_id(child_process_instance_id, "Task_A")

      assert task_a_flow_node_instance_after != nil
      assert task_a_flow_node_instance_after.id == task_a_flow_node_instance_id
    end
  end

  describe "I24: tree retry from grandchild (three levels)" do
    test "retrying grandchild restarts entire tree and preserves PI ids" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("retry_parent_with_failing_child.bpmn")
      {201, _} = http_deploy("retry_nested_grandchild.bpmn")

      {201, body} = http_start("RetryNestedGrandchild")
      root_process_instance_id = body["processInstanceId"]

      {:ok, _root} =
        await_process_instance_state(root_process_instance_id, "fatal", timeout: 20_000)

      wait_for_process_instance(root_process_instance_id, 20_000)

      [mid_process_instance_id] = find_child_process_instance_ids(root_process_instance_id)

      [grandchild_process_instance_id] =
        find_child_process_instance_ids(mid_process_instance_id)

      assert_pi_state!(root_process_instance_id, "fatal")
      assert_pi_state!(mid_process_instance_id, "fatal")
      assert_pi_state!(grandchild_process_instance_id, "fatal")

      {204, nil} = http_retry_process_instance(grandchild_process_instance_id)

      assert {:ok, _root_pid} = poll_pi_alive(root_process_instance_id, 5_000)

      wait_for_process_instance(root_process_instance_id, 20_000)

      assert_pi_state!(root_process_instance_id, "fatal")

      mid_process_instance_ids_after =
        find_child_process_instance_ids(root_process_instance_id)

      assert mid_process_instance_id in mid_process_instance_ids_after
      assert fetch_process_instance!(mid_process_instance_id) != nil

      grandchild_process_instance_ids_after =
        find_child_process_instance_ids(mid_process_instance_id)

      assert grandchild_process_instance_id in grandchild_process_instance_ids_after
      assert fetch_process_instance!(grandchild_process_instance_id) != nil
    end
  end

  describe "I25: tree retry blocked when root PI is finished" do
    test "returns 422 root_process_instance_not_terminal" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("retry_parent_with_error_boundary.bpmn")

      {201, body} = http_start("RetryParentWithErrorBoundary")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _parent} =
        await_process_instance_state(parent_process_instance_id, "finished", timeout: 15_000)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      assert_pi_state!(child_process_instance_id, "fatal")

      {422, error_body} = http_retry_process_instance(child_process_instance_id)
      assert error_body["error"] == "root_process_instance_not_terminal"
      assert error_body["rootState"] == "finished"
      assert error_body["rootProcessInstanceId"] == parent_process_instance_id
    end
  end

  describe "I26: tree retry blocked when root PI is running" do
    test "returns 422 root_process_instance_not_terminal when root waits at UserTask" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      failing_child_version_id = version_id_for("FailingChildProcess", "1.0.0")

      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, body} = http_start("RetryUserTask")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _user_task_fni} =
        await_waiting_flow_node_instance(parent_process_instance_id, "user_task")

      assert_pi_state!(parent_process_instance_id, "running")

      orphan_child_process_instance_id =
        insert_fatal_child_process_instance(
          parent_process_instance_id,
          failing_child_version_id
        )

      assert_pi_state!(orphan_child_process_instance_id, "fatal")

      {422, error_body} = http_retry_process_instance(orphan_child_process_instance_id)

      assert error_body["error"] == "root_process_instance_not_terminal"
      assert error_body["rootState"] == "running"
      assert error_body["rootProcessInstanceId"] == parent_process_instance_id
    end
  end

  describe "I32: retry on running targeted child PI" do
    test "returns 422 process_instance_not_retriable with currentState running" do
      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, _} = http_deploy("retry_parent_with_user_task_child.bpmn")

      {201, body} = http_start("RetryParentWithUserTaskChild")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)
      child_process_instance_id = child_user_task_fni.process_instance_id

      assert_pi_state!(child_process_instance_id, "running")

      {422, error_body} = http_retry_process_instance(child_process_instance_id)

      assert error_body["error"] == "process_instance_not_retriable"
      assert error_body["currentState"] == "running"
    end
  end

  # ---------------------------------------------------------------------------
  # I17: Engine at capacity
  # ---------------------------------------------------------------------------

  describe "I17: engine at capacity blocks retry" do
    setup do
      previous_cap = Application.get_env(:core_execution, :max_concurrent_process_instances)

      on_exit(fn ->
        if previous_cap do
          Application.put_env(:core_execution, :max_concurrent_process_instances, previous_cap)
        else
          Application.delete_env(:core_execution, :max_concurrent_process_instances)
        end
      end)

      :ok
    end

    test "returns 503 engine_at_capacity when a running PI occupies the cap" do
      {201, _} = http_deploy("retry_user_task.bpmn")
      {201, running_body} = http_start("RetryUserTask")
      running_process_instance_id = running_body["processInstanceId"]

      {:ok, _user_task_fni} =
        await_waiting_flow_node_instance(running_process_instance_id, "user_task")

      fatal_process_instance_id =
        deploy_and_fatal("retry_fatal_dead_end.bpmn", "RetryFatalDeadEnd")

      Application.put_env(:core_execution, :max_concurrent_process_instances, 1)

      {503, error_body} = http_retry_process_instance(fatal_process_instance_id)

      assert error_body["error"] == "engine_at_capacity"
      assert error_body["active"] == 1
      assert error_body["limit"] == 1
    end
  end

  # ---------------------------------------------------------------------------
  # I30: Concurrent retry
  # ---------------------------------------------------------------------------

  describe "I30: concurrent retry" do
    test "exactly one retry succeeds and the other is rejected" do
      process_instance_id = deploy_and_fatal("retry_fatal_dead_end.bpmn", "RetryFatalDeadEnd")

      task_function = fn ->
        http_retry_process_instance(process_instance_id)
      end

      task_one = Task.async(task_function)
      task_two = Task.async(task_function)

      result_one = Task.await(task_one, 30_000)
      result_two = Task.await(task_two, 30_000)

      statuses = Enum.map([result_one, result_two], fn {status, _body} -> status end)

      assert Enum.count(statuses, &(&1 == 204)) == 1

      {failure_status, failure_body} =
        Enum.find([result_one, result_two], fn {status, _} -> status != 204 end)

      assert failure_status == 422
      assert failure_body["error"] == "process_instance_not_retriable"
    end
  end

  # ---------------------------------------------------------------------------
  # I10: Retry from error (Error End Event)
  # ---------------------------------------------------------------------------

  describe "I10: basic retry from error" do
    test "retries an error PI and re-executes until error again" do
      {201, _} = http_deploy("error_end_event_standalone.bpmn")
      {201, body} = http_start("ErrorEndStandalone", %{"payload" => %{"data" => "test"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)
      process_instance_before = assert_pi_state!(process_instance_id, "error")
      finished_at_before = process_instance_before.finished_at
      assert finished_at_before != nil

      error_end_fni_before =
        find_fni_by_flow_node_id(process_instance_id, "End_Error")

      assert error_end_fni_before.state == "error"

      {204, nil} = http_retry_process_instance(process_instance_id)

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)
      wait_for_process_instance(process_instance_id, 10_000)

      process_instance_after = assert_pi_state!(process_instance_id, "error")
      assert process_instance_after.finished_at != nil

      assert DateTime.compare(process_instance_after.finished_at, finished_at_before) in [
               :gt,
               :eq
             ]
    end

    test "non-retriable states are still rejected" do
      {201, _} = http_deploy("error_end_event_standalone.bpmn")
      {201, body} = http_start("ErrorEndStandalone", %{"payload" => %{"data" => "test"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "error")

      {204, nil} = http_retry_process_instance(process_instance_id)
      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 5_000)

      {422, error_body} = http_retry_process_instance(process_instance_id)
      assert error_body["error"] == "process_instance_not_retriable"
    end
  end

  # ---------------------------------------------------------------------------
  # I26: Retry embedded subprocess with boundary events
  # ---------------------------------------------------------------------------

  describe "I26: retry aborted embedded subprocess — boundary event cleanup" do
    @tag timeout: 60_000

    test "boundary events are properly cancelled after retry + normal subprocess completion" do
      {201, _} = http_deploy("retry_embedded_subprocess_with_boundary.bpmn")

      {201, body} = http_start("RetryEmbeddedSubprocessWithBoundary")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id, timeout: 15_000)

      child_process_instance_id = user_task_fni.process_instance_id
      assert user_task_fni.state == "waiting"

      # Verify the error boundary FNI was pre-spawned on the parent PI.
      parent_fnis_before = fetch_flow_node_instances(parent_process_instance_id)

      boundary_fni_before =
        Enum.find(parent_fnis_before, &(&1.flow_node_id == "BE_Error"))

      assert boundary_fni_before != nil,
             "error boundary FNI should be pre-spawned"

      assert boundary_fni_before.state in ["active", "waiting"],
             "error boundary should be active or waiting, got: #{boundary_fni_before.state}"

      # Abort the parent PI (cascades to child).
      {204, nil} =
        http_abort_process_instance(parent_process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(parent_process_instance_id, 10_000)
      assert_pi_state!(parent_process_instance_id, "aborted")
      assert_pi_state!(child_process_instance_id, "aborted")

      # Retry the parent PI.
      {204, nil} = http_retry_process_instance(parent_process_instance_id)

      assert {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id, 10_000)

      # Wait for a new child PI's user task to appear.
      {:ok, retried_user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id, timeout: 20_000)

      retried_child_process_instance_id = retried_user_task_fni.process_instance_id

      subprocess_fni_during_retry =
        find_fni_by_flow_node_id(parent_process_instance_id, "SubProcess_1")

      assert subprocess_fni_during_retry != nil
      assert subprocess_fni_during_retry.state == "waiting",
             "SubProcess FNI should be waiting while child runs, got: #{subprocess_fni_during_retry.state}"

      # Complete the user task — the subprocess should finish normally,
      # triggering cancel_boundary_fnis_for_host for the error boundary.
      {204, nil} = http_finish_user_task(retried_user_task_fni.id, %{"done" => true})

      wait_for_process_instance(retried_child_process_instance_id, 15_000)
      wait_for_process_instance(parent_process_instance_id, 15_000)

      # The critical assertion: the parent PI finished (not stuck in running).
      # Without the fix, boundary events remain active → PI deadlocks.
      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(retried_child_process_instance_id, "finished")

      # Verify all FNIs on both PIs are terminal.
      assert_all_fnis_terminal!(parent_process_instance_id)
      assert_all_fnis_terminal!(retried_child_process_instance_id)

      # Verify the error boundary FNI was interrupted (host_completed).
      parent_fnis_after = fetch_flow_node_instances(parent_process_instance_id)

      boundary_fni_after =
        Enum.find(parent_fnis_after, &(&1.flow_node_id == "BE_Error"))

      assert boundary_fni_after != nil
      assert boundary_fni_after.state == "interrupted",
             "error boundary should be interrupted after host completed, got: #{boundary_fni_after.state}"

      # Verify the subprocess shell itself finished (not still active).
      subprocess_fni =
        Enum.find(parent_fnis_after, &(&1.flow_node_id == "SubProcess_1"))

      assert subprocess_fni != nil
      assert subprocess_fni.state == "finished"

      # Verify the process took the happy path (End_OK), not the error path.
      end_ok_fni = Enum.find(parent_fnis_after, &(&1.flow_node_id == "End_OK"))
      end_error_fni = Enum.find(parent_fnis_after, &(&1.flow_node_id == "End_Error"))

      assert end_ok_fni != nil
      assert end_ok_fni.state == "finished"
      assert end_error_fni == nil, "error path should not have been taken"
    end
  end

  # ---------------------------------------------------------------------------
  # Retry re-spawns boundary events on host activities
  # ---------------------------------------------------------------------------

  describe "retry at user task with non-interrupting timer boundary re-spawns boundary FNI" do
    @tag timeout: 60_000

    test "boundary event fires again after retry, and user task can be completed" do
      {201, _} = http_deploy("retry_user_task_with_boundary.bpmn")
      {201, body} = http_start("RetryUserTaskWithBoundary")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      assert user_task_fni.state == "waiting"

      # Wait for the non-interrupting timer boundary (PT0S) to fire.
      boundary_end_fni =
        poll_fni_state(process_instance_id, "end_event", "finished", 10_000)

      assert boundary_end_fni.flow_node_id == "End_Timeout"

      # Abort the PI so it becomes retriable.
      {204, nil} =
        http_abort_process_instance(process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, 10_000)
      assert_pi_state!(process_instance_id, "aborted")

      # Retry the PI.
      {204, nil} = http_retry_process_instance(process_instance_id)

      assert {:ok, _pid} = poll_pi_alive(process_instance_id, 10_000)

      # The user task must be waiting again.
      {:ok, retried_user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      assert retried_user_task_fni.state == "waiting"

      # The boundary timer (PT0S) must have fired again, creating a new
      # End_Timeout FNI. This only works if spawn_missing_boundary_fnis
      # correctly dispatched the boundary handler via dispatch_handler_result.
      retried_fnis = fetch_flow_node_instances(process_instance_id)

      retried_boundary_fnis =
        Enum.filter(retried_fnis, fn fni ->
          fni.flow_node_id == "TimerBE_1" and fni.state in ["active", "waiting", "finished"]
        end)

      assert length(retried_boundary_fnis) >= 1,
             "expected at least one active/waiting/finished boundary FNI after retry, " <>
               "got: #{inspect(Enum.map(retried_boundary_fnis, &{&1.flow_node_id, &1.state}))}"

      :ok =
        finish_waiting_user_task(process_instance_id,
          timeout: 10_000,
          result: %{"done" => true}
        )

      wait_for_process_instance(process_instance_id, 15_000)
      assert_pi_state!(process_instance_id, "finished")

      # All FNIs should be terminal.
      assert_all_fnis_terminal!(process_instance_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Retry guard: EBG loser FNIs must NOT be reset
  # ---------------------------------------------------------------------------

  describe "EBG loser FNI stays interrupted after retry" do
    @tag timeout: 30_000

    test "EBG loser catch event is not reset and no new execution path spawns" do
      {201, _} = http_deploy("retry_ebg_guard.bpmn")
      {201, body} = http_start("RetryEbgGuard")
      process_instance_id = body["processInstanceId"]

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      wait_for_process_instance(process_instance_id, 10_000)

      fnis_before = fetch_flow_node_instances(process_instance_id)

      message_catch_before =
        Enum.find(fnis_before, &(&1.flow_node_id == "Catch_Message"))

      assert message_catch_before != nil
      assert message_catch_before.state == "interrupted",
             "EBG loser should be interrupted before retry, got: #{message_catch_before.state}"

      {204, nil} = http_retry_process_instance(process_instance_id)

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      wait_for_process_instance(process_instance_id, 10_000)

      fnis_after = fetch_flow_node_instances(process_instance_id)

      message_catch_fnis_after =
        Enum.filter(fnis_after, &(&1.flow_node_id == "Catch_Message"))

      assert length(message_catch_fnis_after) == 1,
             "expected exactly 1 Catch_Message FNI (no new one spawned), got #{length(message_catch_fnis_after)}"

      message_catch_after = hd(message_catch_fnis_after)

      assert message_catch_after.state == "interrupted",
             "EBG loser should still be interrupted after retry, got: #{message_catch_after.state}"

      assert message_catch_after.id == message_catch_before.id,
             "EBG loser FNI ID should be unchanged (not reset)"
    end
  end

  # ---------------------------------------------------------------------------
  # Retry guard: cancelled boundary FNIs must NOT be reset
  # ---------------------------------------------------------------------------

  describe "cancelled boundary FNI stays interrupted after retry" do
    @tag timeout: 30_000

    test "timer boundary cancelled by host completion is not reset after retry" do
      {201, _} = http_deploy("retry_boundary_guard.bpmn")
      {201, body} = http_start("RetryBoundaryGuard")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      {204, nil} = http_finish_user_task(user_task_fni.id, %{"done" => true})

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      wait_for_process_instance(process_instance_id, 10_000)

      fnis_before = fetch_flow_node_instances(process_instance_id)

      boundary_before =
        Enum.find(fnis_before, &(&1.flow_node_id == "BE_Timer"))

      assert boundary_before != nil
      assert boundary_before.state == "interrupted",
             "boundary should be interrupted before retry, got: #{boundary_before.state}"

      {204, nil} = http_retry_process_instance(process_instance_id)

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      wait_for_process_instance(process_instance_id, 10_000)

      fnis_after = fetch_flow_node_instances(process_instance_id)

      boundary_fnis_after =
        Enum.filter(fnis_after, &(&1.flow_node_id == "BE_Timer"))

      assert length(boundary_fnis_after) == 1,
             "expected exactly 1 BE_Timer FNI (not reset), got #{length(boundary_fnis_after)}"

      boundary_after = hd(boundary_fnis_after)

      assert boundary_after.state == "interrupted",
             "boundary should still be interrupted after retry, got: #{boundary_after.state}"

      assert boundary_after.id == boundary_before.id,
             "boundary FNI ID should be unchanged (not reset)"
    end
  end

  # ---------------------------------------------------------------------------
  # Retry: join gateway FNIs are reset (preserved), not deleted
  # ---------------------------------------------------------------------------

  describe "parallel join gateway retry — FNI preserved" do
    @tag timeout: 30_000

    test "join FNI is reset (same ID) on retry, no duplicate created" do
      {201, _} = http_deploy("retry_parallel_join.bpmn")
      {201, body} = http_start("RetryParallelJoin")
      process_instance_id = body["processInstanceId"]

      # Wait for Task_HoldB (Branch B's UserTask) to reach "waiting" state.
      # Task_Echo (Branch A) runs concurrently as an async script task. Since
      # neither branch can fatal the PI at this point, the PI will process
      # Task_Echo's result and route it to PG_Join before we release Branch B.
      {:ok, hold_fni} =
        await_waiting_fni_by_node_id(process_instance_id, "Task_HoldB", timeout: 10_000)

      # Brief margin for the PI to also process Task_Echo's fni_result and
      # route the token to PG_Join. Task_Echo is a trivial script task that
      # was spawned at the same time as Task_HoldB.
      Process.sleep(150)

      fnis_before = fetch_flow_node_instances(process_instance_id)

      join_fnis_before =
        Enum.filter(fnis_before, &(&1.flow_node_id == "PG_Join"))

      assert length(join_fnis_before) == 1,
             "expected exactly 1 join FNI (from Task_Echo branch) before releasing Task_HoldB, got #{length(join_fnis_before)}"

      join_fni_id_before = hd(join_fnis_before).id

      assert Enum.find(fnis_before, &(&1.flow_node_id == "Task_DeadEnd")) == nil,
             "Task_DeadEnd must not have started yet"

      # Release Branch B: Task_DeadEnd runs with an unknown implementation and fatals the PI.
      {204, _} = http_finish_user_task(hold_fni.id)

      {:ok, _process_instance} =
        await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

      wait_for_process_instance(process_instance_id, 10_000)

      fnis_at_fatal = fetch_flow_node_instances(process_instance_id)

      dead_end_at_fatal = Enum.find(fnis_at_fatal, &(&1.flow_node_id == "Task_DeadEnd"))
      assert dead_end_at_fatal != nil
      assert dead_end_at_fatal.state == "fatal"

      {204, nil} = http_retry_process_instance(process_instance_id)

      # After retry, only Task_DeadEnd (which was in "fatal" state) is reset to "active"
      # and re-executed. Task_HoldB is already "finished" and is NOT re-dispatched,
      # because the retry mechanism only resets FNIs that match the PI's terminal state
      # ("fatal"). Task_DeadEnd immediately fatals the PI again with its nonexistent handler.
      {:ok, _} = await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)
      wait_for_process_instance(process_instance_id, 10_000)

      fnis_after_retry = fetch_flow_node_instances(process_instance_id)

      # PG_Join: the join FNI must not have been duplicated — same UUID, now interrupted.
      all_join_fnis = Enum.filter(fnis_after_retry, &(&1.flow_node_id == "PG_Join"))

      assert length(all_join_fnis) == 1,
             "expected exactly 1 join FNI after retry (no duplicate), got #{length(all_join_fnis)}"

      assert hd(all_join_fnis).id == join_fni_id_before,
             "join FNI ID must be preserved across retry (reset in-place, not deleted/recreated)"

      # Task_DeadEnd: must have fataled again, confirming the retry re-executed it.
      dead_end_fnis = Enum.filter(fnis_after_retry, &(&1.flow_node_id == "Task_DeadEnd"))

      assert Enum.any?(dead_end_fnis, &(&1.state == "fatal")),
             "expected at least one fatal Task_DeadEnd FNI after retry"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp deploy_and_fatal(fixture_name, process_model_id) do
    {201, _} = http_deploy(fixture_name)
    {201, body} = http_start(process_model_id)
    process_instance_id = body["processInstanceId"]

    {:ok, _process_instance} =
      await_process_instance_state(process_instance_id, "fatal", timeout: 10_000)

    wait_for_process_instance(process_instance_id, 10_000)
    process_instance_id
  end

  defp find_child_process_instance_ids(parent_process_instance_id) do
    require Ash.Query

    ProcessInstanceResource
    |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
    |> Ash.read!(domain: @persistence_domain, authorize?: false)
    |> Enum.map(& &1.id)
  end

  defp poll_child_waiting_user_task(parent_process_instance_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_child_waiting_user_task(parent_process_instance_id, deadline)
  end

  defp do_poll_child_waiting_user_task(parent_process_instance_id, deadline) do
    child_process_instance_ids = find_child_process_instance_ids(parent_process_instance_id)

    result =
      Enum.find_value(child_process_instance_ids, fn child_process_instance_id ->
        case await_waiting_flow_node_instance(child_process_instance_id, "user_task",
               timeout: 100
             ) do
          {:ok, flow_node_instance} -> flow_node_instance
          {:error, :timeout} -> nil
        end
      end)

    case result do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("no child PI reached waiting user_task within timeout")
        else
          Process.sleep(50)
          do_poll_child_waiting_user_task(parent_process_instance_id, deadline)
        end

      flow_node_instance ->
        {:ok, flow_node_instance}
    end
  end

  defp version_id_for(process_model_id, version_string) do
    {200, version_entries} = http_list_versions(process_model_id)

    entry =
      Enum.find(version_entries, fn version_entry ->
        version_entry["version"] == version_string
      end)

    unless entry do
      flunk("version #{version_string} not found for #{process_model_id}")
    end

    entry["versionId"]
  end

  defp fetch_flow_node_instance_with_state!(process_instance_id, flow_node_id, expected_state) do
    flow_node_instance = find_fni_by_flow_node_id(process_instance_id, flow_node_id)

    assert flow_node_instance != nil,
           "expected FNI #{flow_node_id} on PI #{process_instance_id}"

    assert flow_node_instance.state == expected_state,
           "expected FNI #{flow_node_id} state #{expected_state}, got #{flow_node_instance.state}"

    flow_node_instance
  end

  defp fetch_flow_node_instance(flow_node_instance_id) do
    Ash.get(FlowNodeInstanceResource, flow_node_instance_id,
      domain: @persistence_domain,
      authorize?: false
    )
    |> case do
      {:ok, record} -> record
      {:error, _} -> nil
    end
  end

  defp insert_fatal_child_process_instance(parent_process_instance_id, process_version_id) do
    child_process_instance_id = Ash.UUIDv7.generate()

    {:ok, _record} =
      Ash.create(
        ProcessInstanceResource,
        %{
          id: child_process_instance_id,
          process_version_id: process_version_id,
          state: "running",
          started_at: DateTime.utc_now(),
          started_by: %{"id" => "test-user"},
          parent_process_instance_id: parent_process_instance_id
        },
        domain: @persistence_domain,
        authorize?: false
      )

    {:ok, _} =
      Ash.update(
        Ash.get!(ProcessInstanceResource, child_process_instance_id,
          domain: @persistence_domain,
          authorize?: false
        ),
        %{state: "fatal", finished_at: DateTime.utc_now()},
        domain: @persistence_domain,
        action: :update_state,
        authorize?: false
      )

    child_process_instance_id
  end

  defp retry_parent_calling_process_xml(parent_process_model_id, called_element) do
    Path.join(@bpmn_fixtures_dir, "retry_parent_with_failing_child.bpmn")
    |> File.read!()
    |> String.replace("RetryParentWithFailingChild", parent_process_model_id)
    |> String.replace("Participant_RetryParentWithFailingChild", "Participant_#{parent_process_model_id}")
    |> String.replace("Retry Parent With Failing Child", "Retry Parent #{parent_process_model_id}")
    |> String.replace("FailingChildProcess", called_element)
  end

  defp retry_user_task_version_xml(version_string) do
    @retry_user_task_fixture
    |> File.read!()
    |> String.replace("<evil:version>1.0.0</evil:version>", "<evil:version>#{version_string}</evil:version>")
  end

  defp retry_user_task_incompatible_v2_xml do
    @retry_user_task_fixture
    |> File.read!()
    |> String.replace("<evil:version>1.0.0</evil:version>", "<evil:version>2.0.0</evil:version>")
    |> String.replace("UserTask_1", "UserTask_2")
    |> String.replace("Shape_UserTask_1", "Shape_UserTask_2")
  end

  defp retry_fatal_dead_end_version_xml(version_string) do
    @retry_fatal_dead_end_fixture
    |> File.read!()
    |> String.replace("<evil:version>1.0.0</evil:version>", "<evil:version>#{version_string}</evil:version>")
  end

  defp retry_checkpoint_linear_version_xml(version_string) do
    @retry_checkpoint_linear_fixture
    |> File.read!()
    |> String.replace("<evil:version>1.0.0</evil:version>", "<evil:version>#{version_string}</evil:version>")
  end

  # ---------------------------------------------------------------------------
  # I33: Multi-CA abort-retry with embedded subprocess
  # ---------------------------------------------------------------------------

  describe "I33: multi-CA abort+retry from inner subprocess must not duplicate PIs" do
    @tag :integration
    test "abort all, retry from subprocess child start event → preserves all 4 original PI IDs" do
      {201, _} = http_deploy("retry_multi_ca_root.bpmn")
      {201, _} = http_deploy("retry_multi_ca_subprocess_child.bpmn")
      {201, _} = http_deploy("retry_multi_ca_simple_child.bpmn")

      {201, body} = http_start("RetryMultiCaRoot")
      root_process_instance_id = body["processInstanceId"]

      Process.sleep(2_000)

      root_direct_children = find_child_process_instance_ids(root_process_instance_id)
      assert length(root_direct_children) == 2, "Root should have exactly 2 direct children (two CAs), got #{length(root_direct_children)}"

      subprocess_child_process_instance_id =
        Enum.find(root_direct_children, fn child_id ->
          has_do_a_stuff_fni?(child_id)
        end)

      simple_child_process_instance_id =
        Enum.find(root_direct_children, fn child_id ->
          child_id != subprocess_child_process_instance_id
        end)

      assert subprocess_child_process_instance_id != nil, "Should find subprocess child PI (has DoAStuff FNI)"
      assert simple_child_process_instance_id != nil, "Should find simple child PI"

      {204, nil} =
        http_abort_process_instance(root_process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(root_process_instance_id, 10_000)
      Process.sleep(2_000)

      assert_pi_state!(root_process_instance_id, "aborted")
      assert_pi_state!(subprocess_child_process_instance_id, "aborted")
      assert_pi_state!(simple_child_process_instance_id, "aborted")

      do_a_stuff_fni = find_fni_by_flow_node_id(subprocess_child_process_instance_id, "DoAStuff")
      assert do_a_stuff_fni != nil, "Should find DoAStuff FNI in subprocess child"

      {204, nil} =
        http_retry_process_instance(subprocess_child_process_instance_id, %{
          "resetToFlowNodeInstanceId" => do_a_stuff_fni.id
        })

      assert {:ok, _root_pid} = poll_pi_alive(root_process_instance_id, 10_000)
      Process.sleep(3_000)

      assert_pi_state!(root_process_instance_id, "running")

      ca_subprocess_fni =
        find_fni_by_flow_node_id(root_process_instance_id, "CA_SubprocessChild")

      assert ca_subprocess_fni != nil
      assert ca_subprocess_fni.state == "waiting",
             "CA_SubprocessChild FNI should be waiting while child runs, got: #{ca_subprocess_fni.state}"

      ca_simple_fni =
        find_fni_by_flow_node_id(root_process_instance_id, "CA_SimpleChild")

      assert ca_simple_fni != nil
      assert ca_simple_fni.state == "waiting",
             "CA_SimpleChild FNI should be waiting while child runs, got: #{ca_simple_fni.state}"

      root_children_after = find_child_process_instance_ids(root_process_instance_id)
      assert length(root_children_after) == 2,
        "Root should still have exactly 2 direct children after retry, got #{length(root_children_after)}: #{inspect(root_children_after)}"

      assert subprocess_child_process_instance_id in root_children_after,
        "Original subprocess child PI should be preserved"
      assert simple_child_process_instance_id in root_children_after,
        "Original simple child PI should be preserved"

      all_process_instances_after = count_all_process_instances_in_tree(root_process_instance_id)
      assert all_process_instances_after <= 4,
        "Total PI count in tree should be at most 4, got #{all_process_instances_after}"
    end

    @tag :integration
    test "abort all, retry from child PI at DoAStuff checkpoint → preserves tree structure" do
      {201, _} = http_deploy("retry_multi_ca_root.bpmn")
      {201, _} = http_deploy("retry_multi_ca_subprocess_child.bpmn")
      {201, _} = http_deploy("retry_multi_ca_simple_child.bpmn")

      {201, body} = http_start("RetryMultiCaRoot")
      root_process_instance_id = body["processInstanceId"]

      Process.sleep(2_000)

      root_direct_children = find_child_process_instance_ids(root_process_instance_id)
      assert length(root_direct_children) == 2

      subprocess_child_process_instance_id =
        Enum.find(root_direct_children, fn child_id ->
          has_do_a_stuff_fni?(child_id)
        end)

      simple_child_process_instance_id =
        Enum.find(root_direct_children, fn child_id ->
          child_id != subprocess_child_process_instance_id
        end)

      assert subprocess_child_process_instance_id != nil, "Should find subprocess child PI (has DoAStuff FNI)"
      assert simple_child_process_instance_id != nil, "Should find simple child PI"

      sp_grandchildren = find_child_process_instance_ids(subprocess_child_process_instance_id)
      assert length(sp_grandchildren) == 1, "Subprocess child should have 1 grandchild (embedded subprocess), got #{length(sp_grandchildren)}"
      embedded_subprocess_child_process_instance_id = hd(sp_grandchildren)

      {204, nil} =
        http_abort_process_instance(root_process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(root_process_instance_id, 10_000)
      Process.sleep(2_000)

      assert_pi_state!(root_process_instance_id, "aborted")
      assert_pi_state!(subprocess_child_process_instance_id, "aborted")
      assert_pi_state!(simple_child_process_instance_id, "aborted")
      assert_pi_state!(embedded_subprocess_child_process_instance_id, "aborted")

      do_a_stuff_fni = find_fni_by_flow_node_id(subprocess_child_process_instance_id, "DoAStuff")
      assert do_a_stuff_fni != nil, "Should find DoAStuff FNI in subprocess child PI"

      {204, nil} =
        http_retry_process_instance(subprocess_child_process_instance_id, %{
          "resetToFlowNodeInstanceId" => do_a_stuff_fni.id
        })

      assert {:ok, _root_pid} = poll_pi_alive(root_process_instance_id, 10_000)
      Process.sleep(3_000)

      assert_pi_state!(root_process_instance_id, "running")
      assert_pi_state!(subprocess_child_process_instance_id, "running")
      assert_pi_state!(simple_child_process_instance_id, "running")

      ca_subprocess_fni =
        find_fni_by_flow_node_id(root_process_instance_id, "CA_SubprocessChild")

      assert ca_subprocess_fni != nil
      assert ca_subprocess_fni.state == "waiting",
             "CA_SubprocessChild FNI should be waiting while child runs, got: #{ca_subprocess_fni.state}"

      ca_simple_fni =
        find_fni_by_flow_node_id(root_process_instance_id, "CA_SimpleChild")

      assert ca_simple_fni != nil
      assert ca_simple_fni.state == "waiting",
             "CA_SimpleChild FNI should be waiting while child runs, got: #{ca_simple_fni.state}"

      sp_inner_fni =
        find_fni_by_flow_node_id(subprocess_child_process_instance_id, "SP_Inner")

      assert sp_inner_fni != nil
      assert sp_inner_fni.state == "waiting",
             "SP_Inner FNI should be waiting while embedded subprocess child runs, got: #{sp_inner_fni.state}"

      root_children_after = find_child_process_instance_ids(root_process_instance_id)
      assert length(root_children_after) == 2,
        "Root should still have exactly 2 direct children after retry, got #{length(root_children_after)}: #{inspect(root_children_after)}"

      assert subprocess_child_process_instance_id in root_children_after,
        "Original subprocess child PI must be preserved"
      assert simple_child_process_instance_id in root_children_after,
        "Original simple child PI must be preserved"

      all_process_instances_after = count_all_process_instances_in_tree(root_process_instance_id)
      assert all_process_instances_after <= 4,
        "Total PI count in tree should be at most 4 (root + 2 CA + possibly 1 SP grandchild), got #{all_process_instances_after}"
    end
  end

  defp has_do_a_stuff_fni?(process_instance_id) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)
    Enum.any?(flow_node_instances, &(&1.flow_node_id == "DoAStuff"))
  end

  defp count_all_process_instances_in_tree(root_process_instance_id) do
    children = find_child_process_instance_ids(root_process_instance_id)
    grandchildren = Enum.flat_map(children, &find_child_process_instance_ids/1)
    1 + length(children) + length(grandchildren)
  end
end
