defmodule BfwEngine.Integration.Execution.CallActivityCascadeTest do
  @moduledoc """
  Integration tests for Call Activity child PI cascade on parent termination.

  Verifies that when a parent PI terminates (fatal or aborted), child PIs
  spawned by Call Activities are cascaded to the matching terminal state.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution

  setup do
    original_resolver = Application.get_env(:core_execution, :called_element_resolver)

    Application.put_env(
      :core_execution,
      :called_element_resolver,
      BfwEngine.Persistence.CalledElementResolverImpl
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
  # F1: Parent goes fatal (dead-end branch), child is waiting at UserTask
  # -------------------------------------------------------------------

  describe "F1: parent fatal cascades to running child" do
    test "child PI transitions to fatal when parent goes fatal" do
      {201, _} = http_deploy("ca_cascade_waiting_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_parent.bpmn")

      {201, body} = http_start("CaCascadeSimpleParent")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _child_user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id)

      :ok = Execution.fatal_process_instance(parent_process_instance_id, %{reason: "test_fatal"})
      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "fatal")
      assert_no_running_fnis!(parent_process_instance_id)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "fatal")
      assert_no_running_fnis!(child_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # F2: Parent goes fatal after child already finished
  # -------------------------------------------------------------------

  describe "F2: parent fatal does not retroactively change finished child" do
    test "child PI stays finished when parent goes fatal after child completion" do
      {201, _} = http_deploy("ca_cascade_fast_child.bpmn")
      {201, _} = http_deploy("ca_cascade_parent_then_fatal.bpmn")

      {201, body} = http_start("CaCascadeParentThenFatal")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 10_000)

      assert_pi_state!(parent_process_instance_id, "fatal")
      assert_no_running_fnis!(parent_process_instance_id)

      child_process_instance_ids =
        find_child_process_instance_ids(parent_process_instance_id)

      assert length(child_process_instance_ids) == 1

      [child_process_instance_id] = child_process_instance_ids
      assert_pi_state!(child_process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # A1: Parent aborted via API, child is waiting at UserTask
  # -------------------------------------------------------------------

  describe "A1: parent abort cascades to running child" do
    test "child PI transitions to aborted when parent is aborted" do
      {201, _} = http_deploy("ca_cascade_waiting_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_parent.bpmn")

      {201, body} = http_start("CaCascadeSimpleParent")
      parent_process_instance_id = body["processInstanceId"]

      {:ok, _child_user_task_fni} =
        poll_child_waiting_user_task(parent_process_instance_id)

      abort_claims = %{"abort_process_instance" => "all"}

      {204, _} =
        http_abort_process_instance(parent_process_instance_id, "test_abort", abort_claims)

      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "aborted")
      assert_no_running_fnis!(parent_process_instance_id)

      [child_process_instance_id] =
        find_child_process_instance_ids(parent_process_instance_id)

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "aborted")
      assert_no_running_fnis!(child_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # A2: Parent aborted after child already finished
  # -------------------------------------------------------------------

  describe "A2: parent abort does not retroactively change finished child" do
    test "child PI stays finished when parent is aborted after child completion" do
      {201, _} = http_deploy("ca_cascade_fast_child.bpmn")
      {201, _} = http_deploy("ca_cascade_parent_then_abort.bpmn")

      {201, body} = http_start("CaCascadeParentThenAbort")
      parent_process_instance_id = body["processInstanceId"]

      poll_parent_waiting_user_task(parent_process_instance_id)

      abort_claims = %{"abort_process_instance" => "all"}

      {204, _} =
        http_abort_process_instance(parent_process_instance_id, "test_abort", abort_claims)

      wait_for_process_instance(parent_process_instance_id, 5_000)

      assert_pi_state!(parent_process_instance_id, "aborted")
      assert_no_running_fnis!(parent_process_instance_id)

      child_process_instance_ids =
        find_child_process_instance_ids(parent_process_instance_id)

      assert length(child_process_instance_ids) == 1

      [child_process_instance_id] = child_process_instance_ids
      assert_pi_state!(child_process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------
  # N1: 3-level chain, root fatal, child + grandchild running
  # -------------------------------------------------------------------

  describe "N1: 3-level fatal cascade" do
    test "fatal cascades through root -> child -> grandchild" do
      {201, _} = http_deploy("ca_cascade_nested_grandchild.bpmn")
      {201, _} = http_deploy("ca_cascade_nested_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_nested_parent.bpmn")

      {201, body} = http_start("CaCascadeSimpleNestedParent")
      root_process_instance_id = body["processInstanceId"]

      {:ok, _grandchild_user_task_fni} =
        poll_grandchild_waiting_user_task(root_process_instance_id)

      :ok = Execution.fatal_process_instance(root_process_instance_id, %{reason: "test_fatal"})
      wait_for_process_instance(root_process_instance_id, 5_000)

      assert_pi_state!(root_process_instance_id, "fatal")
      assert_no_running_fnis!(root_process_instance_id)

      [child_process_instance_id] =
        find_child_process_instance_ids(root_process_instance_id)

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "fatal")
      assert_no_running_fnis!(child_process_instance_id)

      [grandchild_process_instance_id] =
        find_child_process_instance_ids(child_process_instance_id)

      wait_for_process_instance(grandchild_process_instance_id, 5_000)
      assert_pi_state!(grandchild_process_instance_id, "fatal")
      assert_no_running_fnis!(grandchild_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # N2: 3-level chain, root aborted
  # -------------------------------------------------------------------

  describe "N2: 3-level abort cascade" do
    test "abort cascades through root -> child -> grandchild" do
      {201, _} = http_deploy("ca_cascade_nested_grandchild.bpmn")
      {201, _} = http_deploy("ca_cascade_nested_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_nested_parent.bpmn")

      {201, body} = http_start("CaCascadeSimpleNestedParent")
      root_process_instance_id = body["processInstanceId"]

      {:ok, _grandchild_user_task_fni} =
        poll_grandchild_waiting_user_task(root_process_instance_id)

      abort_claims = %{"abort_process_instance" => "all"}

      {204, _} =
        http_abort_process_instance(root_process_instance_id, "test_abort", abort_claims)

      wait_for_process_instance(root_process_instance_id, 5_000)

      assert_pi_state!(root_process_instance_id, "aborted")
      assert_no_running_fnis!(root_process_instance_id)

      [child_process_instance_id] =
        find_child_process_instance_ids(root_process_instance_id)

      wait_for_process_instance(child_process_instance_id, 5_000)
      assert_pi_state!(child_process_instance_id, "aborted")
      assert_no_running_fnis!(child_process_instance_id)

      [grandchild_process_instance_id] =
        find_child_process_instance_ids(child_process_instance_id)

      wait_for_process_instance(grandchild_process_instance_id, 5_000)
      assert_pi_state!(grandchild_process_instance_id, "aborted")
      assert_no_running_fnis!(grandchild_process_instance_id)
    end
  end

  # -------------------------------------------------------------------
  # N3: 3-level, grandchild finishes fast, child waiting, root fatal
  # -------------------------------------------------------------------

  describe "N3: mixed cascade — grandchild finished, child waiting" do
    test "grandchild stays finished, child and root go fatal" do
      {201, _} = http_deploy("ca_cascade_fast_child.bpmn")
      {201, _} = http_deploy("ca_cascade_mixed_child.bpmn")
      {201, _} = http_deploy("ca_cascade_simple_mixed_parent.bpmn")

      {201, body} = http_start("CaCascadeSimpleMixedParent")
      root_process_instance_id = body["processInstanceId"]

      {:ok, _child_user_task_fni} =
        poll_child_waiting_user_task(root_process_instance_id)

      :ok = Execution.fatal_process_instance(root_process_instance_id, %{reason: "test_fatal"})
      wait_for_process_instance(root_process_instance_id, 5_000)

      assert_pi_state!(root_process_instance_id, "fatal")
      assert_no_running_fnis!(root_process_instance_id)

      [mid_child_process_instance_id] =
        find_child_process_instance_ids(root_process_instance_id)

      wait_for_process_instance(mid_child_process_instance_id, 5_000)
      assert_pi_state!(mid_child_process_instance_id, "fatal")
      assert_no_running_fnis!(mid_child_process_instance_id)

      grandchild_process_instance_ids =
        find_child_process_instance_ids(mid_child_process_instance_id)

      Enum.each(grandchild_process_instance_ids, fn grandchild_process_instance_id ->
        assert_pi_state!(grandchild_process_instance_id, "finished")
      end)
    end
  end

  # -------------------------------------------------------------------
  # B1: Boundary event catches child fatal — existing behavior preserved
  # -------------------------------------------------------------------

  describe "B1: error boundary catches child fatal" do
    test "parent finishes via boundary path when child goes fatal" do
      {201, _} = http_deploy("call_activity_failing_child.bpmn")
      {201, _} = http_deploy("call_activity_error_boundary.bpmn")

      {201, body} = http_start("CallActivityErrorBoundary")
      parent_process_instance_id = body["processInstanceId"]

      wait_for_process_instance(parent_process_instance_id, 10_000)

      assert_pi_state!(parent_process_instance_id, "finished")

      child_process_instance_ids =
        find_child_process_instance_ids(parent_process_instance_id)

      Enum.each(child_process_instance_ids, fn child_process_instance_id ->
        assert_pi_state!(child_process_instance_id, "fatal")
      end)
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp find_child_process_instance_ids(parent_process_instance_id) do
    list_child_process_instance_ids(parent_process_instance_id)
  end

  defp poll_parent_waiting_user_task(process_instance_id) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_poll_parent_user_task(process_instance_id, deadline)
  end

  defp do_poll_parent_user_task(process_instance_id, deadline) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    result =
      Enum.find(flow_node_instances, fn flow_node_instance ->
        flow_node_instance.flow_node_type == "user_task" and
          flow_node_instance.state == "waiting"
      end)

    case result do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          do_poll_parent_user_task(process_instance_id, deadline)
        end

      flow_node_instance ->
        {:ok, flow_node_instance}
    end
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
