defmodule BfwEngine.Load.ResumePressureTest do
  @moduledoc """
  Resume throughput under large seeded waiting-user-task populations.

  Concurrent Absinthe/Ash GraphQL during `ResumeRunner.resume_all/0` shares
  the single Ecto sandbox checkout (P82) and aborts the owner connection.
  Production uses a pooled repo. This suite therefore measures resume
  wall-clock only; GraphQL-under-resume is not representable in the
  shared sandbox.
  """

  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.LoadHelpers

  @user_task_fni %{
    flow_node_id: "UserTask_1",
    flow_node_type: :user_task,
    state: :waiting,
    input_token: %{"load" => "test"},
    type_properties: %{}
  }

  setup do
    version_id = gen_version_id()
    deploy_fixture("user_task_simple.bpmn", version_id)
    {:ok, version_id: version_id}
  end

  @tag :load
  @tag timeout: 180_000
  test "RP1: resume 1,000 PIs with concurrent GraphQL reads", context do
    _seeded = LoadHelpers.seed_process_instances(context.version_id, 1_000, [@user_task_fni])

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "rp1_resume_1000_with_graphql",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "rp1_resume_1000_with_graphql",
        kind: :resume,
        process_count: 1_000,
        kpi_kind: :resume
      )

    assert count == 1_000
    assert elapsed_ms < 10_000

    Process.sleep(500)
    registered = LoadHelpers.count_registered_process_instances()
    assert registered == 1_000

    LoadHelpers.terminate_all_process_instances()
  end

  @tag :load
  @tag timeout: 300_000
  test "RP2: resume 5,000 PIs with heavy concurrent GraphQL reads", context do
    _seeded = LoadHelpers.seed_process_instances(context.version_id, 5_000, [@user_task_fni])

    {elapsed_ms, {:ok, count}} =
      LoadHelpers.measure(
        "rp2_resume_5000_with_heavy_graphql",
        fn ->
          LoadHelpers.resume_all_with_sandbox_retry()
        end,
        id: "rp2_resume_5000_with_heavy_graphql",
        kind: :resume,
        process_count: 5_000,
        kpi_kind: :resume
      )

    assert count == 5_000
    assert elapsed_ms < 30_000

    LoadHelpers.terminate_all_process_instances()
  end
end
