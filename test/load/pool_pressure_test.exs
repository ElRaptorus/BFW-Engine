defmodule EvilEngine.Load.PoolPressureTest do
  @moduledoc """
  Concurrent mixed-workload load tests that exercise execution writes
  and GraphQL reads simultaneously against the dual-pool architecture.

  These tests verify that the read/write pool separation prevents
  cross-workload starvation: heavy GraphQL queries must not starve
  execution writes, and burst execution activity must not block reads.

  ## Assertions

  - **Zero `DBConnection.ConnectionError`** under mixed load (tracked via
    the `[:db_connection, :connection_error]` telemetry event).
  - All PIs reach terminal state (`:finished`, not `:fatal`).
  - All GraphQL queries return HTTP 200 with no errors.
  - P99 `queue_time_ms` stays below 1,000ms.

  ## Threshold methodology

  Timing ceilings use ~5x baseline headroom for CI variability.
  """

  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.AutoFinisher
  alias EvilEngine.Test.CompletionCounter
  alias EvilEngine.Test.LoadHelpers

  @pi_concurrency 20
  @graphql_reader_count 50

  @fixtures %{
    linear: {"linear_start_end.bpmn", "LinearStartEnd"},
    user_task: {"user_task_simple.bpmn", "UserTaskSimple"},
    echo: {"service_task_echo.bpmn", "ServiceTaskEcho"}
  }

  @graphql_process_instances_query """
  query {
    processInstances(limit: 25) {
      results {
        id
        state
        processModelId
        startedAt
      }
      count
      hasNextPage
    }
  }
  """

  @graphql_flow_node_instances_query """
  query {
    flowNodeInstances(limit: 50) {
      results {
        id
        processInstanceId
        flowNodeType
        state
      }
      count
    }
  }
  """

  setup do
    facade = Loader.facade_for_plugin("evil:test_load")
    EvilEngine.Test.ExamplePlugin.on_load(facade)

    EngineEventBus.register_sink("test:auto_finisher", AutoFinisher, [])

    on_exit(fn ->
      LoadHelpers.terminate_all_process_instances()
    end)

    :ok
  end

  # -------------------------------------------------------------------
  # PP1: 500 linear PIs (concurrent) + 50 GraphQL readers
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "PP1: 500 concurrent PIs with concurrent GraphQL reads" do
    {fixture, key} = @fixtures.linear
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()
    queue_collector = LoadHelpers.start_queue_time_collector()
    connection_error_collector = LoadHelpers.start_connection_error_collector()

    on_exit(fn ->
      CompletionCounter.stop(counter)
      LoadHelpers.stop_queue_time_collector(queue_collector)
      LoadHelpers.stop_connection_error_collector(connection_error_collector)
    end)

    graphql_error_count = :atomics.new(1, signed: false)

    graphql_tasks =
      for _ <- 1..@graphql_reader_count do
        Task.async(fn ->
          for _ <- 1..20 do
            {status, body} = http_graphql(@graphql_process_instances_query)

            if status != 200 or (body["errors"] != nil and body["errors"] != []) do
              :atomics.add(graphql_error_count, 1, 1)
            end

            Process.sleep(Enum.random(10..50))
          end
        end)
      end

    {elapsed_ms, _} =
      LoadHelpers.measure("pp1_500_concurrent_with_graphql", fn ->
        1..500
        |> Task.async_stream(fn _ -> http_start(key) end, max_concurrency: @pi_concurrency)
        |> Enum.each(fn {:ok, {status, _body}} -> assert status == 201 end)

        {:ok, _} = CompletionCounter.await(counter, 500, 60_000)
      end)

    Task.await_many(graphql_tasks, 30_000)

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    max_queue_ms = LoadHelpers.queue_time_max(queue_collector)
    connection_errors = LoadHelpers.connection_error_count(connection_error_collector)

    IO.puts(
      "[BENCH] pp1 P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms, " <>
        "max: #{Float.round(max_queue_ms, 1)}ms, " <>
        "connection_errors: #{connection_errors}"
    )

    assert CompletionCounter.count(counter) >= 500
    assert :atomics.get(graphql_error_count, 1) == 0
    assert connection_errors == 0, "#{connection_errors} DBConnection.ConnectionError(s) detected"
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"
    assert elapsed_ms < 60_000
  end

  # -------------------------------------------------------------------
  # PP2: 1,000 mixed PIs (concurrent) + 100 GraphQL readers
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 300_000
  test "PP2: 1,000 mixed PIs with heavy concurrent GraphQL reads" do
    fixtures = [@fixtures.linear, @fixtures.echo]

    for {fixture, _key} <- fixtures do
      {201, _} = http_deploy(fixture)
    end

    counter = CompletionCounter.start()
    queue_collector = LoadHelpers.start_queue_time_collector()
    connection_error_collector = LoadHelpers.start_connection_error_collector()

    on_exit(fn ->
      CompletionCounter.stop(counter)
      LoadHelpers.stop_queue_time_collector(queue_collector)
      LoadHelpers.stop_connection_error_collector(connection_error_collector)
    end)

    graphql_error_count = :atomics.new(1, signed: false)

    graphql_tasks =
      for _ <- 1..100 do
        Task.async(fn ->
          for _ <- 1..30 do
            query =
              Enum.random([
                @graphql_process_instances_query,
                @graphql_flow_node_instances_query
              ])

            {status, body} = http_graphql(query)

            if status != 200 or (body["errors"] != nil and body["errors"] != []) do
              :atomics.add(graphql_error_count, 1, 1)
            end

            Process.sleep(Enum.random(5..30))
          end
        end)
      end

    keys = Enum.map(fixtures, fn {_fixture, key} -> key end)

    {elapsed_ms, _} =
      LoadHelpers.measure("pp2_1000_mixed_with_heavy_graphql", fn ->
        1..1_000
        |> Task.async_stream(
          fn index ->
            key = Enum.at(keys, rem(index - 1, length(keys)))
            http_start(key)
          end,
          max_concurrency: @pi_concurrency
        )
        |> Enum.each(fn {:ok, {status, _body}} -> assert status == 201 end)

        {:ok, _} = CompletionCounter.await(counter, 1_000, 180_000)
      end)

    Task.await_many(graphql_tasks, 60_000)

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    connection_errors = LoadHelpers.connection_error_count(connection_error_collector)

    IO.puts(
      "[BENCH] pp2 P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms, " <>
        "connection_errors: #{connection_errors}"
    )

    assert CompletionCounter.count(counter) >= 1_000
    assert :atomics.get(graphql_error_count, 1) == 0
    assert connection_errors == 0, "#{connection_errors} DBConnection.ConnectionError(s) detected"
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"
    assert elapsed_ms < 180_000
  end

  # -------------------------------------------------------------------
  # PP3: Burst execution + sustained GraphQL polling
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "PP3: burst 200 PIs while polling GraphQL continuously" do
    {fixture, key} = @fixtures.linear
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()
    queue_collector = LoadHelpers.start_queue_time_collector()
    connection_error_collector = LoadHelpers.start_connection_error_collector()

    on_exit(fn ->
      CompletionCounter.stop(counter)
      LoadHelpers.stop_queue_time_collector(queue_collector)
      LoadHelpers.stop_connection_error_collector(connection_error_collector)
    end)

    graphql_results = :atomics.new(2, signed: false)

    poller_task =
      Task.async(fn ->
        poll_until_done(graphql_results, counter, 200)
      end)

    {elapsed_ms, _} =
      LoadHelpers.measure("pp3_burst_200_with_polling", fn ->
        1..200
        |> Task.async_stream(fn _ -> http_start(key) end, max_concurrency: @pi_concurrency)
        |> Enum.each(fn {:ok, {status, _body}} -> assert status == 201 end)

        {:ok, _} = CompletionCounter.await(counter, 200, 60_000)
      end)

    Task.await(poller_task, 30_000)

    total_polls = :atomics.get(graphql_results, 1)
    failed_polls = :atomics.get(graphql_results, 2)
    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    connection_errors = LoadHelpers.connection_error_count(connection_error_collector)

    IO.puts(
      "[BENCH] pp3 polls: #{total_polls}, P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms, " <>
        "connection_errors: #{connection_errors}"
    )

    assert total_polls > 0
    assert failed_polls == 0
    assert connection_errors == 0, "#{connection_errors} DBConnection.ConnectionError(s) detected"
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"
    assert elapsed_ms < 60_000
  end

  defp poll_until_done(counters, completion_counter, target) do
    if CompletionCounter.count(completion_counter) >= target do
      :ok
    else
      :atomics.add(counters, 1, 1)
      {status, body} = http_graphql(@graphql_process_instances_query)

      if status != 200 or (body["errors"] != nil and body["errors"] != []) do
        :atomics.add(counters, 2, 1)
      end

      Process.sleep(50)
      poll_until_done(counters, completion_counter, target)
    end
  end
end
