defmodule BfwEngine.Integration.SoftDeleteSecurityTest do
  @moduledoc """
  Integration tests for soft-delete security hardening.

  Verifies:
  - Deleted records are invisible through REST and GraphQL
  - Version deletion is blocked when non-terminal PIs exist
  - Resume fails gracefully when a version is deleted (data anomaly)
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Persistence.Resources

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp soft_delete_version_directly(version_id) do
    {:ok, version} = Ash.get(Resources.ProcessVersion, version_id, authorize?: false)

    version
    |> Ash.Changeset.for_update(:soft_delete, %{
      deleted: true,
      deleted_at: DateTime.utc_now(),
      deleted_by: %{"id" => "test-admin", "name" => "Direct DB manipulation"}
    })
    |> Ash.update!(authorize?: false)
  end

  defp soft_delete_process_instance_directly(process_instance_id) do
    {:ok, process_instance} =
      Ash.get(Resources.ProcessInstance, process_instance_id, authorize?: false)

    process_instance
    |> Ash.Changeset.for_update(:soft_delete, %{
      deleted: true,
      deleted_at: DateTime.utc_now(),
      deleted_by: %{"id" => "test-admin", "name" => "Direct DB manipulation"}
    })
    |> Ash.update!(authorize?: false)
  end

  defp extract_version_id(process_model_id) do
    {200, versions} = http_list_versions(process_model_id)
    List.first(versions)["versionId"]
  end

  # ---------------------------------------------------------------------------
  # Deleted records invisible
  # ---------------------------------------------------------------------------

  describe "deleted records are invisible through REST" do
    test "soft-deleted version is excluded from GET /processes/:model_id/versions" do
      {201, _deploy_body} = http_deploy("user_task_simple.bpmn")
      process_model_id = "UserTaskSimple"
      version_id = extract_version_id(process_model_id)

      {200, versions_before} = http_list_versions(process_model_id)
      assert length(versions_before) >= 1

      soft_delete_version_directly(version_id)

      {200, versions_after} = http_list_versions(process_model_id)
      version_ids = Enum.map(versions_after, & &1["versionId"])
      refute version_id in version_ids
    end

    test "soft-deleted version causes process to disappear from GET /processes" do
      {201, _deploy_body} = http_deploy("linear_start_end.bpmn")
      process_model_id = "LinearStartEnd"

      {200, processes_before} = http_list_processes()
      keys_before = Enum.map(processes_before, & &1["id"])
      assert process_model_id in keys_before

      {200, versions} = http_list_versions(process_model_id)

      Enum.each(versions, fn version_entry ->
        soft_delete_version_directly(version_entry["versionId"])
      end)

      {200, processes_after} = http_list_processes()
      keys_after = Enum.map(processes_after, & &1["id"])
      refute process_model_id in keys_after
    end

    test "soft-deleted PI is invisible via GET (GraphQL)" do
      process_instance_id = http_deploy_and_start("linear_three_node.bpmn", "LinearThreeNode")

      wait_for_process_instance(process_instance_id)

      query = """
      { getProcessInstance(id: "#{process_instance_id}") { id state } }
      """

      {200, result_before} = http_graphql(query)
      assert result_before["data"]["getProcessInstance"] != nil

      soft_delete_process_instance_directly(process_instance_id)

      {200, result_after} = http_graphql(query)
      assert result_after["data"]["getProcessInstance"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Version delete blocked when PIs active
  # ---------------------------------------------------------------------------

  describe "version deletion blocked when non-terminal PIs exist" do
    test "DELETE /processes/:model_id/versions/:version returns 409 when running PI exists" do
      {201, _deploy_body} = http_deploy("user_task_simple.bpmn")
      process_model_id = "UserTaskSimple"

      {201, start_body} = http_start(process_model_id)
      process_instance_id = start_body["processInstanceId"]
      poll_pi_alive(process_instance_id)

      poll_fni_state(process_instance_id, "user_task", "waiting")

      {200, versions} = http_list_versions(process_model_id)
      version_string = List.first(versions)["version"]

      {409, error_body} = http_delete_version(process_model_id, version_string)
      assert error_body["error"] == "active_instances_exist"
    end

    test "DELETE /processes/:model_id (undeploy) returns 409 when running PI exists" do
      {201, _deploy_body} = http_deploy("user_task_simple.bpmn")
      process_model_id = "UserTaskSimple"

      {201, start_body} = http_start(process_model_id)
      process_instance_id = start_body["processInstanceId"]
      poll_pi_alive(process_instance_id)

      poll_fni_state(process_instance_id, "user_task", "waiting")

      {409, error_body} = http_undeploy_process(process_model_id)
      assert error_body["error"] == "active_instances_exist"
    end

    test "DELETE /processes/:model_id/versions/:version succeeds after PI finishes" do
      {201, _deploy_body} = http_deploy("linear_three_node.bpmn")
      process_model_id = "LinearThreeNode"

      {201, start_body} = http_start(process_model_id)
      process_instance_id = start_body["processInstanceId"]

      wait_for_process_instance(process_instance_id)

      {200, versions} = http_list_versions(process_model_id)
      version_string = List.first(versions)["version"]

      {204, _} = http_delete_version(process_model_id, version_string)
    end
  end

  # ---------------------------------------------------------------------------
  # Resume fails gracefully on data anomaly
  # ---------------------------------------------------------------------------

  describe "resume with deleted version (data anomaly)" do
    test "ResumeRunner logs error but does not crash when version is deleted" do
      {201, _deploy_body} = http_deploy("user_task_simple.bpmn")
      process_model_id = "UserTaskSimple"
      version_id = extract_version_id(process_model_id)

      {201, start_body} = http_start(process_model_id)
      process_instance_id = start_body["processInstanceId"]
      poll_pi_alive(process_instance_id)

      poll_fni_state(process_instance_id, "user_task", "waiting")

      {:ok, pid} = BfwEngine.Execution.lookup_process_instance(process_instance_id)
      DynamicSupervisor.terminate_child(BfwEngine.Execution.Supervisor, pid)

      soft_delete_version_directly(version_id)

      BfwEngine.BPMN.ModelCache.reset_state()

      assert {:ok, _count} = BfwEngine.Execution.ResumeRunner.resume_all()

      assert {:error, :not_found} =
               BfwEngine.Execution.lookup_process_instance(process_instance_id)
    end
  end
end
