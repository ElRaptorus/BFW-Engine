defmodule EvilEngine.Integration.Persistence.RetentionPurgeTest do
  @moduledoc """
  Integration test for Mix-scheduled process-instance tree hard-delete.

  Deploys a linear process, finishes it over HTTP, backdates `finished_at`,
  runs `ProcessInstancePurge.purge_eligible_trees/1`, and asserts the PI
  row is gone.
  """

  use EvilEngine.ExecutionCase, async: false

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias EvilEngine.Persistence.ProcessInstancePurge
  alias EvilEngine.Persistence.Repo

  @moduletag :integration

  test "purge removes an aged finished linear process instance" do
    {201, _} = http_deploy("linear_start_end.bpmn")

    {201, body} = http_start("LinearStartEnd", %{"payload" => %{"key" => "value"}})
    process_instance_id = body["processInstanceId"]
    wait_for_process_instance(process_instance_id)
    assert_pi_state!(process_instance_id, "finished")

    aged_finished_at = DateTime.add(DateTime.utc_now(), -10, :day)

    %{num_rows: 1} =
      EctoSQL.query!(
        Repo,
        "UPDATE process_instances SET finished_at = $1 WHERE id = $2::uuid",
        [aged_finished_at, dump_uuid!(process_instance_id)]
      )

    assert {:ok, %{purged_root_count: 1, skipped_root_count: 0, dry_run: false}} =
             ProcessInstancePurge.purge_eligible_trees(
               retention_config: [finished_days: 1],
               now: DateTime.utc_now()
             )

    assert fetch_process_instance(process_instance_id) == nil

    %{rows: [[count]]} =
      EctoSQL.query!(
        Repo,
        "SELECT COUNT(*) FROM process_instances WHERE id = $1::uuid",
        [dump_uuid!(process_instance_id)]
      )

    assert count == 0
  end

  defp dump_uuid!(uuid_string) do
    {:ok, binary} = Ecto.UUID.dump(uuid_string)
    binary
  end
end
