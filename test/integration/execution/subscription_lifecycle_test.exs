defmodule BfwEngine.Integration.Execution.SubscriptionLifecycleTest do
  @moduledoc """
  Message and signal subscription lifecycle: a resumed boundary records its
  re-registered subscription (C2), and a pending message or signal drained by
  an Event Subprocess start fires that Event Subprocess (C3).
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Execution.ResumeRunner
  alias BfwEngine.Persistence.Resources.FlowNodeInstance

  @poll_attempts 100
  @poll_interval_ms 25

  describe "C2: resumed message boundary" do
    test "records the re-registered subscription and leaves none behind once the host finishes" do
      process_instance_id =
        http_deploy_and_start("message_boundary_interrupting.bpmn", "MessageBoundaryInterrupting")

      user_task = poll_fni_state(process_instance_id, "user_task", "waiting")
      boundary = poll_fni_state(process_instance_id, "boundary_event", "waiting")
      stale_subscription_id = boundary.type_properties["subscription_id"]
      assert is_binary(stale_subscription_id)

      restart_process_instance(process_instance_id)

      live_subscription = await_live_message_subscription(process_instance_id)
      refute live_subscription.subscription_id == stale_subscription_id

      assert await_persisted_subscription_id(boundary.id, stale_subscription_id) ==
               live_subscription.subscription_id

      {204, _body} = http_finish_user_task(user_task.id)
      wait_for_process_instance(process_instance_id)

      assert message_subscriptions(process_instance_id) == []

      {200, publish_body} = http_trigger_message("cancel-task")
      assert publish_body["deliveries"] == []
      assert publish_body["pending"] == true
    end
  end

  describe "C3: pending deliveries to Event Subprocess starts" do
    test "a pending message fires the message Event Subprocess when its scope starts" do
      {200, publish_body} = http_trigger_message("esp-message")
      assert publish_body["pending"] == true

      process_instance_id =
        http_deploy_and_start("event_subprocess_message.bpmn", "EventSubprocessMessage")

      poll_pi_state(process_instance_id, "finished")

      assert %{state: "finished"} = find_fni_by_flow_node_id(process_instance_id, "ESP_Message")

      assert %{state: "interrupted"} =
               find_fni_by_flow_node_id(process_instance_id, "Main_UserTask")
    end

    test "a pending signal fires the signal Event Subprocess when its scope starts" do
      {200, publish_body} = http_trigger_signal("esp-signal")
      assert publish_body["pending"] == true

      process_instance_id =
        http_deploy_and_start("event_subprocess_signal.bpmn", "EventSubprocessSignal")

      poll_pi_state(process_instance_id, "finished")

      assert %{state: "finished"} = find_fni_by_flow_node_id(process_instance_id, "ESP_Signal")
    end

    test "without a pending message the Event Subprocess stays dormant" do
      process_instance_id =
        http_deploy_and_start("event_subprocess_message.bpmn", "EventSubprocessMessage")

      poll_fni_state(process_instance_id, "user_task", "waiting")

      assert find_fni_by_flow_node_id(process_instance_id, "ESP_Message") == nil
      assert_pi_state!(process_instance_id, "running")
    end
  end

  defp restart_process_instance(process_instance_id) do
    {:ok, pid} = Execution.lookup_process_instance(process_instance_id)
    reference = Process.monitor(pid)
    DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 2_000

    {:ok, _resumed_count} = ResumeRunner.resume_all()
    {:ok, _pid} = poll_pi_alive(process_instance_id)
  end

  defp await_live_message_subscription(process_instance_id) do
    poll(fn ->
      process_instance_id
      |> message_subscriptions()
      |> Enum.find(&Process.alive?(&1.via_pid))
    end)
  end

  defp await_persisted_subscription_id(flow_node_instance_id, stale_subscription_id) do
    poll(fn ->
      record =
        Ash.get!(FlowNodeInstance, flow_node_instance_id,
          domain: BfwEngine.Persistence.Api,
          authorize?: false
        )

      case record.type_properties["subscription_id"] do
        ^stale_subscription_id -> nil
        subscription_id -> subscription_id
      end
    end)
  end

  defp message_subscriptions(process_instance_id) do
    :bfw_engine_message_subscriptions
    |> :ets.tab2list()
    |> Enum.map(fn {_key, subscription} -> subscription end)
    |> Enum.filter(&(&1.process_instance_id == process_instance_id))
  end

  defp poll(function, attempt \\ 1) do
    case function.() do
      nil when attempt < @poll_attempts ->
        Process.sleep(@poll_interval_ms)
        poll(function, attempt + 1)

      nil ->
        flunk("condition not met after #{@poll_attempts} attempts")

      value ->
        value
    end
  end
end
