defmodule BfwEngine.Integration.Execution.BoundaryHostScopeTest do
  @moduledoc """
  Boundaries act on their own host instance: Timer and Conditional
  boundaries forward the host's input token (C13), an error boundary on one
  of two concurrent instances of the same activity finishes that instance's
  boundary only (C15), and `bfw:errorMessage` never filters a code match
  (C14).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Plugins.FacadeBuilder
  alias BfwEngine.Test.ExamplePlugin

  describe "C13: data-less boundaries forward the host token" do
    test "a timer boundary path receives the host's input token" do
      process_instance_id =
        http_deploy_and_start(
          "timer_boundary_forwards_host_token.bpmn",
          "TimerBoundaryForwardsHostToken",
          %{"payload" => %{"orderId" => "ORD-1"}}
        )

      _host = poll_fni_state(process_instance_id, "user_task", "waiting")
      boundary = poll_fni_state(process_instance_id, "boundary_event", "waiting")

      {200, %{"triggered" => true}} = http_trigger_timer_event(boundary.id)
      poll_pi_state(process_instance_id, "finished")

      assert %{input_token: %{"orderId" => "ORD-1"}} =
               find_fni_by_flow_node_id(process_instance_id, "End_Timer")
    end

    test "a conditional boundary path receives the host's input token" do
      process_instance_id =
        http_deploy_and_start(
          "conditional_boundary_interrupting.bpmn",
          "ConditionalBoundaryInterrupting",
          %{"payload" => %{"orderId" => "ORD-2"}}
        )

      poll_pi_state(process_instance_id, "finished")

      assert %{input_token: %{"orderId" => "ORD-2"}} =
               find_fni_by_flow_node_id(process_instance_id, "End_Interrupted")
    end
  end

  describe "C14/C15: error boundary on concurrent instances of one activity" do
    setup do
      Application.put_env(
        :bfw_engine,
        :service_task_dispatch,
        BfwEngine.Plugins.RegistryDispatch
      )

      ExamplePlugin.on_load(FacadeBuilder.build("evil:test_boundary_host_scope"))
      :ok
    end

    test "only the failing instance's boundary fires; the sibling instance keeps waiting" do
      process_instance_id =
        http_deploy_and_start(
          "error_boundary_concurrent_host_instances.bpmn",
          "ErrorBoundaryConcurrentHostInstances"
        )

      [first_host, second_host] = await_waiting(process_instance_id, "ServiceTask_Park", 2)
      _boundaries = await_waiting(process_instance_id, "Boundary_Error", 2)

      :ok =
        Execution.fail_async_service_task(second_host.id, "PARK_FAILED", "a runtime message")

      {:ok, %{state: "finished"}} =
        await_finished_fni_by_node_id(process_instance_id, "End_Caught")

      boundaries_by_host =
        process_instance_id
        |> fetch_flow_node_instances()
        |> Enum.filter(&(&1.flow_node_id == "Boundary_Error"))
        |> Map.new(fn boundary -> {hd(boundary.previous_flow_node_instance_ids), boundary} end)

      assert boundaries_by_host[second_host.id].state == "finished"
      assert boundaries_by_host[first_host.id].state == "waiting"
      assert flow_node_instance_state(process_instance_id, first_host.id) == "waiting"
      assert flow_node_instance_state(process_instance_id, second_host.id) == "interrupted"
      assert_pi_state!(process_instance_id, "running")
    end
  end

  defp await_waiting(process_instance_id, flow_node_id, expected_count, attempt \\ 1) do
    waiting =
      process_instance_id
      |> fetch_flow_node_instances()
      |> Enum.filter(&(&1.flow_node_id == flow_node_id and &1.state == "waiting"))
      |> Enum.sort_by(& &1.id)

    cond do
      length(waiting) == expected_count ->
        waiting

      attempt >= 200 ->
        flunk("expected #{expected_count} waiting #{flow_node_id}, got #{length(waiting)}")

      true ->
        Process.sleep(25)
        await_waiting(process_instance_id, flow_node_id, expected_count, attempt + 1)
    end
  end

  defp flow_node_instance_state(process_instance_id, flow_node_instance_id) do
    process_instance_id
    |> fetch_flow_node_instances()
    |> Enum.find(&(&1.id == flow_node_instance_id))
    |> Map.fetch!(:state)
  end
end
