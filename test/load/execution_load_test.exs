defmodule EvilEngine.Load.ExecutionLoadTest do
  @moduledoc """
  Execution load tests that exercise the full API-driven lifecycle.

  Unlike the resume load tests (which seed the DB and measure
  `ResumeRunner.resume_all()`), these tests deploy processes via HTTP,
  start instances through the API, and let the engine execute them to
  completion — including auto-finishing user tasks via a custom EventSink.

  This means these tests have a significantly higher overhead, resulting in the
  higher runtimes, but they are also much closer to how Processes would actually
  be started in a real-life scenario.

  ## Threshold methodology

  Ceilings are set at ~5x the observed baseline on a local dev machine
  (M-series Mac, Postgres in Docker). Baselines measured 2026-05-03:

  | Test | Baseline  | Ceiling |
  |------|-----------|---------|
  | E1   |    290 ms |  1500 ms |
  | E2   | 10,840 ms |   54 s  |
  | E3   |  3,628 ms |   18 s  |
  | E4   |  4,267 ms |   21 s  |
  | E5   |  3,896 ms |   20 s  |
  | E6   | 23,308 ms |  117 s  |
  | E7   | 32,657 ms |  163 s  |
  """

  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Plugins.Loader
  alias EvilEngine.Test.AutoFinisher
  alias EvilEngine.Test.CompletionCounter
  alias EvilEngine.Test.ExamplePlugin
  alias EvilEngine.Test.LoadHelpers

  @fixtures %{
    linear: {"linear_start_end.bpmn", "LinearStartEnd"},
    chained: {"chained_tasks.bpmn", "ChainedTasks"},
    echo: {"service_task_echo.bpmn", "ServiceTaskEcho"},
    async: {"service_task_async.bpmn", "ServiceTaskAsync"},
    user_task: {"user_task_simple.bpmn", "UserTaskSimple"}
  }

  setup do
    facade = Loader.facade_for_plugin("evil:test_load")
    ExamplePlugin.on_load(facade)

    EngineEventBus.register_sink(
      "test:auto_finisher",
      AutoFinisher,
      []
    )

    on_exit(fn ->
      LoadHelpers.terminate_all_process_instances()
    end)

    :ok
  end

  # -------------------------------------------------------------------
  # E1: 100 linear start-end (baseline API overhead)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 30_000
  test "E1: 100 linear start-end PIs", _ctx do
    {fixture, key} = @fixtures.linear
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()

    {elapsed_ms, _} = LoadHelpers.measure("exec_100_linear", fn ->
      for _ <- 1..100 do
        {201, _} = http_start(key)
      end

      {:ok, _} = CompletionCounter.await(counter, 100, 10_000)
    end)

    assert CompletionCounter.count(counter) >= 100
    assert elapsed_ms < 1_500

    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E2: 1,000 chained tasks (multi-step throughput)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 60_000
  test "E2: 1,000 chained task PIs", _ctx do
    {fixture, key} = @fixtures.chained
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()

    {elapsed_ms, _} = LoadHelpers.measure("exec_1000_chained", fn ->
      for _ <- 1..1_000 do
        {201, _} = http_start(key)
      end

      {:ok, _} = CompletionCounter.await(counter, 1_000, 30_000)
    end)

    assert CompletionCounter.count(counter) >= 1_000
    assert elapsed_ms < 54_000

    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E3: 1,000 sync service tasks (plugin dispatch at scale)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 60_000
  test "E3: 1,000 sync service task PIs", _ctx do
    {fixture, key} = @fixtures.echo
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()

    {elapsed_ms, _} = LoadHelpers.measure("exec_1000_echo", fn ->
      for _ <- 1..1_000 do
        {201, _} = http_start(key)
      end

      {:ok, _} = CompletionCounter.await(counter, 1_000, 30_000)
    end)

    assert CompletionCounter.count(counter) >= 1_000
    assert elapsed_ms < 18_000

    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E4: 1,000 async service tasks (async lifecycle at scale)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 60_000
  test "E4: 1,000 async service task PIs", _ctx do
    {fixture, key} = @fixtures.async
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()

    {elapsed_ms, _} = LoadHelpers.measure("exec_1000_async", fn ->
      for _ <- 1..1_000 do
        {201, _} = http_start(key)
      end

      {:ok, _} = CompletionCounter.await(counter, 1_000, 60_000)
    end)

    assert CompletionCounter.count(counter) >= 1_000
    assert elapsed_ms < 21_000

    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E5: 1,000 user tasks (auto-finished by EventSink)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 60_000
  test "E5: 1,000 user task PIs (auto-finished)", _ctx do
    {fixture, key} = @fixtures.user_task
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()

    {elapsed_ms, _} = LoadHelpers.measure("exec_1000_user_task", fn ->
      for _ <- 1..1_000 do
        {201, _} = http_start(key)
      end

      {:ok, _} = CompletionCounter.await(counter, 1_000, 30_000)
    end)

    assert CompletionCounter.count(counter) >= 1_000
    assert elapsed_ms < 20_000

    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E6: 5,000 mixed workload (all 5 fixture types)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 300_000
  test "E6: 5,000 mixed PIs across 5 process types", _ctx do
    fixtures = [
      @fixtures.linear,
      @fixtures.chained,
      @fixtures.echo,
      @fixtures.async,
      @fixtures.user_task
    ]

    for {fixture, _key} <- fixtures do
      {201, _} = http_deploy(fixture)
    end

    counter = CompletionCounter.start()
    queue_collector = LoadHelpers.start_queue_time_collector()

    {elapsed_ms, _} = LoadHelpers.measure("exec_5000_mixed", fn ->
      for i <- 1..5_000 do
        {_fixture, key} = Enum.at(fixtures, rem(i - 1, 5))
        {201, _} = http_start(key)
      end

      {:ok, _} = CompletionCounter.await(counter, 5_000, 180_000)
    end)

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    IO.puts("[BENCH] exec_5000_mixed P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms")

    assert CompletionCounter.count(counter) >= 5_000
    assert elapsed_ms < 120_000
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"

    LoadHelpers.stop_queue_time_collector(queue_collector)
    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E7: 10,000 linear start-end (stress test)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 300_000
  test "E7: 10,000 linear start-end PIs", _ctx do
    {fixture, key} = @fixtures.linear
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()
    queue_collector = LoadHelpers.start_queue_time_collector()

    {elapsed_ms, _} = LoadHelpers.measure("exec_10000_linear", fn ->
      for _ <- 1..10_000 do
        {201, _} = http_start(key)
      end

      {:ok, _} = CompletionCounter.await(counter, 10_000, 300_000)
    end)

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    IO.puts("[BENCH] exec_10000_linear P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms")

    assert CompletionCounter.count(counter) >= 10_000
    assert elapsed_ms < 163_000
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"

    LoadHelpers.stop_queue_time_collector(queue_collector)
    CompletionCounter.stop(counter)
  end
end
