defmodule EvilEngine.Integration.Execution.TimerEventTriggerTest do
  @moduledoc """
  Integration tests for POST /timer-events/:flow_node_instance_id/trigger.

  All tests are strictly black-box (HTTP round-trips only).
  """
  use EvilEngine.ExecutionCase, async: false

  @test_secret "test_only_secret_at_least_32_bytes!"

  # ===========================================================================
  # Happy paths
  # ===========================================================================

  describe "POST /timer-events/:flow_node_instance_id/trigger" do
    test "triggers a waiting timer catch event and PI completes" do
      process_instance_id =
        http_deploy_and_start("timer_catch_manual_trigger.bpmn", "TimerCatchManualTrigger")

      {:ok, _waiting_catch} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      flow_node_instance = find_timer_fni!(process_instance_id)

      {200, body} = http_trigger_timer_event(flow_node_instance.id)
      assert body["triggered"] == true

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end

    test "returns 404 for non-existent FNI" do
      {404, body} = http_trigger_timer_event(Ash.UUIDv7.generate())
      assert body["error"] == "not_found"
    end

    test "returns 422 for FNI that is not a timer event" do
      process_instance_id = http_deploy_and_start("user_task_simple.bpmn", "UserTaskSimple")

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      {422, body} = http_trigger_timer_event(user_task_fni.id)
      assert body["error"] == "not_a_timer_event"
    end

    test "returns 409 for already-finished timer FNI" do
      process_instance_id =
        http_deploy_and_start("timer_catch_manual_trigger.bpmn", "TimerCatchManualTrigger")

      {:ok, _waiting_catch} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      flow_node_instance = find_timer_fni!(process_instance_id)

      {200, first_body} = http_trigger_timer_event(flow_node_instance.id)
      assert first_body["triggered"] == true

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")

      {409, body} = http_trigger_timer_event(flow_node_instance.id)
      assert body["error"] == "conflict"
    end
  end

  # ===========================================================================
  # Lane access
  # ===========================================================================

  describe "timer trigger authorization (lane visibility)" do
    test "returns 404 when caller lacks lane claim for laned timer" do
      process_instance_id = deploy_and_start_laned_timer_catch()

      {:ok, _waiting_catch} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      flow_node_instance = find_timer_fni!(process_instance_id)

      claims_without_lane = %{"sub" => "no-lane-user"}
      {404, body} = http_trigger_timer_event(flow_node_instance.id, claims_without_lane)
      assert body["error"] == "not_found"
    end

    test "200 when caller has matching lane claim" do
      process_instance_id = deploy_and_start_laned_timer_catch()

      {:ok, _waiting_catch} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      flow_node_instance = find_timer_fni!(process_instance_id)

      claims_with_lane = %{"lane:Operations" => "write"}
      {200, body} = http_trigger_timer_event(flow_node_instance.id, claims_with_lane)
      assert body["triggered"] == true
    end

    test "403 when caller has a read claim on the timer lane" do
      process_instance_id = deploy_and_start_laned_timer_catch()

      {:ok, _waiting_catch} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      flow_node_instance = find_timer_fni!(process_instance_id)

      {403, body} = http_trigger_timer_event(flow_node_instance.id, %{"lane:Operations" => "read"})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:Operations"
      assert body["requiredValue"] == "write"
    end
  end

  # ===========================================================================
  # Auth
  # ===========================================================================

  describe "timer trigger authentication" do
    test "returns 401 for unauthenticated request" do
      flow_node_instance_id = Ash.UUIDv7.generate()

      conn =
        Plug.Test.conn(:post, "/timer-events/#{flow_node_instance_id}/trigger", "{}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> route()

      assert conn.status == 401
    end

    test "returns 401 for expired JWT" do
      flow_node_instance_id = Ash.UUIDv7.generate()
      expired_token = sign_expired_jwt()

      conn =
        Plug.Test.conn(:post, "/timer-events/#{flow_node_instance_id}/trigger", "{}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{expired_token}")
        |> route()

      assert conn.status == 401
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp find_timer_fni!(process_instance_id) do
    flow_node_instances = fetch_flow_node_instances(process_instance_id)

    flow_node_instance =
      Enum.find(flow_node_instances, fn flow_node_instance ->
        flow_node_instance.flow_node_type in ["intermediate_catch_event", "boundary_event"] and
          flow_node_instance.event_type == "timer" and
          flow_node_instance.state in ["active", "waiting"]
      end)

    assert flow_node_instance != nil,
           "Expected a waiting/active timer FNI for PI #{process_instance_id}"

    flow_node_instance
  end

  defp deploy_and_start_laned_timer_catch do
    {201, _} = http_deploy("timer_catch_laned_trigger.bpmn")
    {201, body} = http_start("TimerCatchLanedTrigger", %{}, %{"lane:Operations" => "write"})
    body["processInstanceId"]
  end

  defp sign_expired_jwt do
    secret = Application.get_env(:api_auth, :hs256_secret) || @test_secret
    jwk = JOSE.JWK.from_oct(secret)

    claims = %{
      "sub" => "expired-user",
      "exp" => DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_unix()
    }

    {_, compact} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
    compact
  end
end
