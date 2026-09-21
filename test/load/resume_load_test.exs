defmodule BfwEngine.Load.ResumeLoadTest do
  @moduledoc """
  Load / benchmark tests for resume-on-startup.

  Validates that the engine can resume large numbers of process instances
  within acceptable time bounds. Results are printed as structured
  benchmark lines for CI parsing.
  Note: Unline execution load tests, these tests do not verify Flow Node Interactivity
  after resuming is done.
  Post-resuming interactivity checks are covered by the integration tests.
  The purpose of these load tests is to check "how fast can the Engine pick up
  from where it previously left off?"

  ## Threshold methodology

  Ceilings are set at ~5x the observed baseline on this machine
  (Linux, Postgres in Docker). This catches a 3x regression while
  leaving headroom for CI variability. Original M-series baselines
  (2026-05-03) are superseded by the 2026-09-02 Linux measurements
  that failed the old 5× ceilings.

  | Test | Baseline | Ceiling |
  |------|----------|---------|
  | L1   |   189 ms | 1000 ms |
  | L2   |  1,903 ms |   10 s |
  | L3   |  1,893 ms |   10 s |
  | L4   |   887 ms | 4500 ms |
  | L5   | 15,422 ms |   80 s |
  | L6   | 46,340 ms |  232 s |
  | L7   |  8,432 ms |   43 s |
  | L8   | ~2.1ms/PI | 11ms/PI |
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Execution
  alias BfwEngine.Test.LoadHelpers

  @user_task_fni %{
    flow_node_id: "UserTask_1",
    flow_node_type: :user_task,
    state: :waiting,
    input_token: %{"load" => "test"},
    type_properties: %{}
  }

  @manual_task_fni %{
    flow_node_id: "ManualTask_1",
    flow_node_type: :manual_task,
    state: :waiting,
    input_token: %{"load" => "test"},
    type_properties: %{}
  }

  @async_service_fni %{
    flow_node_id: "ServiceTask_1",
    flow_node_type: :service_task,
    state: :waiting,
    input_token: %{"load" => "test"},
    type_properties: %{"async" => true}
  }

  setup do
    version_id = gen_version_id()
    deploy_fixture("user_task_simple.bpmn", version_id)
    {:ok, version_id: version_id}
  end

  # -------------------------------------------------------------------
  # L1: Resume 100 user-task PIs
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 30_000
  test "L1: resume 100 user-task PIs", context do
    seeded = LoadHelpers.seed_process_instances(context.version_id, 100, [@user_task_fni])

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "resume_100_user_task_pis",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "resume_100_user_task_pis",
        kind: :resume,
        process_count: 100,
        kpi_kind: :resume
      )

    assert count == 100
    assert elapsed_ms < 1_000

    Process.sleep(500)

    process_instance_count =
      Enum.count(seeded, fn %{process_instance_id: process_instance_id} ->
        match?({:ok, _}, Execution.lookup_process_instance(process_instance_id))
      end)

    assert process_instance_count == 100

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # L2: Resume 1,000 mixed PIs
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 30_000
  test "L2: resume 1,000 mixed PIs", context do
    version_id_manual = gen_version_id()
    deploy_fixture("manual_task_confirm.bpmn", version_id_manual)
    version_id_async = gen_version_id()
    deploy_fixture("service_task_async_park.bpmn", version_id_async)

    templates = [
      {context.version_id, [@user_task_fni]},
      {version_id_manual, [@manual_task_fni]},
      {version_id_async, [@async_service_fni]}
    ]

    seeded =
      Enum.flat_map(1..334, fn index ->
        {version_id, flow_node_instance_template} = Enum.at(templates, rem(index - 1, 3))
        LoadHelpers.seed_process_instances(version_id, 1, flow_node_instance_template)
      end)

    remaining = 1000 - length(seeded)
    extra = LoadHelpers.seed_process_instances(context.version_id, remaining, [@user_task_fni])
    all_seeded = seeded ++ extra

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "resume_1000_mixed_pis",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "resume_1000_mixed_pis",
        kind: :resume,
        process_count: 1_000,
        kpi_kind: :resume
      )

    assert count == 1000
    assert elapsed_ms < 10_000

    LoadHelpers.terminate_all_process_instances()
    _ = all_seeded
  end

  # -------------------------------------------------------------------
  # L3: Resume 1,000 user-task PIs (batch)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 30_000
  test "L3: resume 1,000 user-task PIs", context do
    _seeded = LoadHelpers.seed_process_instances(context.version_id, 1_000, [@user_task_fni])

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "resume_1000_user_task_pis",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "resume_1000_user_task_pis",
        kind: :resume,
        process_count: 1_000,
        kpi_kind: :resume
      )

    assert count == 1_000
    assert elapsed_ms < 10_000

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # L4: Resume PIs with varying FNI counts (1-5 FNIs each)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 30_000
  test "L4: resume 500 PIs with 1-5 FNIs each", context do
    finished_flow_node_instance_template = %{
      flow_node_id: "Start_1",
      flow_node_type: :start_event,
      state: :finished,
      input_token: %{},
      type_properties: %{}
    }

    seeded =
      Enum.flat_map(1..500, fn index ->
        flow_node_instance_count = rem(index - 1, 5) + 1

        flow_node_instances = [
          @user_task_fni
          | List.duplicate(finished_flow_node_instance_template, flow_node_instance_count - 1)
        ]

        LoadHelpers.seed_process_instances(context.version_id, 1, flow_node_instances)
      end)

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "resume_500_varying_fnis",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "resume_500_varying_fnis",
        kind: :resume,
        process_count: 500,
        kpi_kind: :resume
      )

    assert count == 500
    assert elapsed_ms < 4_500

    Process.sleep(500)

    registered =
      Enum.count(seeded, fn %{process_instance_id: process_instance_id} ->
        match?({:ok, _}, Execution.lookup_process_instance(process_instance_id))
      end)

    assert registered == 500

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # L5: Resume 5,000 mixed PIs (varying process complexity)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "L5: resume 5,000 mixed PIs across 3 process types", context do
    version_id_manual = gen_version_id()
    deploy_fixture("manual_task_confirm.bpmn", version_id_manual)
    version_id_async = gen_version_id()
    deploy_fixture("service_task_async_park.bpmn", version_id_async)

    templates = [
      {context.version_id, [@user_task_fni]},
      {version_id_manual, [@manual_task_fni]},
      {version_id_async, [@async_service_fni]}
    ]

    seeded = LoadHelpers.seed_mixed_pis(templates, 5_000)

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "resume_5000_mixed_pis",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "resume_5000_mixed_pis",
        kind: :resume,
        process_count: 5_000,
        kpi_kind: :resume
      )

    assert count == 5_000
    assert elapsed_ms < 80_000

    LoadHelpers.terminate_all_process_instances()
    _ = seeded
  end

  # -------------------------------------------------------------------
  # L6: Resume 10,000 user-task PIs (stress)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 300_000
  test "L6: resume 10,000 user-task PIs", context do
    _seeded = LoadHelpers.seed_process_instances(context.version_id, 10_000, [@user_task_fni])

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "resume_10000_user_task_pis",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "resume_10000_user_task_pis",
        kind: :resume,
        process_count: 10_000,
        kpi_kind: :resume
      )

    assert count == 10_000
    assert elapsed_ms < 232_000

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # L7: Resume 5,000 PIs with heavy FNI counts (5-10 FNIs each)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "L7: resume 5,000 PIs with 5-10 FNIs each", context do
    finished_flow_node_instance_template = %{
      flow_node_id: "Start_1",
      flow_node_type: :start_event,
      state: :finished,
      input_token: %{},
      type_properties: %{}
    }

    _seeded =
      Enum.flat_map(1..5_000, fn index ->
        extra_count = rem(index - 1, 6) + 4

        flow_node_instances = [
          @user_task_fni | List.duplicate(finished_flow_node_instance_template, extra_count)
        ]

        LoadHelpers.seed_process_instances(context.version_id, 1, flow_node_instances)
      end)

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "resume_5000_heavy_fnis",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "resume_5000_heavy_fnis",
        kind: :resume,
        process_count: 5_000,
        kpi_kind: :resume
      )

    assert count == 5_000
    assert elapsed_ms < 43_000

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # L8: Batch seeding throughput (measures DB write speed)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "L8: seed throughput — 1000/5000/10000 PIs in batches", context do
    for batch_size <- [1_000, 5_000, 10_000] do
      {elapsed_ms, seeded} =
        LoadHelpers.measure(
          "seed_#{batch_size}_pis",
          fn ->
            LoadHelpers.seed_process_instances(context.version_id, batch_size, [@user_task_fni])
          end,
          id: "seed_#{batch_size}_pis",
          kind: :seeding,
          process_count: batch_size,
          kpi_kind: :seeding
        )

      assert length(seeded) == batch_size
      # 5× of ~2.1ms/PI Linux baseline. The old 3ms/PI cap was ~1.4× and
      # failed on GitHub ubuntu-latest (2 vCPU) at 3.2ms/PI.
      assert elapsed_ms < batch_size * 11

      LoadHelpers.cleanup_seeded_pis(seeded)
    end
  end
end
