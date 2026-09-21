defmodule BfwEngine.Integration.Graphql.GraphqlFilterOperatorsTest do
  @moduledoc """
  GraphQL integration tests for filter operators beyond `eq` and `ilike`.

  Covers notEq, in, DateTime comparisons, isNil, composite and/or/not,
  boolean filters, and relationship filters on processInstances and processes.
  """
  use BfwEngine.ExecutionCase, async: false

  @moduletag :integration

  @admin_claims %{"sub" => "admin", "zeeky_boogie_doog" => true}

  @process_model_id "LinearStartEnd"
  @user_task_process_model_id "UserTaskSimple"

  setup do
    past_datetime =
      DateTime.utc_now()
      |> DateTime.add(-3600)
      |> DateTime.to_iso8601()

    future_datetime =
      DateTime.utc_now()
      |> DateTime.add(3600)
      |> DateTime.to_iso8601()

    {201, _} = http_deploy("linear_start_end.bpmn")

    process_instance_ids =
      for _ <- 1..3 do
        {201, body} = http_start(@process_model_id, %{}, @admin_claims)
        process_instance_id = body["processInstanceId"]
        wait_for_process_instance(process_instance_id)
        process_instance_id
      end

    {:ok,
     past_datetime: past_datetime,
     future_datetime: future_datetime,
     process_instance_ids: process_instance_ids}
  end

  defp assert_contains_all_process_instances(results, process_instance_ids) do
    result_ids = MapSet.new(Enum.map(results, & &1["id"]))

    assert Enum.all?(process_instance_ids, &MapSet.member?(result_ids, &1))
  end

  describe "notEq filter" do
    test "excludes running process instances", %{process_instance_ids: process_instance_ids} do
      query = """
      query FilterProcessInstancesNotEq {
        processInstances(filter: {state: {notEq: "running"}}) {
          results {
            id
            state
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]

      assert length(results) >= 3
      assert Enum.all?(results, &(&1["state"] != "running"))
      assert_contains_all_process_instances(results, process_instance_ids)
    end
  end

  describe "in filter" do
    test "returns only process instances in the given states", %{
      process_instance_ids: process_instance_ids
    } do
      query = """
      query FilterProcessInstancesIn {
        processInstances(filter: {state: {in: ["finished", "fatal"]}}) {
          results {
            id
            state
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]

      assert length(results) >= 3
      assert Enum.all?(results, &(&1["state"] in ["finished", "fatal"]))
      assert_contains_all_process_instances(results, process_instance_ids)
    end
  end

  describe "DateTime filters" do
    test "greaterThan returns process instances started after the cutoff", %{
      past_datetime: past_datetime,
      process_instance_ids: process_instance_ids
    } do
      query = """
      query FilterProcessInstancesGreaterThan {
        processInstances(filter: {startedAt: {greaterThan: "#{past_datetime}"}}) {
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
      assert_contains_all_process_instances(results, process_instance_ids)

      {:ok, cutoff, _} = DateTime.from_iso8601(past_datetime)

      assert Enum.all?(results, fn result ->
               {:ok, started_at, _} = DateTime.from_iso8601(result["startedAt"])
               DateTime.compare(started_at, cutoff) == :gt
             end)
    end

    test "lessThan returns process instances started before the cutoff", %{
      future_datetime: future_datetime,
      process_instance_ids: process_instance_ids
    } do
      query = """
      query FilterProcessInstancesLessThan {
        processInstances(filter: {startedAt: {lessThan: "#{future_datetime}"}}) {
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
      assert_contains_all_process_instances(results, process_instance_ids)

      {:ok, cutoff, _} = DateTime.from_iso8601(future_datetime)

      assert Enum.all?(results, fn result ->
               {:ok, started_at, _} = DateTime.from_iso8601(result["startedAt"])
               DateTime.compare(started_at, cutoff) == :lt
             end)
    end
  end

  describe "isNil filter" do
    test "isNil false returns only finished process instances with finishedAt set", %{
      process_instance_ids: process_instance_ids
    } do
      query = """
      query FilterProcessInstancesFinishedAtNotNil {
        processInstances(filter: {finishedAt: {isNil: false}}) {
          results {
            id
            state
            finishedAt
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]

      assert length(results) >= 3
      assert Enum.all?(results, &(&1["finishedAt"] != nil))
      assert_contains_all_process_instances(results, process_instance_ids)
    end

    test "isNil true returns only running process instances without finishedAt" do
      {201, _} = http_deploy("user_task_simple.bpmn")

      {201, body} =
        http_start(@user_task_process_model_id, %{}, @admin_claims)

      running_process_instance_id = body["processInstanceId"]
      Process.sleep(200)

      query = """
      query FilterProcessInstancesFinishedAtNil {
        processInstances(filter: {finishedAt: {isNil: true}}) {
          results {
            id
            state
            finishedAt
          }
        }
      }
      """

      {200, response_body} = http_graphql(query, %{}, @admin_claims)
      results = response_body["data"]["processInstances"]["results"]

      refute results == []

      running_result =
        Enum.find(results, &(&1["id"] == running_process_instance_id))

      assert running_result != nil
      assert running_result["state"] == "running"
      assert running_result["finishedAt"] == nil
      assert Enum.all?(results, &(&1["finishedAt"] == nil))
    end
  end

  describe "composite and filter" do
    test "requires all conditions to match", %{
      past_datetime: past_datetime,
      process_instance_ids: process_instance_ids
    } do
      query = """
      query FilterProcessInstancesAnd {
        processInstances(filter: {and: [{state: {eq: "finished"}}, {startedAt: {greaterThan: "#{past_datetime}"}}]}) {
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

      assert length(results) >= 3
      assert Enum.all?(results, &(&1["state"] == "finished"))
      assert_contains_all_process_instances(results, process_instance_ids)

      {:ok, cutoff, _} = DateTime.from_iso8601(past_datetime)

      assert Enum.all?(results, fn result ->
               {:ok, started_at, _} = DateTime.from_iso8601(result["startedAt"])
               DateTime.compare(started_at, cutoff) == :gt
             end)
    end
  end

  describe "composite or filter" do
    test "matches when any condition is met", %{process_instance_ids: process_instance_ids} do
      query = """
      query FilterProcessInstancesOr {
        processInstances(filter: {or: [{state: {eq: "finished"}}, {state: {eq: "fatal"}}]}) {
          results {
            id
            state
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]

      assert length(results) >= 3
      assert Enum.all?(results, &(&1["state"] in ["finished", "fatal"]))
      assert_contains_all_process_instances(results, process_instance_ids)
    end
  end

  describe "composite not filter" do
    test "excludes process instances matching the inner filter", %{
      process_instance_ids: process_instance_ids
    } do
      query = """
      query FilterProcessInstancesNot {
        processInstances(filter: {not: {state: {eq: "running"}}}) {
          results {
            id
            state
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]

      assert length(results) >= 3
      assert Enum.all?(results, &(&1["state"] != "running"))
      assert_contains_all_process_instances(results, process_instance_ids)
    end
  end

  describe "boolean eq filter" do
    test "returns only enabled processes" do
      {201, _} = http_deploy("user_task_simple.bpmn")
      {204, _} = http_disable(@process_model_id, @admin_claims)

      query = """
      query FilterProcessesEnabled {
        processes(filter: {enabled: {eq: true}}) {
          results {
            processModelId
            enabled
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processes"]["results"]

      refute results == []
      assert Enum.all?(results, &(&1["enabled"] == true))

      enabled_model_ids = Enum.map(results, & &1["processModelId"])
      assert @user_task_process_model_id in enabled_model_ids
      refute @process_model_id in enabled_model_ids
    end
  end

  describe "relationship filter" do
    test "returns only process instances with an end_event flow node instance", %{
      process_instance_ids: process_instance_ids
    } do
      query = """
      query FilterProcessInstancesByEndEvent {
        processInstances(filter: {flowNodeInstances: {flowNodeType: {eq: "end_event"}}}) {
          results {
            id
            state
          }
        }
      }
      """

      {200, body} = http_graphql(query, %{}, @admin_claims)
      results = body["data"]["processInstances"]["results"]

      assert length(results) >= 3
      assert Enum.all?(results, &(&1["state"] == "finished"))
      assert_contains_all_process_instances(results, process_instance_ids)
    end
  end
end
