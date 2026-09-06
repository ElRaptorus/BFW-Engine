defmodule EvilEngine.Integration.StartEndpointTest do
  @moduledoc """
  Integration tests for `POST /processes/{model_id}/start`.

  Covers:
  - Happy paths (H1–H4): successful PI creation via HTTP
  - Bad paths (B1–B9): catalog errors, start-event errors, payload/auth errors
  - Full-stack E2E: deploy → start → complete → assert DB state
  """
  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.EventCollector
  alias EvilEngine.Types.Event

  # -------------------------------------------------------------------------
  # Happy paths
  # -------------------------------------------------------------------------

  describe "H1: deploy + start single-start-event process" do
    test "returns 201 with PI ID, PI reaches finished state", %{collector: collector} do
      {201, deploy_body} = http_deploy("linear_three_node.bpmn")
      assert length(deploy_body["deployed"]) >= 1

      {201, start_body} =
        http_start("LinearThreeNode", %{"payload" => %{"order_id" => 42}})

      process_instance_id = start_body["processInstanceId"]
      assert is_binary(process_instance_id)
      assert start_body["processModelId"] == "LinearThreeNode"
      assert start_body["state"] == "running"
      assert start_body["version"] == "1.0.0"

      wait_for_process_instance(process_instance_id)

      process_instance = assert_pi_state!(process_instance_id, "finished")
      assert process_instance.finished_at != nil
      assert process_instance.started_with_context == nil

      assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")

      events = EventCollector.await_events(collector, 8)
      process_instance_state_change_events = Enum.filter(events, &match?(%Event.ProcessInstanceStateChanged{}, &1))
      assert length(process_instance_state_change_events) == 2
    end
  end

  describe "H2: start with explicit startEventId on single-start process" do
    test "returns 201, strict validation passes", %{collector: _} do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {201, body} =
        http_start("LinearStartEnd", %{
          "startEventId" => "Start_1",
          "payload" => %{"x" => 1}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 2)

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      assert start_fni != nil
    end
  end

  describe "H3: multi-start-event process with explicit startEventId" do
    test "correct start event path is used", %{collector: _} do
      {201, _} = http_deploy("multi_start_events.bpmn")

      {201, body} =
        http_start("MultiStartEvents", %{
          "startEventId" => "Start_B",
          "payload" => %{"path" => "B"}
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")

      flow_node_instances = fetch_flow_node_instances(process_instance_id)
      flow_node_ids = Enum.map(flow_node_instances, & &1.flow_node_id) |> MapSet.new()

      assert MapSet.member?(flow_node_ids, "Start_B")
      assert MapSet.member?(flow_node_ids, "Task_B")
      assert MapSet.member?(flow_node_ids, "End_B")
      refute MapSet.member?(flow_node_ids, "Start_A")
    end
  end

  describe "H4: start with businessKey" do
    test "returns 201, businessKey does not break the start flow", %{collector: _} do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {201, body} =
        http_start("LinearStartEnd", %{
          "payload" => %{"x" => 1},
          "businessKey" => "ext-ref-123"
        })

      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
    end
  end

  # -------------------------------------------------------------------------
  # Bad paths — catalog errors
  # -------------------------------------------------------------------------

  describe "B1: nonexistent process model id" do
    test "returns 404 process_not_found" do
      {404, body} = http_start("nonexistent_process")
      assert body["error"] == "process_not_found"
    end
  end

  describe "B2: disabled process" do
    test "returns 422 process_disabled" do
      {201, _} = http_deploy("linear_start_end.bpmn")
      {204, _} = http_disable("LinearStartEnd")

      {422, body} = http_start("LinearStartEnd")
      assert body["error"] == "process_disabled"
    end
  end

  describe "B3: all versions soft-deleted" do
    test "returns 404 no_active_version" do
      {201, _} = http_deploy("linear_start_end.bpmn")
      {204, _} = http_delete_version("LinearStartEnd", "1.0.0")

      {404, body} = http_start("LinearStartEnd")
      assert body["error"] == "no_active_version"
    end
  end

  # -------------------------------------------------------------------------
  # Bad paths — start-event errors
  # -------------------------------------------------------------------------

  describe "B4: multi-start-event without startEventId" do
    test "returns 422 ambiguous_start_event" do
      {201, _} = http_deploy("multi_start_events.bpmn")

      {422, body} = http_start("MultiStartEvents", %{"payload" => %{}})
      assert body["error"] == "ambiguous_start_event"
      assert is_binary(body["message"])
    end
  end

  describe "B5: nonexistent startEventId" do
    test "returns 422 start_event_not_found" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {422, body} =
        http_start("LinearStartEnd", %{"startEventId" => "Nonexistent_Start"})

      assert body["error"] == "start_event_not_found"
      assert is_binary(body["message"])
    end
  end

  describe "B6: startEventId mismatch on single-start process" do
    test "returns 422 start_event_not_found" do
      {201, _} = http_deploy("multi_start_events.bpmn")

      {422, body} =
        http_start("MultiStartEvents", %{"startEventId" => "Does_Not_Exist"})

      assert body["error"] == "start_event_not_found"
    end
  end

  # -------------------------------------------------------------------------
  # Bad paths — payload errors
  # -------------------------------------------------------------------------

  describe "B7: payload exceeds TDE_TOKEN_MAX_BYTES" do
    test "returns 413 payload_too_large" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      oversize = String.duplicate("x", 65_537)

      {413, body} =
        http_start("LinearStartEnd", %{"payload" => %{"data" => oversize}})

      assert body["error"] == "payload_too_large"
      assert body["field"] == "payload"
      assert is_integer(body["size"])
      assert is_integer(body["limit"])
    end
  end

  # -------------------------------------------------------------------------
  # Bad paths — auth errors
  # -------------------------------------------------------------------------

  describe "B8: unauthenticated request" do
    test "returns 401" do
      conn =
        Plug.Test.conn(:post, "/processes/anything/start", "{}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> route()

      assert conn.status == 401
    end
  end

  describe "B9: expired JWT" do
    test "returns 401" do
      expired_claims = %{
        "exp" => DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_unix()
      }

      conn =
        Plug.Test.conn(:post, "/processes/anything/start", "{}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(expired_claims)}")
        |> route()

      assert conn.status == 401
    end
  end

  # -------------------------------------------------------------------------
  # GET /processes — list deployed processes
  # -------------------------------------------------------------------------

  describe "GET /processes" do
    test "returns deployed processes with latest version" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {200, body} = http_list_processes()
      assert is_list(body)

      entry = Enum.find(body, &(&1["id"] == "LinearStartEnd"))
      assert entry
      assert entry["version"] == "1.0.0"
      assert entry["enabled"] == true
    end

    test "excludes fully-undeployed processes" do
      {201, _} = http_deploy("linear_start_end.bpmn")
      {204, _} = http_undeploy_process("LinearStartEnd")

      {200, body} = http_list_processes()
      refute Enum.any?(body, &(&1["id"] == "LinearStartEnd"))
    end
  end

  # -------------------------------------------------------------------------
  # DELETE /processes/{model_id} — undeploy process
  # -------------------------------------------------------------------------

  describe "DELETE /processes/{model_id}" do
    test "204 removes all versions from the visible listing" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {200, versions_before} = http_list_versions("LinearStartEnd")
      assert length(versions_before) >= 1

      {204, nil} = http_undeploy_process("LinearStartEnd")

      {200, versions_after} = http_list_versions("LinearStartEnd")
      assert versions_after == []
    end

    test "404 for nonexistent process" do
      {404, body} = http_undeploy_process("NonExistent")
      assert body["error"] == "not_found"
    end

    test "404 for already-undeployed process" do
      {201, _} = http_deploy("linear_start_end.bpmn")
      {204, _} = http_undeploy_process("LinearStartEnd")

      {404, body} = http_undeploy_process("LinearStartEnd")
      assert body["error"] == "not_found"
    end

    test "403 without delete_bpmn claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {403, body} = http_undeploy_process("LinearStartEnd", %{"delete_bpmn" => false})
      assert body["error"] == "forbidden"
    end
  end

  # -------------------------------------------------------------------------
  # isExecutable sync on deploy
  # -------------------------------------------------------------------------

  describe "isExecutable sync" do
    @bpmn_template """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                      xmlns:evil="https://evilengine.dev/schema/bpmn"
                      id="Definitions_1">
      <bpmn:process id="SyncTest" name="Sync Test" isExecutable="EXEC_FLAG">
        <bpmn:extensionElements>
          <evil:version>VERSION</evil:version>
        </bpmn:extensionElements>
        <bpmn:startEvent id="Start_1" name="Start"/>
        <bpmn:endEvent id="End_1" name="End"/>
        <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1"/>
      </bpmn:process>
    </bpmn:definitions>
    """

    defp sync_bpmn(version, executable) do
      @bpmn_template
      |> String.replace("VERSION", version)
      |> String.replace("EXEC_FLAG", to_string(executable))
    end

    test "deploy with isExecutable=true creates enabled process" do
      {201, _} = http_deploy_xml(sync_bpmn("1.0.0", true))

      {200, show} = http_show_process("SyncTest")
      assert show["enabled"] == true
    end

    test "disable, redeploy with isExecutable=true → re-enabled" do
      {201, _} = http_deploy_xml(sync_bpmn("1.0.0", true))
      {204, _} = http_disable("SyncTest")

      {200, show} = http_show_process("SyncTest")
      assert show["enabled"] == false

      {201, _} = http_deploy_xml(sync_bpmn("2.0.0", true))

      {200, show2} = http_show_process("SyncTest")
      assert show2["enabled"] == true
    end

    test "deploy with isExecutable=false → disabled, start returns 422" do
      {201, _} = http_deploy_xml(sync_bpmn("1.0.0", false))

      {200, show} = http_show_process("SyncTest")
      assert show["enabled"] == false

      {422, body} = http_start("SyncTest")
      assert body["error"] == "process_disabled"
    end
  end

  # -------------------------------------------------------------------------
  # Full-stack E2E round-trip
  # -------------------------------------------------------------------------

  describe "E2E: deploy → start → complete → query" do
    test "full round-trip through HTTP layer", %{collector: collector} do
      {201, deploy_body} = http_deploy("linear_three_node.bpmn")
      deployed = hd(deploy_body["deployed"])
      assert deployed["processModelId"] == "LinearThreeNode"

      {201, start_body} =
        http_start("LinearThreeNode", %{"payload" => %{"test" => "e2e"}})

      process_instance_id = start_body["processInstanceId"]
      assert start_body["version"] == "1.0.0"

      wait_for_process_instance(process_instance_id)

      {200, show_body} = http_show_process("LinearThreeNode")
      assert show_body["id"] == "LinearThreeNode"

      {200, versions_body} = http_list_versions("LinearThreeNode")
      assert length(versions_body) >= 1

      process_instance = assert_pi_state!(process_instance_id, "finished")
      assert process_instance.process_version_id != nil
      assert process_instance.started_with_context == nil

      flow_node_instances = assert_flow_node_instance_count!(process_instance_id, 3)
      assert_all_fnis_state!(process_instance_id, "finished")

      start_fni = Enum.find(flow_node_instances, &(&1.flow_node_id == "Start_1"))
      assert start_fni.input_token == %{"test" => "e2e"}

      events = EventCollector.await_events(collector, 8)
      process_instance_state_change_events = Enum.filter(events, &match?(%Event.ProcessInstanceStateChanged{}, &1))
      assert length(process_instance_state_change_events) == 2
      assert hd(process_instance_state_change_events).new_state == :running
      assert List.last(process_instance_state_change_events).new_state == :finished
    end
  end
end
