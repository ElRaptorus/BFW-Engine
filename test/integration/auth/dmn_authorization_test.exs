defmodule EvilEngine.Integration.Auth.DmnAuthorizationTest do
  @moduledoc """
  Authorization tests for REST DMN catalog endpoints.

  Verifies claim enforcement for:
  - `deploy_dmn` on POST /decisions, PUT /…/enable, PUT /…/disable
  - `delete_dmn` on DELETE /…/versions/{version} and DELETE /…
  - 401 for unauthenticated requests
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @definitions_discount "definitions_discount"

  # -------------------------------------------------------------------------
  # Deploy — deploy_dmn claim
  # -------------------------------------------------------------------------

  describe "deploy: deploy_dmn claim" do
    test "403 without deploy_dmn claim" do
      {403, body} = http_deploy_dmn("simple_unique.dmn", %{"deploy_dmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "deploy_dmn"
      assert body["resource"] == "decision"
    end

    test "403 when deploy_dmn claim is entirely absent" do
      {403, body} = http_deploy_dmn("simple_unique.dmn", %{"deploy_dmn" => nil})
      assert body["error"] == "forbidden"
    end

    test "201 with deploy_dmn claim" do
      {201, body} = http_deploy_dmn("simple_unique.dmn")
      assert is_list(body["deployed"])
    end

    test "201 with zeeky_boogie_doog admin override (no deploy_dmn)" do
      {201, _} =
        http_deploy_dmn("simple_unique.dmn", %{
          "deploy_dmn" => false,
          "zeeky_boogie_doog" => true
        })
    end
  end

  # -------------------------------------------------------------------------
  # Enable — deploy_dmn claim
  # -------------------------------------------------------------------------

  describe "enable: deploy_dmn claim" do
    test "403 without deploy_dmn claim" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {403, body} = http_enable_decision(@definitions_discount, %{"deploy_dmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "deploy_dmn"
    end

    test "204 with deploy_dmn claim" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {204, nil} = http_enable_decision(@definitions_discount)
    end
  end

  # -------------------------------------------------------------------------
  # Disable — deploy_dmn claim
  # -------------------------------------------------------------------------

  describe "disable: deploy_dmn claim" do
    test "403 without deploy_dmn claim" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {403, body} = http_disable_decision(@definitions_discount, %{"deploy_dmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "deploy_dmn"
    end

    test "204 with deploy_dmn claim" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {204, nil} = http_disable_decision(@definitions_discount)
    end
  end

  # -------------------------------------------------------------------------
  # Delete version — delete_dmn claim
  # -------------------------------------------------------------------------

  describe "delete_version: delete_dmn claim" do
    test "403 without delete_dmn claim" do
      {201, body} = http_deploy_dmn("simple_unique.dmn")
      version = hd(body["deployed"])["version"]

      {403, body} =
        http_delete_decision_version(@definitions_discount, version, %{"delete_dmn" => false})

      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "delete_dmn"
      assert body["resource"] == "decision"
    end

    test "204 with delete_dmn claim" do
      {201, body} = http_deploy_dmn("simple_unique.dmn")
      version = hd(body["deployed"])["version"]

      {204, nil} = http_delete_decision_version(@definitions_discount, version)
    end

    test "204 with zeeky_boogie_doog admin override (no delete_dmn)" do
      {201, body} = http_deploy_dmn("simple_unique.dmn")
      version = hd(body["deployed"])["version"]

      {204, _} =
        http_delete_decision_version(@definitions_discount, version, %{
          "delete_dmn" => false,
          "zeeky_boogie_doog" => true
        })
    end
  end

  # -------------------------------------------------------------------------
  # Undeploy — delete_dmn claim
  # -------------------------------------------------------------------------

  describe "undeploy: delete_dmn claim" do
    test "403 without delete_dmn claim" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")

      {403, body} = http_undeploy_decision(@definitions_discount, %{"delete_dmn" => false})
      assert body["error"] == "forbidden"
      assert body["requiredClaim"] == "delete_dmn"
    end

    test "204 with delete_dmn claim" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {204, nil} = http_undeploy_decision(@definitions_discount)
    end
  end

  # -------------------------------------------------------------------------
  # 401 — missing JWT
  # -------------------------------------------------------------------------

  describe "401 for unauthenticated requests" do
    test "POST /decisions without JWT returns 401" do
      conn =
        Plug.Test.conn(:post, "/decisions", Jason.encode!(%{"sources" => ["<xml/>"]}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> route()

      assert conn.status == 401
    end

    test "GET /decisions without JWT returns 401" do
      conn =
        Plug.Test.conn(:get, "/decisions")
        |> route()

      assert conn.status == 401
    end

    test "POST /decisions/:id/evaluate without JWT returns 401" do
      conn =
        Plug.Test.conn(:post, "/decisions/foo/evaluate", Jason.encode!(%{"input" => %{}}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> route()

      assert conn.status == 401
    end
  end
end
