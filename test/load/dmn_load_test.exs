defmodule EvilEngine.Load.DmnLoadTest do
  @moduledoc """
  BRT + DMN load tests that exercise the full Start → BRT → End pipeline.

  Each test deploys a DMN model with N rules and a minimal BPMN process
  (Start Event → Business Rule Task → End Event), then starts many
  process instances concurrently and measures total completion time.

  ## Methodology

  Each scenario runs `@warmup_runs` iterations first (discarded), then
  `@measured_runs` sequential batches. The average of the measured runs
  is printed as the run baseline. Assert ceilings are ~5× the 2026-05-21
  M-series Mac averages (same multiplier as execution/resume load tests).
  The original 3× Mac ceilings fail on GitHub `ubuntu-latest` (2 vCPU):
  D7 averaged 16,583 ms against 14,937 ms.

  ## Baselines (2026-05-21, M-series Mac, Postgres in Docker)

  | Test  | Table size | PIs  | Baseline  | Ceiling   |
  |-------|-----------|------|-----------|-----------|
  | D1    | 10 rules  | 100  |    463 ms |  2,315 ms |
  | D2    | 50 rules  | 100  |    467 ms |  2,335 ms |
  | D3    | 100 rules | 100  |    473 ms |  2,365 ms |
  | D4    | 500 rules | 100  |    476 ms |  2,380 ms |
  | D5    | 10 rules  | 1000 |  4,919 ms | 24,595 ms |
  | D6    | 50 rules  | 1000 |  4,944 ms | 24,720 ms |
  | D7    | 100 rules | 1000 |  4,979 ms | 24,895 ms |
  | D8    | 500 rules | 1000 | 14,846 ms | 74,230 ms |
  """

  use EvilEngine.ExecutionCase, async: false

  alias EvilEngine.Test.CompletionCounter
  alias EvilEngine.Test.LoadHelpers

  @warmup_runs 2
  @measured_runs 5

  @fixtures %{
    r10: {"brt_load_10.bpmn", "BrtLoad10", "load_10_rules.dmn"},
    r50: {"brt_load_50.bpmn", "BrtLoad50", "load_50_rules.dmn"},
    r100: {"brt_load_100.bpmn", "BrtLoad100", "load_100_rules.dmn"},
    r500: {"brt_load_500.bpmn", "BrtLoad500", "load_500_rules.dmn"}
  }

  @payload %{"age" => 18, "status" => "standard"}

  setup do
    EvilEngine.DMN.ModelCache.reset_state()

    on_exit(fn ->
      LoadHelpers.terminate_all_process_instances()
    end)

    :ok
  end

  defp deploy_fixture(fixture_key) do
    {bpmn, _process_id, dmn} = Map.fetch!(@fixtures, fixture_key)
    {201, _} = http_deploy_dmn(dmn)
    {201, _} = http_deploy(bpmn)
    :ok
  end

  defp run_batch(process_id, count, timeout) do
    counter = CompletionCounter.start()

    try do
      {elapsed_ms, _} =
        LoadHelpers.measure(
          "batch_#{process_id}_#{count}",
          fn ->
            for _ <- 1..count do
              {201, _} = http_start(process_id, @payload)
            end

            case CompletionCounter.await(counter, count, timeout) do
              {:ok, _completed} -> :ok
              {:timeout, completed} -> {:partial, completed}
            end
          end,
          id: "batch_#{process_id}_#{count}",
          kind: :dmn,
          process_count: count
        )

      CompletionCounter.stop(counter)
      elapsed_ms
    after
      # Each measured run must start from an empty Execution Supervisor.
      # Leaving finished PIs registered makes later batches monotonically slower
      # (D5 climbed 9 s → 35 s across seven 1 000-PI batches on Linux).
      LoadHelpers.terminate_all_process_instances()
    end
  end

  defp run_measured_scenario(fixture_key, count, timeout) do
    {_bpmn, process_id, _dmn} = Map.fetch!(@fixtures, fixture_key)
    deploy_fixture(fixture_key)

    for _ <- 1..@warmup_runs do
      run_batch(process_id, count, timeout)
    end

    measurements =
      for run <- 1..@measured_runs do
        elapsed_ms = run_batch(process_id, count, timeout)

        IO.puts(
          "[BENCH] Run #{run}/#{@measured_runs}: " <>
            "#{process_id} x#{count} = #{elapsed_ms}ms"
        )

        elapsed_ms
      end

    average = div(Enum.sum(measurements), @measured_runs)
    ceiling = average * 5

    IO.puts(
      "[BENCH] #{process_id} x#{count}: " <>
        "avg=#{average}ms, min=#{Enum.min(measurements)}ms, " <>
        "max=#{Enum.max(measurements)}ms, ceiling=#{ceiling}ms"
    )

    {average, ceiling}
  end

  # -------------------------------------------------------------------
  # 100 PIs with varying table sizes
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "100 PIs with 10-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r10, 100, 30_000)

    assert average < 2_315
  end

  @tag :load
  @tag timeout: 120_000
  test "100 PIs with 50-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r50, 100, 30_000)

    assert average < 2_335
  end

  @tag :load
  @tag timeout: 120_000
  test "100 PIs with 100-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r100, 100, 30_000)

    assert average < 2_365
  end

  @tag :load
  @tag timeout: 120_000
  test "100 PIs with 500-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r500, 100, 60_000)

    assert average < 2_380
  end

  # -------------------------------------------------------------------
  # 1000 PIs with varying table sizes
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 600_000
  test "1000 PIs with 10-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r10, 1_000, 120_000)

    assert average < 24_595
  end

  @tag :load
  @tag timeout: 600_000
  test "1000 PIs with 50-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r50, 1_000, 120_000)

    assert average < 24_720
  end

  @tag :load
  @tag timeout: 600_000
  test "1000 PIs with 100-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r100, 1_000, 120_000)

    assert average < 24_895
  end

  @tag :load
  @tag timeout: 1_200_000
  test "1000 PIs with 500-rule decision table" do
    {average, _ceiling} = run_measured_scenario(:r500, 1_000, 300_000)

    assert average < 74_230
  end
end
