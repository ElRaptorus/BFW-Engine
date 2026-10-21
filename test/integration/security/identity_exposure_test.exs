defmodule BfwEngine.Integration.Security.IdentityExposureTest do
  @moduledoc """
  REST and GraphQL responses carry only the user ID for `deployer` and
  `startedBy`, never the stored identity snapshot with roles, groups, and
  JWT claims.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @process_model_id "LinearStartEnd"
  @decision_definition_id "definitions_discount"
  @caller_claims %{
    "roles" => ["admin"],
    "groups" => ["operations"],
    "zeeky_boogie_doog" => true,
    "custom_secret_claim" => "must-not-leak"
  }
  @identity_snapshot_keys ["claims", "roles", "groups"]

  @process_versions_query """
  query ProcessVersions {
    processVersions { results { id deployer } }
  }
  """

  @decision_versions_query """
  query DecisionVersions {
    decisionVersions { results { id deployer } }
  }
  """

  @process_instances_by_starter_query """
  query ProcessInstancesByStarter($startedBy: String!) {
    processInstances(filter: {startedBy: {eq: $startedBy}}) { results { id startedBy } }
  }
  """

  describe "REST" do
    test "process show and version list return the deployer ID only" do
      {201, _} = http_deploy("linear_start_end.bpmn", @caller_claims)

      {200, process} = http_show_process(@process_model_id, claims: @caller_claims)
      assert process["deployer"] == "test-user"
      refute_identity_snapshot(process)

      {200, versions} = http_list_versions(@process_model_id, claims: @caller_claims)
      assert [%{"deployer" => "test-user"}] = versions
      refute_identity_snapshot(versions)
    end

    test "decision show and version list return the deployer ID only" do
      {201, _} = http_deploy_dmn("simple_unique.dmn", @caller_claims)

      {200, decision} = http_get("/decisions/#{@decision_definition_id}", @caller_claims)
      assert decision["deployer"] == "test-user"
      refute_identity_snapshot(decision)

      {200, versions} = http_get("/decisions/#{@decision_definition_id}/versions", @caller_claims)
      assert [%{"deployer" => "test-user"}] = versions
      refute_identity_snapshot(versions)
    end

    test "a version deployed without a recorded user ID has a null deployer" do
      xml = File.read!(Path.join(fixtures_dir(), "linear_start_end.bpmn"))

      {:ok, _} =
        BfwEngine.Api.deploy_bpmn(
          [%{filename: "linear_start_end.bpmn", xml: xml}],
          %{type: "anonymous"},
          skip_claims: true
        )

      {200, process} = http_show_process(@process_model_id)
      assert Map.has_key?(process, "deployer")
      assert process["deployer"] == nil
    end
  end

  describe "GraphQL" do
    test "process and decision versions expose the deployer ID only" do
      {201, _} = http_deploy("linear_start_end.bpmn", @caller_claims)
      {201, _} = http_deploy_dmn("simple_unique.dmn", @caller_claims)

      {200, process_body} = http_graphql(@process_versions_query, %{}, @caller_claims)
      refute Map.has_key?(process_body, "errors")
      assert [%{"deployer" => "test-user"}] = process_body["data"]["processVersions"]["results"]
      refute_identity_snapshot(process_body)

      {200, decision_body} = http_graphql(@decision_versions_query, %{}, @caller_claims)
      refute Map.has_key?(decision_body, "errors")
      assert [%{"deployer" => "test-user"}] = decision_body["data"]["decisionVersions"]["results"]
      refute_identity_snapshot(decision_body)
    end

    test "process instances filter by starter ID and expose the ID only" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @process_model_id)

      wait_for_process_instance(process_instance_id)

      {200, body} =
        http_graphql(@process_instances_by_starter_query, %{"startedBy" => "test-user"}, @caller_claims)

      refute Map.has_key?(body, "errors")

      assert [%{"id" => ^process_instance_id, "startedBy" => "test-user"}] =
               body["data"]["processInstances"]["results"]

      refute_identity_snapshot(body)

      {200, other_body} =
        http_graphql(@process_instances_by_starter_query, %{"startedBy" => "someone-else"}, @caller_claims)

      assert other_body["data"]["processInstances"]["results"] == []
    end
  end

  defp http_get(path, claims) do
    Plug.Test.conn(:get, path)
    |> Plug.Conn.put_req_header("authorization", "Bearer #{sign_jwt(claims)}")
    |> route()
    |> decode_response()
  end

  defp fixtures_dir, do: Path.expand("../../fixtures/bpmns", __DIR__)

  defp refute_identity_snapshot(body) do
    encoded = Jason.encode!(body)

    for key <- @identity_snapshot_keys do
      refute encoded =~ ~s("#{key}"), "response must not contain the #{key} key: #{encoded}"
    end

    refute encoded =~ "must-not-leak"
  end
end
