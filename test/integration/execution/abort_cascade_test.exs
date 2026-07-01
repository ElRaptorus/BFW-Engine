defmodule EvilEngine.Integration.Execution.AbortCascadeTest do
  @moduledoc """
  Integration tests for upward abort cascade through the process tree.

  Verifies that when a child PI is aborted (via API), the abort propagates
  upward to the parent (and beyond), aborting the entire process tree.
  This is the "kill switch" behaviour: abort on any PI in the tree kills
  the whole tree. Error Boundary Events must NOT catch aborts.
  """
  use EvilEngine.ExecutionCase, async: false

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
  # U1: Abort child PI → parent cascades to aborted
  # -------------------------------------------------------------------

  describe "U1: aborting child cascades abort to parent" do
    test "parent PI transitions to aborted when child is aborted directly" do
      {201, _} = http_deploy("ca_cascade_waiting_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_parent.bpmn")

      {201, body} = http_start("CaCascadeSimpleParent")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id)

      child_process_instance_id = child_user_task_fni.process_instance_id

      abort_claims = %{"abort_process_instance" => "all"}

      {204, _} =
        http_abort_process_instance(child_process_instance_id, "user_abort_child", abort_claims)

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "aborted")
      assert_no_running_fnis!(child_process_instance_id)

      wait_for_process_instance(parent_process_instance_id, 5_000)
      assert_pi_state!(parent_process_instance_id, "aborted")
      assert_no_running_fnis!(parent_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # U2: 3-level chain — abort grandchild → all abort
  # -------------------------------------------------------------------

  describe "U2: aborting grandchild cascades abort through entire tree" do
    test "root, child, and grandchild all transition to aborted" do
      {201, _} = http_deploy("ca_cascade_nested_grandchild.bpmn")
      {201, _} = http_deploy("ca_cascade_nested_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_nested_parent.bpmn")

      {201, body} = http_start("CaCascadeSimpleNestedParent")
      root_process_instance_id = body["processInstanceId"]

      {:ok, grandchild_user_task_fni} =
        poll_grandchild_waiting_user_task(root_process_instance_id)

      grandchild_process_instance_id = grandchild_user_task_fni.process_instance_id

      abort_claims = %{"abort_process_instance" => "all"}

      {204, _} =
        http_abort_process_instance(
          grandchild_process_instance_id,
          "user_abort_grandchild",
          abort_claims
        )

      wait_for_process_instance(grandchild_process_instance_id, 5_000)
      assert_pi_state!(grandchild_process_instance_id, "aborted")
      assert_no_running_fnis!(grandchild_process_instance_id)

      [child_process_instance_id] =
        find_child_process_instance_ids(root_process_instance_id)

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "aborted")
      assert_no_running_fnis!(child_process_instance_id)

      wait_for_process_instance(root_process_instance_id, 5_000)
      assert_pi_state!(root_process_instance_id, "aborted")
      assert_no_running_fnis!(root_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # U3: Abort child with Error Boundary on parent CA — boundary must NOT fire
  # -------------------------------------------------------------------

  describe "U3: abort bypasses Error Boundary Events" do
    test "parent aborts instead of catching error boundary when child is aborted" do
      {201, _} = http_deploy("ca_cascade_waiting_child.bpmn")
      {201, _} = http_deploy("ca_cascade_error_boundary_parent.bpmn")

      {201, body} = http_start("CaCascadeErrorBoundaryParent")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, child_user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id)

      child_process_instance_id = child_user_task_fni.process_instance_id

      abort_claims = %{"abort_process_instance" => "all"}

      {204, _} =
        http_abort_process_instance(child_process_instance_id, "user_abort_child", abort_claims)

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "aborted")

      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "aborted")
      assert_no_running_fnis!(parent_process_instance_id)

      parent_fnis = fetch_flow_node_instances(parent_process_instance_id)

      boundary_end_reached =
        Enum.any?(parent_fnis, fn fni ->
          fni.flow_node_id == "End_Boundary" and fni.state == "finished"
        end)

      refute boundary_end_reached,
             "Error Boundary path (End_Boundary) must not be reached on abort"
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp find_child_process_instance_ids(parent_process_instance_id) do
    require Ash.Query

    EvilEngine.Persistence.Resources.ProcessInstance
    |> Ash.Query.filter(parent_process_instance_id == ^parent_process_instance_id)
    |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)
    |> Enum.map(& &1.id)
  end

  defp poll_child_waiting_user_task(parent_process_instance_id) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_poll_child_user_task(parent_process_instance_id, deadline)
  end

  defp do_poll_child_user_task(parent_process_instance_id, deadline) do
    child_process_instance_ids =
      find_child_process_instance_ids(parent_process_instance_id)

    result =
      Enum.find_value(child_process_instance_ids, fn child_process_instance_id ->
        flow_node_instances = fetch_flow_node_instances(child_process_instance_id)

        Enum.find(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_type == "user_task" and
            flow_node_instance.state == "waiting"
        end)
      end)

    case result do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          do_poll_child_user_task(parent_process_instance_id, deadline)
        end

      flow_node_instance ->
        {:ok, flow_node_instance}
    end
  end

  defp poll_grandchild_waiting_user_task(root_process_instance_id) do
    deadline = System.monotonic_time(:millisecond) + 15_000
    do_poll_grandchild_user_task(root_process_instance_id, deadline)
  end

  defp do_poll_grandchild_user_task(root_process_instance_id, deadline) do
    child_process_instance_ids =
      find_child_process_instance_ids(root_process_instance_id)

    grandchild_process_instance_ids =
      Enum.flat_map(child_process_instance_ids, &find_child_process_instance_ids/1)

    all_descendant_ids = child_process_instance_ids ++ grandchild_process_instance_ids

    result =
      Enum.find_value(all_descendant_ids, fn descendant_id ->
        flow_node_instances = fetch_flow_node_instances(descendant_id)

        Enum.find(flow_node_instances, fn flow_node_instance ->
          flow_node_instance.flow_node_type == "user_task" and
            flow_node_instance.state == "waiting"
        end)
      end)

    case result do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          do_poll_grandchild_user_task(root_process_instance_id, deadline)
        end

      flow_node_instance ->
        {:ok, flow_node_instance}
    end
  end
end
