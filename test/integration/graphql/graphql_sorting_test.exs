defmodule BfwEngine.Integration.Graphql.GraphqlSortingTest do
  @moduledoc """
  GraphQL integration tests for list sorting beyond the default
  `STARTED_AT DESC` ordering on process instances.

  Covers ascending and multi-field sorts on process instances, name
  sorting on processes, chronological flow node instance ordering, and
  created-at ordering on decision definitions.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @linear_process_model_id "LinearStartEnd"
  @linear_process_name "Linear Start End"
  @user_task_process_model_id "UserTaskSimple"
  @user_task_process_name "User Task Simple"

  @discount_decision_definition_id "definitions_discount"
  @sum_decision_definition_id "definitions_sum"

  defp start_linear_process_instances(count) do
    {201, _} = http_deploy("linear_start_end.bpmn")

    for _ <- 1..count do
      {201, body} = http_start(@linear_process_model_id, %{}, @admin_claims)
      wait_for_process_instance(body["processInstanceId"])
    end
  end

  defp parse_started_at_values(results) do
    Enum.map(results, fn result ->
      {:ok, datetime, _offset} = DateTime.from_iso8601(result["startedAt"])
      datetime
    end)
  end

  defp parse_created_at_values(results) do
    Enum.map(results, fn result ->
      {:ok, datetime, _offset} = DateTime.from_iso8601(result["createdAt"])
      datetime
    end)
  end

  defp assert_names_in_ascending_order(names) do
    Enum.each(Enum.zip(names, tl(names)), fn {left, right} ->
      assert left <= right
    end)
  end

  defp assert_sorted_by_state_asc_started_at_desc(results) do
    expected_order =
      Enum.sort(results, fn left, right ->
        cond do
          left["state"] < right["state"] ->
            true

          left["state"] > right["state"] ->
            false

          true ->
            {:ok, left_started_at, _} = DateTime.from_iso8601(left["startedAt"])
            {:ok, right_started_at, _} = DateTime.from_iso8601(right["startedAt"])

            DateTime.compare(left_started_at, right_started_at) in [:gt, :eq]
        end
      end)

    assert results == expected_order
  end

  describe "processInstances sorting" do
    test "returns processInstances sorted by started_at ascending" do
      start_linear_process_instances(3)

      query = """
      query SortedProcessInstancesAsc {
        processInstances(limit: 10, sort: [{field: STARTED_AT, order: ASC}]) {
          results {
            id
            startedAt
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]
      assert length(results) >= 3

      parsed_started_at = parse_started_at_values(results)
      assert parsed_started_at == Enum.sort(parsed_started_at, DateTime)
    end

    test "returns processInstances sorted by state asc then started_at desc" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {201, user_task_body} = http_start(@user_task_process_model_id, %{}, @admin_claims)
      user_task_process_instance_id = user_task_body["processInstanceId"]

      {:ok, _} = await_process_instance_state(user_task_process_instance_id, "running")

      {201, _} = http_deploy("linear_start_end.bpmn")
      {201, linear_body} = http_start(@linear_process_model_id, %{}, @admin_claims)
      linear_process_instance_id = linear_body["processInstanceId"]
      wait_for_process_instance(linear_process_instance_id)

      query = """
      query MultiFieldSortedProcessInstances {
        processInstances(
          limit: 10
          sort: [{field: STATE, order: ASC}, {field: STARTED_AT, order: DESC}]
        ) {
          results {
            id
            state
            startedAt
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]
      assert length(results) >= 2

      our_results =
        Enum.filter(results, &(&1["id"] in [user_task_process_instance_id, linear_process_instance_id]))

      assert length(our_results) == 2
      assert_sorted_by_state_asc_started_at_desc(our_results)

      [first, second] = our_results
      assert first["state"] == "finished"
      assert second["state"] == "running"
    end
  end

  describe "processes sorting" do
    test "returns processes sorted by name ascending" do
      {201, _} = http_deploy("linear_start_end.bpmn")
      {201, _} = http_deploy("user_task_simple.bpmn")

      query = """
      query SortedProcessesByName {
        processes(sort: [{field: NAME, order: ASC}]) {
          results {
            id
            name
            processModelId
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processes"]["results"]

      our_results =
        Enum.filter(results, &(&1["processModelId"] in [@linear_process_model_id, @user_task_process_model_id]))

      assert length(our_results) == 2

      names = Enum.map(our_results, & &1["name"])
      assert names == [@linear_process_name, @user_task_process_name]
      assert_names_in_ascending_order(names)
    end
  end

  describe "flowNodeInstances sorting" do
    test "returns flowNodeInstances sorted by started_at ascending" do
      {201, _} = http_deploy("linear_start_end.bpmn")
      {201, body} = http_start(@linear_process_model_id, %{}, @admin_claims)
      process_instance_id = body["processInstanceId"]
      wait_for_process_instance(process_instance_id)

      query = """
      query SortedFlowNodeInstances {
        flowNodeInstances(
          filter: {processInstanceId: {eq: "#{process_instance_id}"}}
          sort: [{field: STARTED_AT, order: ASC}]
        ) {
          results {
            id
            flowNodeId
            startedAt
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["flowNodeInstances"]["results"]
      assert length(results) == 2

      parsed_started_at = parse_started_at_values(results)
      assert parsed_started_at == Enum.sort(parsed_started_at, DateTime)

      flow_node_ids = Enum.map(results, & &1["flowNodeId"])
      assert flow_node_ids == ["Start_1", "End_1"]
    end
  end

  describe "decisionDefinitions sorting" do
    test "returns decisionDefinitions sorted by created_at descending" do
      {201, _} = http_deploy_dmn("simple_unique.dmn")
      {201, _} = http_deploy_dmn("literal_expression.dmn")

      query = """
      query SortedDecisionDefinitions {
        decisionDefinitions(sort: [{field: CREATED_AT, order: DESC}]) {
          results {
            id
            decisionDefinitionId
            name
            createdAt
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["decisionDefinitions"]["results"]
      assert length(results) >= 2

      our_results =
        Enum.filter(results, &(&1["decisionDefinitionId"] in [
          @discount_decision_definition_id,
          @sum_decision_definition_id
        ]))

      assert length(our_results) == 2

      parsed_created_at = parse_created_at_values(our_results)
      assert parsed_created_at == Enum.sort(parsed_created_at, {:desc, DateTime})

      [newest, oldest] = our_results
      assert newest["decisionDefinitionId"] == @sum_decision_definition_id
      assert oldest["decisionDefinitionId"] == @discount_decision_definition_id
    end
  end
end
