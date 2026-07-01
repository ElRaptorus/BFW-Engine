defmodule EvilEngine.Integration.Graphql.GraphqlCalculationsTest do
  @moduledoc """
  GraphQL integration tests for Ash calculation fields on ProcessInstance.

  Covers `finalTokens` (end-event output tokens for finished PIs) and
  `idText` (UUID text cast, filterable via ilike).
  """
  use EvilEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @linear_process_model_id "LinearStartEnd"
  @user_task_process_model_id "UserTaskSimple"

  @get_process_instance_with_final_tokens_query """
  query GetProcessInstance($id: ID!) {
    getProcessInstance(id: $id) {
      id
      state
      finalTokens
    }
  }
  """

  defp normalize_final_token_entry(entry) when is_binary(entry), do: Jason.decode!(entry)
  defp normalize_final_token_entry(entry) when is_map(entry), do: entry

  defp assert_final_token_has_required_keys(entry) do
    normalized = normalize_final_token_entry(entry)
    assert Map.has_key?(normalized, "endEventId")
    assert Map.has_key?(normalized, "payload")
  end

  describe "finalTokens calculation" do
    test "finished PI returns end-event output tokens" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @linear_process_model_id)

      wait_for_process_instance(process_instance_id)

      {200, body} =
        http_graphql(
          @get_process_instance_with_final_tokens_query,
          %{"id" => process_instance_id},
          @admin_claims
        )

      refute Map.has_key?(body, "errors")

      process_instance = body["data"]["getProcessInstance"]
      assert process_instance["id"] == process_instance_id
      assert process_instance["state"] == "finished"
      assert is_list(process_instance["finalTokens"])
      [_ | _] = process_instance["finalTokens"]

      Enum.each(process_instance["finalTokens"], &assert_final_token_has_required_keys/1)
    end

    test "running PI returns null for finalTokens" do
      process_instance_id =
        http_deploy_and_start("user_task_simple.bpmn", @user_task_process_model_id)

      poll_fni_state(process_instance_id, "user_task", "waiting")

      {200, body} =
        http_graphql(
          @get_process_instance_with_final_tokens_query,
          %{"id" => process_instance_id},
          @admin_claims
        )

      refute Map.has_key?(body, "errors")

      process_instance = body["data"]["getProcessInstance"]
      assert process_instance["id"] == process_instance_id
      assert process_instance["state"] in ["running", "waiting"]
      assert process_instance["finalTokens"] == nil
    end
  end

  describe "idText filter" do
    test "ilike on UUID substring matches the correct process instance" do
      process_instance_id =
        http_deploy_and_start("linear_start_end.bpmn", @linear_process_model_id)

      wait_for_process_instance(process_instance_id)

      substring = String.slice(process_instance_id, 0, 8)

      query = """
      query FilterProcessInstancesByIdText {
        processInstances(filter: {idText: {ilike: "%#{substring}%"}}) {
          results {
            id
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)

      refute Map.has_key?(body, "errors")

      results = body["data"]["processInstances"]["results"]
      result_ids = Enum.map(results, & &1["id"])
      assert process_instance_id in result_ids
    end

    test "ilike with non-matching substring returns empty results" do
      query = """
      query FilterProcessInstancesByNonMatchingIdText {
        processInstances(filter: {idText: {ilike: "%zzzzzzzz-nomatch%"}}) {
          results {
            id
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)

      refute Map.has_key?(body, "errors")

      results = body["data"]["processInstances"]["results"]
      assert results == []
    end
  end
end
