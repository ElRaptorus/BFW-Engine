defmodule EvilEngine.Load.ResumePressureTest do
  @moduledoc """
  Resume-under-GraphQL-pressure load test.

  Verifies that `ResumeRunner.resume_all/0` completes successfully while
  concurrent GraphQL queries are hammering the read pool. This is the
  startup scenario: the engine restarts with many PIs to resume, and
  Studio users immediately start querying.
  """

  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Execution
  alias EvilEngine.Execution.ResumeRunner
  alias EvilEngine.Test.LoadHelpers

  @user_task_fni %{
    flow_node_id: "UserTask_1",
    flow_node_type: :user_task,
    state: :waiting,
    input_token: %{"load" => "test"},
    type_properties: %{}
  }

  @graphql_process_instances_query """
  query {
    processInstances(limit: 50) {
      results { id state }
      count
    }
  }
  """

  @graphql_flow_node_instances_query """
  query {
    flowNodeInstances(limit: 50) {
      results { id flowNodeType state }
      count
    }
  }
  """

  setup do
    version_id = gen_version_id()
    deploy_fixture("user_task_simple.bpmn", version_id)
    {:ok, version_id: version_id}
  end

  # -------------------------------------------------------------------
  # RP1: Resume 1,000 PIs + 50 concurrent GraphQL readers
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "RP1: resume 1,000 PIs with concurrent GraphQL reads", context do
    _seeded = LoadHelpers.seed_process_instances(context.version_id, 1_000, [@user_task_fni])

    graphql_error_count = :atomics.new(1, signed: false)
    resume_done = :atomics.new(1, signed: false)

    graphql_tasks =
      for _ <- 1..50 do
        Task.async(fn ->
          poll_graphql_until_done(resume_done, graphql_error_count)
        end)
      end

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure("rp1_resume_1000_with_graphql", fn ->
        result = ResumeRunner.resume_all()
        :atomics.put(resume_done, 1, 1)
        result
      end)

    Task.await_many(graphql_tasks, 30_000)

    assert count == 1_000
    assert :atomics.get(graphql_error_count, 1) == 0
    assert elapsed_ms < 10_000

    Process.sleep(500)
    registered = LoadHelpers.count_registered_process_instances()
    assert registered == 1_000

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # RP2: Resume 5,000 PIs + heavy GraphQL read load
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 300_000
  test "RP2: resume 5,000 PIs with heavy concurrent GraphQL reads", context do
    _seeded = LoadHelpers.seed_process_instances(context.version_id, 5_000, [@user_task_fni])

    graphql_error_count = :atomics.new(1, signed: false)
    resume_done = :atomics.new(1, signed: false)

    graphql_tasks =
      for _ <- 1..100 do
        Task.async(fn ->
          poll_graphql_until_done(resume_done, graphql_error_count)
        end)
      end

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure("rp2_resume_5000_with_heavy_graphql", fn ->
        result = ResumeRunner.resume_all()
        :atomics.put(resume_done, 1, 1)
        result
      end)

    Task.await_many(graphql_tasks, 60_000)

    assert count == 5_000
    assert :atomics.get(graphql_error_count, 1) == 0
    assert elapsed_ms < 30_000

    LoadHelpers.terminate_all_process_instances()
  end

  defp poll_graphql_until_done(resume_done, error_counter) do
    if :atomics.get(resume_done, 1) == 1 do
      :ok
    else
      query =
        Enum.random([
          @graphql_process_instances_query,
          @graphql_flow_node_instances_query
        ])

      {status, body} = http_graphql(query)

      if status != 200 or (body["errors"] != nil and body["errors"] != []) do
        :atomics.add(error_counter, 1, 1)
      end

      Process.sleep(Enum.random(20..100))
      poll_graphql_until_done(resume_done, error_counter)
    end
  end
end
