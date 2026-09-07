defmodule EvilEngine.Integration.Execution.CallActivityResumeTest do
  @moduledoc """
  Integration tests for Call Activity resume scenarios.

  Covers the four resume code paths in `CallActivity.handle_resume/4`:

  1. Child still running  → `monitor_and_wait` re-attaches to the live child
  2. Child already gone    → `run_fresh_lifecycle` spawns a new child
  3. No child_process_instance_id (nil)  → `query_child_state(_, nil)` → fresh lifecycle
  4. Resolution failure    → called element no longer available after restart
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Execution
  alias EvilEngine.Execution.ResumeRunner

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

  # -------------------------------------------------------------------
  # R1: Child still running — parent re-monitors and waits
  # -------------------------------------------------------------------

  describe "CA resume: child still running" do
    test "parent re-monitors running child and completes after child finishes" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")
      {201, _} = http_deploy("call_activity_resume_parent.bpmn")

      {201, body} = http_start("CallActivityResumeParent")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)
      child_process_instance_id = child_user_task_fni.process_instance_id

      assert {:ok, child_pid} = Execution.lookup_process_instance(child_process_instance_id)
      assert Process.alive?(child_pid)

      terminate_process_instance(parent_process_instance_id)
      await_process_exit(parent_process_instance_id)

      assert {:ok, _} = Execution.lookup_process_instance(child_process_instance_id),
             "Child PI must survive parent termination"

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count >= 1

      {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id)

      {204, _} = http_finish_user_task(child_user_task_fni.id, %{"result" => "done"})

      wait_for_process_instance(child_process_instance_id, 5_000)
      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(child_process_instance_id, "finished")

      parent_ca_fni = find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")
      assert parent_ca_fni.state == "finished"
      assert parent_ca_fni.type_properties["child_process_instance_id"] == child_process_instance_id
    end
  end

  # -------------------------------------------------------------------
  # R2: Child finished while parent was down — parent aggregates results
  # -------------------------------------------------------------------

  describe "CA resume: child finished while parent was down" do
    test "parent aggregates finished child results without creating a new child" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")
      {201, _} = http_deploy("call_activity_resume_parent.bpmn")

      {201, body} = http_start("CallActivityResumeParent")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)
      original_child_process_instance_id = child_user_task_fni.process_instance_id

      terminate_process_instance(parent_process_instance_id)
      await_process_exit(parent_process_instance_id)

      {204, _} = http_finish_user_task(child_user_task_fni.id, %{"result" => "done"})
      wait_for_process_instance(original_child_process_instance_id, 5_000)
      assert_pi_state!(original_child_process_instance_id, "finished")

      assert {:error, :not_found} =
               Execution.lookup_process_instance(original_child_process_instance_id)

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count >= 1

      {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id)

      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(original_child_process_instance_id, "finished")

      parent_ca_fni = find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert parent_ca_fni.type_properties["child_process_instance_id"] ==
               original_child_process_instance_id
    end
  end

  # -------------------------------------------------------------------
  # R3: No child_process_instance_id in persistence — fresh lifecycle
  # -------------------------------------------------------------------

  describe "CA resume: no child_process_instance_id in persistence" do
    test "parent re-executes full lifecycle when child_process_instance_id is nil" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")
      {201, _} = http_deploy("call_activity_resume_parent.bpmn")

      {201, body} = http_start("CallActivityResumeParent")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)
      original_child_process_instance_id = child_user_task_fni.process_instance_id

      terminate_process_instance(parent_process_instance_id)
      await_process_exit(parent_process_instance_id)

      terminate_process_instance(original_child_process_instance_id)
      await_process_exit(original_child_process_instance_id)

      clear_child_process_instance_id_from_fni(parent_process_instance_id, "CA_1")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count >= 1

      {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id)

      {:ok, new_child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id, exclude: [original_child_process_instance_id])
      new_child_process_instance_id = new_child_user_task_fni.process_instance_id

      assert new_child_process_instance_id != original_child_process_instance_id

      {204, _} = http_finish_user_task(new_child_user_task_fni.id, %{"result" => "fresh"})

      wait_for_process_instance(new_child_process_instance_id, 5_000)
      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(new_child_process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # R4: Called element disabled, but existing child PI resumes from DB
  # -------------------------------------------------------------------

  describe "CA resume: called element disabled but child PI exists in DB" do
    test "parent resumes existing child from DB even when model is disabled" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")
      {201, _} = http_deploy("call_activity_resume_parent_boundary.bpmn")

      {201, body} = http_start("CallActivityResumeParentBoundary")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)
      original_child_process_instance_id = child_user_task_fni.process_instance_id

      terminate_process_instance(parent_process_instance_id)
      await_process_exit(parent_process_instance_id)

      terminate_process_instance(original_child_process_instance_id)
      await_process_exit(original_child_process_instance_id)

      {status, _} = http_disable("ResumableChild")
      assert status in [200, 204]

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count >= 1

      {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id)
      {:ok, _child_pid} = poll_pi_alive(original_child_process_instance_id)

      {:ok, resumed_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)

      assert resumed_user_task_fni.process_instance_id == original_child_process_instance_id,
             "The SAME child PI must be resumed, not a new one"

      {204, _} =
        http_finish_user_task(to_string(resumed_user_task_fni.id), %{"result" => "done"})

      wait_for_process_instance(original_child_process_instance_id, 5_000)
      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(original_child_process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # R5: New version deployed, but existing child PI resumes with old version
  # -------------------------------------------------------------------

  describe "CA resume: new version deployed but child resumes with original version" do
    test "existing child resumes from DB with original version data" do
      {201, _} = http_deploy("call_activity_resume_child.bpmn")
      {201, _} = http_deploy("call_activity_resume_parent_boundary.bpmn")

      {201, body} = http_start("CallActivityResumeParentBoundary")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)
      original_child_process_instance_id = child_user_task_fni.process_instance_id

      terminate_process_instance(parent_process_instance_id)
      await_process_exit(parent_process_instance_id)

      terminate_process_instance(original_child_process_instance_id)
      await_process_exit(original_child_process_instance_id)

      {201, _} = http_deploy("call_activity_resume_child_fatal.bpmn")

      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count >= 1

      {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id)

      {:ok, resumed_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)

      assert resumed_user_task_fni.process_instance_id == original_child_process_instance_id,
             "The SAME child PI must be resumed from its old version, not a new one"

      {:ok, _child_pid} = poll_pi_alive(resumed_user_task_fni.process_instance_id)

      {204, _} = http_finish_user_task(resumed_user_task_fni.id, %{"result" => "done"})

      wait_for_process_instance(original_child_process_instance_id, 5_000)
      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "finished")
      assert_pi_state!(original_child_process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # R6: Child fatals after resume re-monitor — parent catches fatal
  # -------------------------------------------------------------------

  describe "CA resume: child fatals after resume re-attach" do
    test "parent catches child fatal when child proceeds to defective task after resume" do
      # Deploy the defective child (UserTask → bad ServiceTask → End).
      # The parent's Call Activity resolves to this latest version.
      {201, _} = http_deploy("call_activity_resume_child_defective.bpmn")
      {201, _} = http_deploy("call_activity_resume_parent.bpmn")

      {201, body} = http_start("CallActivityResumeParent")
      parent_process_instance_id = body["processInstanceId"]

      # Child (defective version) reaches UserTask_1 and waits
      {:ok, child_user_task_fni} = poll_child_waiting_user_task(parent_process_instance_id)
      child_process_instance_id = child_user_task_fni.process_instance_id

      # Terminate only the parent; child keeps running at user task
      terminate_process_instance(parent_process_instance_id)
      await_process_exit(parent_process_instance_id)

      assert {:ok, _} = Execution.lookup_process_instance(child_process_instance_id),
             "Child must survive parent termination"

      # Resume — parent re-monitors the still-running child via monitor_and_wait
      {:ok, resumed_count} = ResumeRunner.resume_all()
      assert resumed_count >= 1

      {:ok, _parent_pid} = poll_pi_alive(parent_process_instance_id)

      # Finish the user task → child advances to defective ServiceTask → fatal
      {204, _} = http_finish_user_task(child_user_task_fni.id, %{"result" => "done"})

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "fatal")
      assert_no_running_fnis!(child_process_instance_id)

      # Parent's monitor_and_wait receives {:fatal, reason} and propagates
      wait_for_process_instance(parent_process_instance_id, 5_000)
      assert_pi_state!(parent_process_instance_id, "fatal")
      assert_no_running_fnis!(parent_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp terminate_process_instance(process_instance_id) do
    case Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(EvilEngine.Execution.Supervisor, pid)

      {:error, :not_found} ->
        :ok
    end
  end

  defp await_process_exit(process_instance_id) do
    case Execution.lookup_process_instance(process_instance_id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp poll_child_waiting_user_task(parent_process_instance_id, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_poll_child_user_task(parent_process_instance_id, exclude, deadline)
  end

  defp do_poll_child_user_task(parent_process_instance_id, exclude, deadline) do
    child_process_instance_ids =
      find_child_process_instance_ids(parent_process_instance_id)
      |> Enum.reject(&(&1 in exclude))

    result =
      Enum.find_value(child_process_instance_ids, fn child_process_instance_id ->
        flow_node_instances = fetch_flow_node_instances(child_process_instance_id)

        Enum.find(flow_node_instances, fn flow_node_instance_candidate ->
          flow_node_instance_candidate.flow_node_type == "user_task" and flow_node_instance_candidate.state == "waiting"
        end)
      end)

    case result do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          do_poll_child_user_task(parent_process_instance_id, exclude, deadline)
        end

      flow_node_instance ->
        {:ok, flow_node_instance}
    end
  end

  defp find_child_process_instance_ids(parent_process_instance_id) do
    list_child_process_instance_ids(parent_process_instance_id)
  end

  defp clear_child_process_instance_id_from_fni(parent_process_instance_id, flow_node_id) do
    require Ash.Query

    flow_node_instance =
      EvilEngine.Test.DbAssertions.with_sandbox_retry(fn ->
        EvilEngine.Persistence.Resources.FlowNodeInstance
        |> Ash.Query.filter(
          process_instance_id == ^parent_process_instance_id and
            flow_node_id == ^flow_node_id and
            state == "waiting"
        )
        |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)
        |> List.first()
      end)

    if flow_node_instance do
      current_props = flow_node_instance.type_properties || %{}

      cleared_props =
        current_props
        |> Map.delete("child_process_instance_id")
        |> Map.delete(:child_process_instance_id)

      Ash.update!(flow_node_instance, %{type_properties: cleared_props},
        domain: EvilEngine.Persistence.Api,
        authorize?: false,
        action: :update_waiting
      )
    end
  end

  describe "five-level Call Activity chain" do
    test "root finishes after the leaf user task is completed" do
      {201, _} = http_deploy("call_activity_depth_5_leaf.bpmn")
      {201, _} = http_deploy("call_activity_depth_5_l4.bpmn")
      {201, _} = http_deploy("call_activity_depth_5_l3.bpmn")
      {201, _} = http_deploy("call_activity_depth_5_l2.bpmn")
      {201, _} = http_deploy("call_activity_depth_5_l1.bpmn")

      {201, body} = http_start("CallActivityDepth5")
      root_process_instance_id = body["processInstanceId"]

      leaf_user_task = await_tree_waiting_user_task(root_process_instance_id)
      {204, _} = http_finish_user_task(leaf_user_task.id, %{"approved" => true})

      wait_for_process_instance(root_process_instance_id, 20_000)
      assert_pi_state!(root_process_instance_id, "finished")
    end
  end

  defp await_tree_waiting_user_task(root_process_instance_id, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_tree_waiting_user_task(root_process_instance_id, deadline)
  end

  defp do_await_tree_waiting_user_task(root_process_instance_id, deadline) do
    case find_waiting_user_task_in_tree(root_process_instance_id) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "no waiting user task in Call Activity tree #{root_process_instance_id}"
        end

        Process.sleep(50)
        do_await_tree_waiting_user_task(root_process_instance_id, deadline)

      flow_node_instance ->
        flow_node_instance
    end
  end

  defp find_waiting_user_task_in_tree(process_instance_id) do
    match =
      fetch_flow_node_instances(process_instance_id)
      |> Enum.find(fn flow_node_instance ->
        flow_node_instance.flow_node_type == "user_task" and
          flow_node_instance.state == "waiting"
      end)

    if match do
      match
    else
      list_child_process_instance_ids(process_instance_id)
      |> Enum.find_value(&find_waiting_user_task_in_tree/1)
    end
  end
end
