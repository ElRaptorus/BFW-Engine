defmodule EvilEngine.Load.ResumeLoadTest do
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

  Ceilings are set at ~5x the observed baseline on a local dev machine
  (M-series Mac, Postgres in Docker). This catches a 3x regression while
  leaving headroom for CI variability. Baselines measured 2026-05-03:

  | Test | Baseline | Ceiling |
  |------|----------|---------|
  | L1   |    25 ms |  150 ms |
  | L2   |   213 ms | 1200 ms |
  | L3   |   253 ms | 1500 ms |
  | L4   |   117 ms |  700 ms |
  | L5   | 1,265 ms | 7000 ms |
  | L6   | 2,266 ms |   12 s  |
  | L7   | 1,316 ms | 7000 ms |
  | L8   | ~0.8ms/PI | 3ms/PI |
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

    {elapsed_ms, {:ok, count}} = LoadHelpers.measure("resume_100_user_task_pis", fn ->
      ResumeRunner.resume_all()
    end)

    assert count == 100
    assert elapsed_ms < 150

    Process.sleep(500)
    process_instance_count = Enum.count(seeded, fn %{process_instance_id: process_instance_id} ->
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

    {elapsed_ms, {:ok, count}} = LoadHelpers.measure("resume_1000_mixed_pis", fn ->
      ResumeRunner.resume_all()
    end)

    assert count == 1000
    assert elapsed_ms < 1_200

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

    {elapsed_ms, {:ok, count}} = LoadHelpers.measure("resume_1000_user_task_pis", fn ->
      ResumeRunner.resume_all()
    end)

    assert count == 1_000
    assert elapsed_ms < 1_500

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
        flow_node_instances = [@user_task_fni | List.duplicate(finished_flow_node_instance_template, flow_node_instance_count - 1)]
        LoadHelpers.seed_process_instances(context.version_id, 1, flow_node_instances)
      end)

    {elapsed_ms, {:ok, count}} = LoadHelpers.measure("resume_500_varying_fnis", fn ->
      ResumeRunner.resume_all()
    end)

    assert count == 500
    assert elapsed_ms < 700

    Process.sleep(500)
    registered = Enum.count(seeded, fn %{process_instance_id: process_instance_id} ->
      match?({:ok, _}, Execution.lookup_process_instance(process_instance_id))
    end)
    assert registered == 500

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # L5: Resume 5,000 mixed PIs (varying process complexity)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 60_000
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

    {elapsed_ms, {:ok, count}} = LoadHelpers.measure("resume_5000_mixed_pis", fn ->
      ResumeRunner.resume_all()
    end)

    assert count == 5_000
    assert elapsed_ms < 7_000

    LoadHelpers.terminate_all_process_instances()
    _ = seeded
  end

  # -------------------------------------------------------------------
  # L6: Resume 10,000 user-task PIs (stress)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "L6: resume 10,000 user-task PIs", context do
    _seeded = LoadHelpers.seed_process_instances(context.version_id, 10_000, [@user_task_fni])

    {elapsed_ms, {:ok, count}} = LoadHelpers.measure("resume_10000_user_task_pis", fn ->
      ResumeRunner.resume_all()
    end)

    assert count == 10_000
    assert elapsed_ms < 12_000

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
        flow_node_instances = [@user_task_fni | List.duplicate(finished_flow_node_instance_template, extra_count)]
        LoadHelpers.seed_process_instances(context.version_id, 1, flow_node_instances)
      end)

    {elapsed_ms, {:ok, count}} = LoadHelpers.measure("resume_5000_heavy_fnis", fn ->
      ResumeRunner.resume_all()
    end)

    assert count == 5_000
    assert elapsed_ms < 7_000

    LoadHelpers.terminate_all_process_instances()
  end

  # -------------------------------------------------------------------
  # L8: Batch seeding throughput (measures DB write speed)
  # -------------------------------------------------------------------

  @tag :load
  @tag timeout: 120_000
  test "L8: seed throughput — 1000/5000/10000 PIs in batches", context do
    for batch_size <- [1_000, 5_000, 10_000] do
      {elapsed_ms, seeded} = LoadHelpers.measure("seed_#{batch_size}_pis", fn ->
        LoadHelpers.seed_process_instances(context.version_id, batch_size, [@user_task_fni])
      end)

      assert length(seeded) == batch_size
      assert elapsed_ms < batch_size * 3

      LoadHelpers.cleanup_seeded_pis(seeded)
    end
  end
end
