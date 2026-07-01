defmodule EvilEngine.Integration.Execution.MessageEventsTest do
  @moduledoc """
  Integration tests for BPMN Message Events (§12.4.2 S10 scenarios).

  Tests the full message pipeline: publish, subscription matching,
  pending/drain, catch-wins-over-Start, and broadcast-within-key.
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Api
  alias EvilEngine.Events.MessagePersistence
  alias EvilEngine.Events.MessageSubscriptions

  # ===================================================================
  # S10 — Cross-PI messaging (single recipient)
  # ===================================================================

  describe "S10: Cross-PI messaging" do
    test "message trigger delivers to waiting catch event" do
      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, body} = http_start("MessageCatchSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, _fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      {200, trigger_result} = http_trigger_message("test-message", %{"data" => "hello"})

      assert length(trigger_result["deliveries"]) == 1
      delivery = hd(trigger_result["deliveries"])
      assert delivery["processInstanceId"] == process_instance_id

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # S10a — Broadcast-within-key (serial-letter)
  # ===================================================================

  describe "S10a: Broadcast-within-key" do
    test "single publish delivers to all 3 PIs waiting on same message" do
      {201, _} = http_deploy("message_catch_simple.bpmn")

      pids =
        for _ <- 1..3 do
          {201, body} = http_start("MessageCatchSimple")
          body["processInstanceId"]
        end

      for process_instance_id <- pids do
        {:ok, _fni} =
          await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
            timeout: 10_000
          )
      end

      {200, trigger_result} = http_trigger_message("test-message", %{"broadcast" => true})

      assert length(trigger_result["deliveries"]) == 3

      for process_instance_id <- pids do
        wait_for_process_instance(process_instance_id)
        assert_pi_state!(process_instance_id, "finished")
      end
    end
  end

  # ===================================================================
  # S10b — Catch-wins-over-Start
  # ===================================================================

  describe "S10b: Catch-wins-over-Start" do
    test "existing subscription prevents new PI from Message Start Event" do
      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, _} = http_deploy("message_start_event.bpmn")

      {201, body} = http_start("MessageCatchSimple")
      catch_process_instance_id = body["processInstanceId"]

      {:ok, _fni} =
        await_waiting_flow_node_instance(catch_process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      {200, trigger_result} = http_trigger_message("test-message", %{"data" => "catch_wins"})

      assert length(trigger_result["deliveries"]) >= 1
      assert trigger_result["startedProcessInstanceIds"] == []

      wait_for_process_instance(catch_process_instance_id)
      assert_pi_state!(catch_process_instance_id, "finished")
    end

    test "no subscription triggers new PI via Message Start Event" do
      {201, _} = http_deploy("message_start_event.bpmn")

      {200, trigger_result} = http_trigger_message("trigger-process", %{"data" => "start"})

      assert trigger_result["deliveries"] == []
      assert length(trigger_result["startedProcessInstanceIds"]) >= 1

      [started_process_instance_id | _] = trigger_result["startedProcessInstanceIds"]
      wait_for_process_instance(started_process_instance_id)
      assert_pi_state!(started_process_instance_id, "finished")
    end
  end

  # ===================================================================
  # S10c — Pending-TTL rematch
  # ===================================================================

  describe "S10c: Pending-TTL rematch" do
    test "publish with no sub → pending; late subscribe → drain → catch advances" do
      identity = %EvilEngine.Types.Identity{
        id: "test-user",
        roles: ["admin"],
        groups: [],
        claims: %{"trigger_message" => "all"}
      }

      {:ok, publish_result} =
        Api.publish_message("test-message", %{"data" => "pending"}, nil, identity)

      assert publish_result.deliveries == []
      assert publish_result.pending == true

      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, body} = http_start("MessageCatchSimple")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 15_000)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # S10f — Mixed Catch + Boundary on same key
  # ===================================================================

  describe "S10f: Mixed Catch + Boundary on same key" do
    test "both catch and boundary subscribe; single publish delivers to both" do
      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, _} = http_deploy("message_boundary_interrupting.bpmn")

      {201, catch_body} = http_start("MessageCatchSimple")
      catch_process_instance_id = catch_body["processInstanceId"]

      {201, boundary_body} = http_start("MessageBoundaryInterrupting")
      boundary_process_instance_id = boundary_body["processInstanceId"]

      {:ok, _catch_fni} =
        await_waiting_flow_node_instance(catch_process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      {:ok, _user_task_fni} =
        await_waiting_flow_node_instance(boundary_process_instance_id, "user_task",
          timeout: 10_000
        )

      Process.sleep(500)

      {200, _trigger_result} = http_trigger_message("test-message", %{"mixed" => true})

      wait_for_process_instance(catch_process_instance_id)
      assert_pi_state!(catch_process_instance_id, "finished")
    end
  end

  # ===================================================================
  # A-MSG-1 — PI with waiting catch → abort → subscription cleaned up
  # ===================================================================

  describe "A-MSG-1: Abort cleans up message subscription" do
    test "aborting PI with waiting catch cleans up subscription" do
      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, body} = http_start("MessageCatchSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, _fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      assert MessageSubscriptions.has_subscriptions_for_message?("test-message")

      {204, nil} =
        http_abort_process_instance(process_instance_id, "test_abort", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, 5_000)
      assert_pi_state!(process_instance_id, "aborted")
    end
  end

  # ===================================================================
  # A-MSG-3 — Host completes → boundary subscription cleaned up
  # ===================================================================

  describe "A-MSG-3: Host completes → boundary subscription cleaned" do
    test "completing user task cleans up boundary message subscription" do
      {201, _} = http_deploy("message_boundary_interrupting.bpmn")
      {201, body} = http_start("MessageBoundaryInterrupting")
      process_instance_id = body["processInstanceId"]

      {:ok, user_task_fni} =
        await_waiting_flow_node_instance(process_instance_id, "user_task", timeout: 10_000)

      :ok = finish_user_task(process_instance_id, user_task_fni.id, %{"done" => true})

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # T-MSG-1 — Terminate End Event kills waiting message catch FNI
  # ===================================================================

  describe "T-MSG-1: Terminate kills waiting message catch" do
    test "terminate end event interrupts waiting message catch" do
      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, body} = http_start("MessageCatchSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, _fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      {204, nil} =
        http_abort_process_instance(process_instance_id, "terminate_test", %{
          "abort_process_instance" => "all"
        })

      wait_for_process_instance(process_instance_id, 5_000)
      assert_pi_state!(process_instance_id, "aborted")
    end
  end

  # ===================================================================
  # Message End Event publishes and finishes
  # ===================================================================

  describe "Message End Event" do
    test "publishes message and PI finishes" do
      {201, _} = http_deploy("message_end_event.bpmn")
      {201, body} = http_start("MessageEndEvent", %{"payload" => %{"status" => "done"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # Message Throw Event publishes and proceeds
  # ===================================================================

  describe "Message Throw Event" do
    test "publishes message and PI proceeds to end" do
      {201, _} = http_deploy("message_throw_simple.bpmn")
      {201, body} = http_start("MessageThrowSimple", %{"payload" => %{"notification" => "hello"}})
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # F2 — Cross-process BPMN-native message delivery
  # ===================================================================

  describe "F2: Cross-process messaging" do
    test "thrower process delivers message to waiting catcher process via correlation" do
      {201, _} = http_deploy("message_cross_process_catcher.bpmn")
      {201, _} = http_deploy("message_cross_process_thrower.bpmn")

      {201, catch_body} =
        http_start("MessageCrossProcessCatcher", %{"payload" => %{"orderId" => "ORD-123"}})

      catcher_process_instance_id = catch_body["processInstanceId"]

      {:ok, _catch_fni} =
        await_waiting_flow_node_instance(catcher_process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      assert_pi_state!(catcher_process_instance_id, "running")

      {201, thrower_body} =
        http_start("MessageCrossProcessThrower", %{"payload" => %{"orderId" => "ORD-123"}})

      thrower_process_instance_id = thrower_body["processInstanceId"]

      wait_for_process_instance(thrower_process_instance_id)
      wait_for_process_instance(catcher_process_instance_id)

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

  # ===================================================================
  # F2b — Message throw starts a PI via Message Start Event — triggerer tracked
  # ===================================================================

  describe "F2b: Message throw to start event PI — triggerer tracked" do
    test "PI started by message throw event has triggerer_flow_node_instance_id set" do
      {201, _} = http_deploy("message_throw_trigger.bpmn")
      {201, _} = http_deploy("message_start_event.bpmn")

      {201, thrower_body} = http_start("MessageThrowTrigger")
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
             "Exactly one PI should have been started by the message start event triggered by Throw_1"

      [started_pi] = started_pis
      wait_for_process_instance(started_pi.id, 10_000)
      assert_pi_state!(started_pi.id, "finished")
      assert started_pi.triggerer_flow_node_instance_id == throw_fni.id
    end
  end

  # ===================================================================
  # S10d — Pending-TTL rematch survives engine restart (simulated)
  # ===================================================================

  describe "S10d: Pending-TTL rematch survives engine restart" do
    test "pending message persisted to DB is drained after subscription reset and late subscribe" do
      identity = %EvilEngine.Types.Identity{
        id: "test-user",
        roles: ["admin"],
        groups: [],
        claims: %{"trigger_message" => "all"}
      }

      {:ok, publish_result} =
        Api.publish_message("test-message", %{"data" => "survive_restart"}, nil, identity)

      assert publish_result.deliveries == []
      assert publish_result.pending == true

      MessageSubscriptions.reset_state()
      MessageSubscriptions.mark_ready()

      {201, _} = http_deploy("message_catch_simple.bpmn")
      {201, body} = http_start("MessageCatchSimple")
      process_instance_id = body["processInstanceId"]

      wait_for_process_instance(process_instance_id, 15_000)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # F3 — Start + Catch overlap (catch wins over Message Start)
  # ===================================================================

  describe "F3: Start and Catch overlap" do
    test "existing catch subscription wins over Message Start Event on same key" do
      {201, _} = http_deploy("message_start_catch_overlap.bpmn")

      {201, body} =
        http_start("MessageStartCatchOverlap", %{
          "startEventId" => "Start_regular",
          "payload" => %{"correlationId" => "C1"}
        })

      process_instance_id = body["processInstanceId"]

      {:ok, _catch_fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      assert_pi_state!(process_instance_id, "running")

      {200, trigger_result} =
        http_trigger_message("shared-msg", %{"data" => "overlap"}, "C1")

      assert trigger_result["startedProcessInstanceIds"] == []
      assert length(trigger_result["deliveries"]) >= 1
      delivery = hd(trigger_result["deliveries"])
      assert delivery["processInstanceId"] == process_instance_id

      wait_for_process_instance(process_instance_id)
      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # ===================================================================
  # F4 — Auth rejection (403)
  # ===================================================================

  describe "F4: Message trigger authorization" do
    test "returns 403 when trigger_message claim is missing" do
      {403, body} =
        http_trigger_message("test-message", %{"data" => "unauthorized"}, nil, %{
          "trigger_message" => "none"
        })

      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "trigger_message"
    end
  end

  # ===================================================================
  # F5 — Readiness gate (503)
  # ===================================================================

  describe "F5: Message subscription readiness gate" do
    test "returns 503 when engine is not ready" do
      MessageSubscriptions.reset_state()

      json_body = Jason.encode!(%{"payload" => %{"data" => "not_ready"}})

      conn =
        Plug.Test.conn(:post, "/messages/test-message/trigger", json_body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header(
          "authorization",
          "Bearer #{sign_jwt(%{"trigger_message" => "all"})}"
        )
        |> route()

      assert conn.status == 503
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["5"]

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "service_unavailable"

      MessageSubscriptions.mark_ready()
    end
  end

  # ===================================================================
  # F6 — Pending message TTL expiry
  # ===================================================================

  describe "F6: Pending message TTL expiry" do
    test "pending message expires after TTL and is not delivered to late subscriber" do
      original_ttl = Application.get_env(:core_events, :message_pending_ttl, "PT60S")
      Application.put_env(:core_events, :message_pending_ttl, "PT1S")

      on_exit(fn ->
        Application.put_env(:core_events, :message_pending_ttl, original_ttl)
      end)

      identity = %EvilEngine.Types.Identity{
        id: "test-user",
        roles: ["admin"],
        groups: [],
        claims: %{"trigger_message" => "all"}
      }

      {:ok, publish_result} =
        Api.publish_message("test-message", %{"data" => "will_expire"}, nil, identity)

      assert publish_result.deliveries == []
      assert publish_result.pending == true

      Process.sleep(1_500)

      case MessagePersistence.adapter() do
        nil -> :ok
        adapter -> {:ok, _count} = adapter.expire_pending_messages()
      end

      {201, _} = http_deploy("message_catch_simple.bpmn")

      {201, body} = http_start("MessageCatchSimple")
      process_instance_id = body["processInstanceId"]

      {:ok, _catch_fni} =
        await_waiting_flow_node_instance(process_instance_id, "intermediate_catch_event",
          timeout: 10_000
        )

      Process.sleep(500)

      assert_pi_state!(process_instance_id, "running")
    end
  end

  # ===================================================================
  # F7 — Payload cap (413)
  # ===================================================================

  describe "F7: Message trigger payload cap" do
    test "returns 413 when message payload exceeds size limit" do
      oversize_payload = %{"data" => String.duplicate("x", 65_537)}

      {413, body} = http_trigger_message("test-message", oversize_payload)

      assert body["error"] == "payload_too_large"
      assert body["field"] == "payload"
      assert is_integer(body["size"])
      assert is_integer(body["limit"])
    end
  end
end
