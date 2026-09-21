defmodule BfwEngine.Load.ExecutionLoadTest do
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
  (M-series Mac, Postgres in Docker). Baselines measured 2026-05-03
  except E8/E9 (2026-09-02, Linux, Postgres in Docker). E5's ceiling is
  60 s (not 5×) because GitHub `ubuntu-latest` (2 vCPU) plus the
  AutoFinisher HTTP round-trip routinely exceeds 20 s for the last
  stragglers. E6's ceiling is 180 s (not 5×) for the same runner: a
  mixed 5,000-PI start loop already takes ~100 s there, and a single
  missed AutoFinisher/echo finish used to hang at 4,999/5,000 (P88).
  E8's 5× ceiling would exceed the 600 s test timeout, so
  the assert is capped at 600 s. E10–E12 (single-shape 10,000) use the
  same 600 s cap until a first measured baseline exists.

  | Test | Baseline  | Ceiling |
  |------|-----------|---------|
  | E1   |    290 ms |  1500 ms |
  | E2   | 10,840 ms |   54 s  |
  | E3   |  3,628 ms |   18 s  |
  | E4   |  4,267 ms |   21 s  |
  | E5   |  3,896 ms |   60 s  |
  | E6   | 23,308 ms |  180 s  |
  | E7   | 32,657 ms |  163 s  |
  | E8   | 206,507 ms |  600 s |
  | E10  | no baseline yet (first 10k parallel-only) | 600 s |
  | E11  | no baseline yet (first 10k MI-only) | 600 s |
  | E12  | no baseline yet (first 10k call-activity-only) | 600 s |
  | E9 1 KiB | 11,843 ms | 60 s |
  | E9 16 KiB | 19,652 ms | 99 s |
  | E9 64 KiB | 30,713 ms | 154 s |
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Plugins.Loader
  alias BfwEngine.Test.AutoFinisher
  alias BfwEngine.Test.CompletionCounter
  alias BfwEngine.Test.DbAssertions
  alias BfwEngine.Test.ExamplePlugin
  alias BfwEngine.Test.LoadHelpers

  @payload_cap_bytes 65_536
  @mi_start_body %{"payload" => %{"items" => [1, 2, 3]}}
  @shape_10000_count 10_000
  @shape_10000_await_ms 480_000
  @shape_10000_ceiling_ms 600_000
  @e9_elapsed_ceilings_ms %{
    "1kib" => 60_000,
    "16kib" => 99_000,
    "64kib" => 154_000
  }

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

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_100_linear",
        fn ->
          for _ <- 1..100 do
            {201, _} = http_start(key)
          end

          {:ok, _} = CompletionCounter.await(counter, 100, 10_000)
        end,
        id: "exec_100_linear",
        kind: :execution,
        process_count: 100
      )

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

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_1000_chained",
        fn ->
          for _ <- 1..1_000 do
            {201, _} = http_start(key)
          end

          {:ok, _} = CompletionCounter.await(counter, 1_000, 30_000)
        end,
        id: "exec_1000_chained",
        kind: :execution,
        process_count: 1_000
      )

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

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_1000_echo",
        fn ->
          for _ <- 1..1_000 do
            {201, _} = http_start(key)
          end

          {:ok, _} = CompletionCounter.await(counter, 1_000, 30_000)
        end,
        id: "exec_1000_echo",
        kind: :execution,
        process_count: 1_000
      )

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

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_1000_async",
        fn ->
          for _ <- 1..1_000 do
            {201, _} = http_start(key)
          end

          {:ok, _} = CompletionCounter.await(counter, 1_000, 60_000)
        end,
        id: "exec_1000_async",
        kind: :execution,
        process_count: 1_000
      )

    assert CompletionCounter.count(counter) >= 1_000
    assert elapsed_ms < 21_000

    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E5: 1,000 user tasks (auto-finished by EventSink)
  # -------------------------------------------------------------------
  # Await/elapsed are wider than the ~5× local ceiling: each PI is an
  # HTTP start plus a fire-and-forget AutoFinisher HTTP finish. GitHub
  # ubuntu-latest (2 vCPU) routinely needs >30s for the last stragglers.

  @tag :load
  @tag timeout: 180_000
  test "E5: 1,000 user task PIs (auto-finished)", _ctx do
    {fixture, key} = @fixtures.user_task
    {201, _} = http_deploy(fixture)

    counter = CompletionCounter.start()

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_1000_user_task",
        fn ->
          for _ <- 1..1_000 do
            {201, _} = http_start(key)
          end

          {:ok, _} = CompletionCounter.await(counter, 1_000, 90_000)
        end,
        id: "exec_1000_user_task",
        kind: :execution,
        process_count: 1_000
      )

    assert CompletionCounter.count(counter) >= 1_000
    assert elapsed_ms < 60_000

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

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_5000_mixed",
        fn ->
          for i <- 1..5_000 do
            {_fixture, key} = Enum.at(fixtures, rem(i - 1, 5))
            {201, _} = http_start(key)
          end

          {:ok, _} = CompletionCounter.await(counter, 5_000, 180_000)
        end,
        id: "exec_5000_mixed",
        kind: :execution,
        process_count: 5_000,
        queue_time_collector: queue_collector
      )

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    IO.puts("[BENCH] exec_5000_mixed P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms")

    assert CompletionCounter.count(counter) >= 5_000
    assert elapsed_ms < 180_000
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

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_10000_linear",
        fn ->
          for _ <- 1..10_000 do
            {201, _} = http_start(key)
          end

          {:ok, _} = CompletionCounter.await(counter, 10_000, 300_000)
        end,
        id: "exec_10000_linear",
        kind: :execution,
        process_count: 10_000,
        queue_time_collector: queue_collector
      )

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    IO.puts("[BENCH] exec_10000_linear P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms")

    assert CompletionCounter.count(counter) >= 10_000
    assert elapsed_ms < 163_000
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"

    LoadHelpers.stop_queue_time_collector(queue_collector)
    CompletionCounter.stop(counter)
  end

  # -------------------------------------------------------------------
  # E8: 10,000 mixed linear / parallel / MI / call-activity
  # -------------------------------------------------------------------

  @tag :load
  @tag :e8
  @tag timeout: 600_000
  test "E8: 10,000 mixed linear/parallel/MI/call-activity PIs" do
    {201, _} = http_deploy("linear_start_end.bpmn")
    {201, _} = http_deploy("parallel_gateway_two_branches.bpmn")
    {201, _} = http_deploy("mi_parallel_script_task.bpmn")
    {201, _} = http_deploy("call_activity_child.bpmn")
    {201, _} = http_deploy("call_activity_basic.bpmn")

    starters = [
      {"LinearStartEnd", %{}},
      {"ParallelGatewayTwoBranches", %{}},
      {"mi-parallel-script-task", @mi_start_body},
      {"CallActivityBasic", %{}}
    ]

    counter = CompletionCounter.start(roots_only: true)
    queue_collector = LoadHelpers.start_queue_time_collector()
    latency_samples_table = :ets.new(:e8_start_latencies, [:public, :bag])

    {elapsed_ms, _} =
      LoadHelpers.measure(
        "exec_10000_mixed_standard",
        fn ->
          for index <- 1..10_000 do
            {process_model_id, body} = Enum.at(starters, rem(index - 1, 4))

            {start_us, {201, _}} =
              :timer.tc(fn -> http_start_with_sandbox_retry(process_model_id, body) end)

            :ets.insert(latency_samples_table, {:sample, start_us / 1000})
          end

          {:ok, _} = CompletionCounter.await(counter, 10_000, 480_000)
        end,
        id: "exec_10000_mixed_standard",
        kind: :execution,
        process_count: 10_000,
        latency_samples_table: latency_samples_table,
        queue_time_collector: queue_collector
      )

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    IO.puts("[BENCH] exec_10000_mixed_standard P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms")

    assert CompletionCounter.count(counter) >= 10_000
    assert elapsed_ms < 600_000
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"

    LoadHelpers.stop_queue_time_collector(queue_collector)
    CompletionCounter.stop(counter)
    :ets.delete(latency_samples_table)
  end

  # -------------------------------------------------------------------
  # E10–E12: 10,000 of each E8 shape, run alone
  # Linear 10,000 is E7. These isolate whether mixed 10,000 is a
  # weighted average of extra FNIs or one pathological shape.
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 600_000
  test "E10: 10,000 parallel-gateway PIs" do
    run_shape_10000("exec_10000_parallel_gateway",
      deploy: ["parallel_gateway_two_branches.bpmn"],
      start: {"ParallelGatewayTwoBranches", %{}}
    )
  end

  @tag :load
  @tag timeout: 600_000
  test "E11: 10,000 parallel multi-instance script-task PIs" do
    run_shape_10000("exec_10000_mi_parallel_script",
      deploy: ["mi_parallel_script_task.bpmn"],
      start: {"mi-parallel-script-task", @mi_start_body}
    )
  end

  @tag :load
  @tag timeout: 600_000
  test "E12: 10,000 call-activity PIs" do
    run_shape_10000("exec_10000_call_activity",
      deploy: ["call_activity_child.bpmn", "call_activity_basic.bpmn"],
      start: {"CallActivityBasic", %{}},
      roots_only: true
    )
  end

  # -------------------------------------------------------------------

  @tag :load
  @tag :e9
  @tag timeout: 600_000
  test "E9: 1,000 linear PIs at 1 KiB / 16 KiB / 64 KiB payloads" do
    {201, _} = http_deploy("linear_start_end.bpmn")

    for {label, byte_count} <- [{"1kib", 1_024}, {"16kib", 16_384}, {"64kib", 60_000}] do
      body = payload_of_bytes(byte_count)
      encoded_payload_bytes = :erlang.iolist_size(Jason.encode!(body["payload"]))
      assert encoded_payload_bytes <= @payload_cap_bytes

      workload_id = "exec_1000_linear_payload_#{label}"
      counter = CompletionCounter.start()

      {elapsed_ms, _} =
        LoadHelpers.measure(
          workload_id,
          fn ->
            for _ <- 1..1_000 do
              {status, _response} = http_start_with_sandbox_retry("LinearStartEnd", body)
              assert status == 201
            end

            {:ok, _} = CompletionCounter.await(counter, 1_000, 180_000)
          end,
          id: workload_id,
          kind: :execution,
          process_count: 1_000
        )

      assert CompletionCounter.count(counter) >= 1_000
      assert elapsed_ms < Map.fetch!(@e9_elapsed_ceilings_ms, label)

      CompletionCounter.stop(counter)
    end
  end

  defp run_shape_10000(workload_id, opts) do
    bpmn_files = Keyword.fetch!(opts, :deploy)
    {process_model_id, body} = Keyword.fetch!(opts, :start)
    count_roots_only = Keyword.get(opts, :roots_only, false)

    Enum.each(bpmn_files, fn bpmn_file ->
      {201, _} = http_deploy(bpmn_file)
    end)

    counter = CompletionCounter.start(roots_only: count_roots_only)
    queue_collector = LoadHelpers.start_queue_time_collector()

    {elapsed_ms, _} =
      LoadHelpers.measure(
        workload_id,
        fn ->
          for _ <- 1..@shape_10000_count do
            {201, _} = http_start_with_sandbox_retry(process_model_id, body)
          end

          {:ok, _} =
            CompletionCounter.await(counter, @shape_10000_count, @shape_10000_await_ms)
        end,
        id: workload_id,
        kind: :execution,
        process_count: @shape_10000_count,
        queue_time_collector: queue_collector
      )

    p99_queue_ms = LoadHelpers.queue_time_p99(queue_collector)
    IO.puts("[BENCH] #{workload_id} P99 queue_time: #{Float.round(p99_queue_ms, 1)}ms")

    assert CompletionCounter.count(counter) >= @shape_10000_count
    assert elapsed_ms < @shape_10000_ceiling_ms
    assert p99_queue_ms < 1_000, "P99 queue_time #{p99_queue_ms}ms exceeds 1000ms ceiling"

    LoadHelpers.stop_queue_time_collector(queue_collector)
    CompletionCounter.stop(counter)
  end

  defp payload_of_bytes(byte_count) do
    %{"payload" => %{"blob" => String.duplicate("a", byte_count)}}
  end

  defp http_start_with_sandbox_retry(process_model_id, body) do
    DbAssertions.with_sandbox_retry(fn ->
      http_start(process_model_id, body)
    end)
  end
end
