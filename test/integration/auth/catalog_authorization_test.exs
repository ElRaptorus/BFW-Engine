defmodule BfwEngine.Integration.Auth.CatalogAuthorizationTest do
  @moduledoc """
  Authorization tests for REST catalog endpoints.

  Verifies claim enforcement for:
  - `deploy_bpmn` on POST /processes, PUT /…/enable, PUT /…/disable
  - `delete_bpmn` on DELETE /…/versions/{version}
  - Lane-based start check on POST /…/start (laned start event)
  """
  use BfwEngine.ExecutionCase, async: false

  # -------------------------------------------------------------------------
  # Deploy — deploy_bpmn claim
  # -------------------------------------------------------------------------

  describe "deploy: deploy_bpmn claim" do
    test "403 without deploy_bpmn claim" do
      {403, body} = http_deploy("linear_start_end.bpmn", %{"deploy_bpmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "deploy_bpmn"
      assert body["resource"] == "process"
    end

    test "403 when deploy_bpmn claim is entirely absent" do
      {403, body} = http_deploy("linear_start_end.bpmn", %{"deploy_bpmn" => nil})
      assert body["error"] == "forbidden"
    end

    test "201 with deploy_bpmn claim" do
      {201, body} = http_deploy("linear_start_end.bpmn")
      assert is_list(body["deployed"])
    end

    test "201 with zeeky_boogie_doog admin override (no deploy_bpmn)" do
      {201, _} =
        http_deploy("linear_start_end.bpmn", %{
          "deploy_bpmn" => false,
          "zeeky_boogie_doog" => true
        })
    end
  end

  # -------------------------------------------------------------------------
  # Enable — deploy_bpmn claim
  # -------------------------------------------------------------------------

  describe "enable: deploy_bpmn claim" do
    test "403 without deploy_bpmn claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {403, body} = http_enable("LinearStartEnd", %{"deploy_bpmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "deploy_bpmn"
    end

    test "204 with deploy_bpmn claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {204, nil} = http_enable("LinearStartEnd")
    end
  end

  # -------------------------------------------------------------------------
  # Disable — deploy_bpmn claim
  # -------------------------------------------------------------------------

  describe "disable: deploy_bpmn claim" do
    test "403 without deploy_bpmn claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {403, body} = http_disable("LinearStartEnd", %{"deploy_bpmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "deploy_bpmn"
    end

    test "204 with deploy_bpmn claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {204, nil} = http_disable("LinearStartEnd")
    end
  end

  # -------------------------------------------------------------------------
  # Delete version — delete_bpmn claim
  # -------------------------------------------------------------------------

  describe "delete_version: delete_bpmn claim" do
    test "403 without delete_bpmn claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {403, body} = http_delete_version("LinearStartEnd", "1.0.0", %{"delete_bpmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "delete_bpmn"
      assert body["resource"] == "process"
    end

    test "204 with delete_bpmn claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {204, nil} = http_delete_version("LinearStartEnd", "1.0.0")
    end

    test "204 with zeeky_boogie_doog admin override (no delete_bpmn)" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {204, _} =
        http_delete_version("LinearStartEnd", "1.0.0", %{
          "delete_bpmn" => false,
          "zeeky_boogie_doog" => true
        })
    end
  end

  # -------------------------------------------------------------------------
  # Start — lane-based authorization
  # -------------------------------------------------------------------------

  describe "start: lane-based authorization" do
    test "404 when start event is on 'Management' lane and caller lacks lane:Management (lane denial hides existence)" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      {404, body} = http_start("LanedUserTask", %{}, %{"lane:Management" => nil})
      assert body["error"] == "not_found"
    end

    test "201 when caller has matching lane claim (Management)" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      {201, body} = http_start("LanedUserTask", %{}, %{"lane:Management" => "write"})
      assert is_binary(body["processInstanceId"])
    end

    test "403 when caller has read-only lane claim" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      {403, body} = http_start("LanedUserTask", %{}, %{"lane:Management" => "read"})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "lane:Management"
      assert body["requiredValue"] == "write"
    end

    test "404 when leftover boolean true is not a write alias" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      {404, body} = http_start("LanedUserTask", %{}, %{"lane:Management" => true})
      assert body["error"] == "not_found"
    end

    test "404 for garbage lane values that are not read or write" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      for garbage <- ["WRITE", "READ", "", 1] do
        {404, body} = http_start("LanedUserTask", %{}, %{"lane:Management" => garbage})
        assert body["error"] == "not_found"
      end
    end

    test "404 when caller lacks default lane claim (lane denial hides existence)" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {404, body} = http_start("LinearStartEnd", %{}, %{"lane:default" => nil})
      assert body["error"] == "not_found"
    end

    test "201 when caller has default lane claim" do
      {201, _} = http_deploy("linear_start_end.bpmn")

      {201, body} = http_start("LinearStartEnd")
      assert is_binary(body["processInstanceId"])
    end

    test "201 with zeeky_boogie_doog admin override (no lane claim)" do
      {201, _} = http_deploy("user_task_with_lane.bpmn")

      {201, _} =
        http_start("LanedUserTask", %{}, %{
          "lane:Management" => nil,
          "lane:default" => nil,
          "zeeky_boogie_doog" => true
        })
    end
  end
end
