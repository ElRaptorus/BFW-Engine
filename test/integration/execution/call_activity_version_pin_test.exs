defmodule BfwEngine.Integration.Execution.CallActivityVersionPinTest do
  @moduledoc """
  Persistence-backed Call Activity `bfw:calledProcessVersion` resolution.

  NoOp cannot prove `deployed_at` order. These tests use the real
  `CalledElementResolverImpl` against two child versions of the same process.
  """
  use BfwEngine.ExecutionCase, async: false

  @bpmn_fixtures_dir Path.expand("../../fixtures/bpmns", __DIR__)
  @child_fixture Path.join(@bpmn_fixtures_dir, "call_activity_child.bpmn")
  @parent_fixture Path.join(@bpmn_fixtures_dir, "call_activity_basic.bpmn")
  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @call_activity_model_query """
  query GetProcessVersionModel($id: ID!) {
    getProcessVersion(id: $id) {
      id
      processModel {
        flowNodes {
          id
          type
          ... on CallActivityNode {
            calledElement
            startEventId
            calledProcessVersion
          }
        }
      }
    }
  }
  """

  setup do
    original_resolver = Application.get_env(:core_execution, :called_element_resolver)

    Application.put_env(
      :core_execution,
      :called_element_resolver,
      BfwEngine.Persistence.CalledElementResolverImpl
    )

    on_exit(fn ->
      if original_resolver do
        Application.put_env(:core_execution, :called_element_resolver, original_resolver)
      else
        Application.delete_env(:core_execution, :called_element_resolver)
      end
    end)

    :ok
  end

  describe "pin vs latest at enter time" do
    test "unpinned Call Activity resolves the newest deployed_at child version" do
      deploy_child_versions()
      {201, _} = http_deploy_xml(File.read!(@parent_fixture))

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] = find_child_process_instance_ids(parent_process_instance_id)
      child = fetch_process_instance!(child_process_instance_id)
      assert child.process_version_id == version_id_for("ChildProcess", "2.0.0")
    end

    test "pinned Call Activity resolves the named bfw:version, not latest" do
      deploy_child_versions()
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "1.0.0"))

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] = find_child_process_instance_ids(parent_process_instance_id)
      child = fetch_process_instance!(child_process_instance_id)
      assert child.process_version_id == version_id_for("ChildProcess", "1.0.0")
    end
  end

  describe "missing pin and disabled catalog" do
    test "unknown pin fatals with called_process_version_not_found" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "9.9.9"))

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "fatal")

      call_activity_flow_node_instance =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_flow_node_instance.state == "fatal"

      assert call_activity_flow_node_instance.error_info["error_code"] ==
               "called_process_version_not_found"

      assert call_activity_flow_node_instance.error_info["message"] =~ "ChildProcess"
      assert call_activity_flow_node_instance.error_info["message"] =~ "9.9.9"
    end

    test "disabled catalog with pin fatals version_disabled" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "1.0.0"))
      {204, _} = http_disable("ChildProcess")

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "fatal")

      call_activity_flow_node_instance =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_flow_node_instance.error_info["error_code"] == "version_disabled"
    end

    test "disabled catalog without pin fatals process_not_found" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy_xml(File.read!(@parent_fixture))
      {204, _} = http_disable("ChildProcess")

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "fatal")

      call_activity_flow_node_instance =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_flow_node_instance.error_info["error_code"] == "process_not_found"
    end

    test "whitespace-only pin is treated as unpinned and resolves latest" do
      deploy_child_versions()
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "   "))

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] = find_child_process_instance_ids(parent_process_instance_id)
      child = fetch_process_instance!(child_process_instance_id)
      assert child.process_version_id == version_id_for("ChildProcess", "2.0.0")
    end

    test "soft-deleted pin fatals with called_process_version_not_found" do
      deploy_child_versions()
      {204, _} = http_delete_version("ChildProcess", "1.0.0")
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "1.0.0"))

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "fatal")

      call_activity_flow_node_instance =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_flow_node_instance.error_info["error_code"] ==
               "called_process_version_not_found"

      assert call_activity_flow_node_instance.error_info["message"] =~ "1.0.0"
    end
  end

  describe "literal pin latest is a version name, not a keyword" do
    test "pin latest fatals when no child version is named latest" do
      deploy_child_versions()
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "latest"))

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "fatal")

      call_activity_flow_node_instance =
        find_fni_by_flow_node_id(parent_process_instance_id, "CA_1")

      assert call_activity_flow_node_instance.error_info["error_code"] ==
               "called_process_version_not_found"

      assert call_activity_flow_node_instance.error_info["message"] =~ "latest"
    end

    test "pin latest succeeds when a child version is actually named latest" do
      child_xml = File.read!(@child_fixture)
      {201, _} = http_deploy_xml(child_xml)
      {201, _} = http_deploy_xml(bump_evil_version(child_xml, "1.0.0", "latest"))
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "latest"))

      {201, body} = http_start("CallActivityBasic")
      parent_process_instance_id = body["processInstanceId"]
      wait_for_process_instance(parent_process_instance_id, 15_000)
      assert_pi_state!(parent_process_instance_id, "finished")

      [child_process_instance_id] = find_child_process_instance_ids(parent_process_instance_id)
      child = fetch_process_instance!(child_process_instance_id)
      assert child.process_version_id == version_id_for("ChildProcess", "latest")
    end
  end

  describe "GraphQL CallActivityNode.calledProcessVersion" do
    test "exposes the pin string on CallActivityNode and null when unpinned" do
      {201, _} = http_deploy("call_activity_child.bpmn")
      {201, _} = http_deploy_xml(pin_call_activity(File.read!(@parent_fixture), "1.0.0"))

      parent_version_id = version_id_for("CallActivityBasic", "1.0.0")

      {200, pinned_body} =
        http_graphql(@call_activity_model_query, %{"id" => parent_version_id}, @admin_claims)

      refute Map.has_key?(pinned_body, "errors")

      pinned_call_activity =
        Enum.find(
          pinned_body["data"]["getProcessVersion"]["processModel"]["flowNodes"],
          fn flow_node -> flow_node["id"] == "CA_1" end
        )

      assert pinned_call_activity["calledElement"] == "ChildProcess"
      assert pinned_call_activity["calledProcessVersion"] == "1.0.0"

      {201, _} =
        http_deploy_xml(bump_evil_version(File.read!(@parent_fixture), "1.0.0", "1.0.1"))

      unpinned_version_id = version_id_for("CallActivityBasic", "1.0.1")

      {200, unpinned_body} =
        http_graphql(@call_activity_model_query, %{"id" => unpinned_version_id}, @admin_claims)

      refute Map.has_key?(unpinned_body, "errors")

      unpinned_call_activity =
        Enum.find(
          unpinned_body["data"]["getProcessVersion"]["processModel"]["flowNodes"],
          fn flow_node -> flow_node["id"] == "CA_1" end
        )

      assert unpinned_call_activity["calledProcessVersion"] == nil
    end
  end

  defp find_child_process_instance_ids(parent_process_instance_id) do
    list_child_process_instance_ids(parent_process_instance_id)
  end

  defp deploy_child_versions do
    child_xml = File.read!(@child_fixture)
    {201, _} = http_deploy_xml(child_xml)
    {201, _} = http_deploy_xml(bump_evil_version(child_xml, "1.0.0", "2.0.0"))
  end

  defp pin_call_activity(xml, version_string) do
    Regex.replace(~r{<bpmn:callActivity id="CA_1"([^>]*)/>}, xml, fn _, attributes ->
      """
      <bpmn:callActivity id="CA_1"#{attributes}>
        <bpmn:extensionElements>
          <bfw:calledProcessVersion>#{version_string}</bfw:calledProcessVersion>
        </bpmn:extensionElements>
      </bpmn:callActivity>
      """
    end)
  end

  defp bump_evil_version(xml, from_version, to_version) do
    String.replace(
      xml,
      "<bfw:version>#{from_version}</bfw:version>",
      "<bfw:version>#{to_version}</bfw:version>"
    )
  end

  defp version_id_for(process_model_id, version_string) do
    {200, version_entries} = http_list_versions(process_model_id)

    entry =
      Enum.find(version_entries, fn version_entry ->
        version_entry["version"] == version_string
      end)

    unless entry do
      flunk("version #{version_string} not found for #{process_model_id}")
    end

    entry["versionId"]
  end
end
