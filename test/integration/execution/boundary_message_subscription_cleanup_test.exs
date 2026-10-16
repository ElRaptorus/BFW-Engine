defmodule BfwEngine.Integration.Execution.BoundaryMessageSubscriptionCleanupTest do
  @moduledoc "Regression: a message boundary on an instantly finishing host leaves no orphaned subscription (C1)."
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Events.MessageSubscriptions

  @message_name "instant-host-message"

  describe "C1: message boundary on an instant host" do
    test "no subscription with a dead via_pid remains and a later publish is pending" do
      process_instance_id =
        http_deploy_and_start("boundary_message_instant_host.bpmn", "BoundaryMessageInstantHost")

      _ = poll_fni_state(process_instance_id, "user_task", "waiting")

      orphaned_subscriptions =
        @message_name
        |> MessageSubscriptions.lookup(:none)
        |> Enum.filter(&(&1.process_instance_id == process_instance_id))
        |> Enum.reject(&Process.alive?(&1.via_pid))

      assert orphaned_subscriptions == []

      {200, publish_body} = http_trigger_message(@message_name)

      assert publish_body["deliveries"] == []
      assert publish_body["pending"] == true
      assert find_fni_by_flow_node_id(process_instance_id, "End_Boundary") == nil
    end

    test "the interrupted boundary leaves no subscription row, whether it was active or waiting" do
      {201, _} = http_deploy("boundary_message_instant_host.bpmn")

      for _run <- 1..10 do
        {201, start_body} = http_start("BoundaryMessageInstantHost")
        process_instance_id = start_body["processInstanceId"]

        _ = poll_fni_state(process_instance_id, "user_task", "waiting")

        case find_fni_by_flow_node_id(process_instance_id, "Boundary_Message") do
          nil -> :ok
          boundary -> assert boundary.state == "interrupted"
        end

        refute MessageSubscriptions.has_subscriptions_for_message?(@message_name)
      end
    end
  end
end
