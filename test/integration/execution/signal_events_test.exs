defmodule EvilEngine.Integration.Execution.SignalEventsTest do
  @moduledoc """
  Umbrella-level integration tests for BPMN Signal Events.

  Verifies signal publication, broadcast delivery to catch events, signal
  start event triggering, and — critically — that `triggerer_flow_node_instance_id`
  is correctly propagated from the throwing FNI to each receiving FNI or
  PI that the signal triggers.

  Scenarios covered:

  - S-SIG-1: Cross-process signal catch — intermediate catch event receives broadcast;
    `triggerer_flow_node_instance_id` on the catch FNI points to the throw FNI.

  - S-SIG-2: Signal throw starts a PI via Signal Start Event — the newly started PI's
    `triggerer_flow_node_instance_id` points to the throw FNI in the thrower PI.
  """
  use EvilEngine.ExecutionCase, async: false

  # ---------------------------------------------------------------------------
  # S-SIG-1: Cross-process signal catch — triggerer propagation
  # ---------------------------------------------------------------------------

  describe "S-SIG-1: Cross-process signal catch — triggerer tracked" do
    test "Catch_1 FNI triggerer_flow_node_instance_id references the throwing Throw_1 FNI" do
      {201, _} = http_deploy("signal_cross_process_catch.bpmn")
      {201, _} = http_deploy("signal_cross_process_throw.bpmn")

      {201, catch_body} = http_start("SignalCrossProcessCatch")
      catcher_process_instance_id = catch_body["processInstanceId"]

      {:ok, _catch_fni} =
        await_waiting_flow_node_instance(catcher_process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      assert_pi_state!(catcher_process_instance_id, "running")

      {201, thrower_body} = http_start("SignalCrossProcessThrow")
      thrower_process_instance_id = thrower_body["processInstanceId"]

      wait_for_process_instance(thrower_process_instance_id, 10_000)
      wait_for_process_instance(catcher_process_instance_id, 10_000)

      assert_pi_state!(thrower_process_instance_id, "finished")
      assert_pi_state!(catcher_process_instance_id, "finished")

      thrower_fnis = fetch_flow_node_instances(thrower_process_instance_id)
      throw_fni = Enum.find(thrower_fnis, &(&1.flow_node_id == "Throw_1"))

      catcher_fnis = fetch_flow_node_instances(catcher_process_instance_id)
      catch_fni = Enum.find(catcher_fnis, &(&1.flow_node_id == "Catch_1"))

      assert throw_fni != nil, "Throw_1 FNI must exist in thrower PI"
      assert catch_fni != nil, "Catch_1 FNI must exist in catcher PI"

      assert catch_fni.triggerer_flow_node_instance_id == throw_fni.id,
             "Catch_1 FNI triggerer_flow_node_instance_id should reference the Throw_1 FNI"
    end
  end

  # ---------------------------------------------------------------------------
  # S-SIG-2: Signal throw starts a PI via Signal Start Event — triggerer tracked
  # ---------------------------------------------------------------------------

  describe "S-SIG-2: Signal throw to start event PI — triggerer tracked" do
    test "PI started by signal throw event has triggerer_flow_node_instance_id set" do
      {201, _} = http_deploy("signal_throw_trigger.bpmn")
      {201, _} = http_deploy("signal_start_event.bpmn")

      {201, thrower_body} = http_start("SignalThrowTrigger")
      thrower_process_instance_id = thrower_body["processInstanceId"]

      wait_for_process_instance(thrower_process_instance_id, 10_000)
      assert_pi_state!(thrower_process_instance_id, "finished")

      thrower_fnis = fetch_flow_node_instances(thrower_process_instance_id)
      throw_fni = Enum.find(thrower_fnis, &(&1.flow_node_id == "Throw_1"))
      assert throw_fni != nil, "Throw_1 FNI must exist in thrower PI"

      require Ash.Query

      started_pis =
        EvilEngine.Persistence.Resources.ProcessInstance
        |> Ash.Query.filter(triggerer_flow_node_instance_id == ^throw_fni.id)
        |> Ash.read!(domain: EvilEngine.Persistence.Api, authorize?: false)

      assert length(started_pis) == 1,
             "Exactly one PI should have been started by the signal start event triggered by Throw_1"

      [started_pi] = started_pis
      wait_for_process_instance(started_pi.id, 10_000)
      assert_pi_state!(started_pi.id, "finished")
      assert started_pi.triggerer_flow_node_instance_id == throw_fni.id
    end
  end
end
