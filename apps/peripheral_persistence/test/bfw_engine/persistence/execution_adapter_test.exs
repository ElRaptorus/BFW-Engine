defmodule BfwEngine.Persistence.ExecutionAdapterTest do
  @moduledoc """
  Unit tests for `BfwEngine.Persistence.ExecutionAdapter`.

  Three focus areas:

  - The resume-scoped FNI filter (PF-2) — verifies that
    `list_flow_node_instances/1` returns only the rows the resume path
    actually consumes: `:active` + `:waiting` (re-dispatched / re-attached)
    plus `:finished` End-Event FNIs (forward-compat with multi-End
    aggregation across restarts; see Phase 2 items 13-14).
  - The paginated PI load (PF-1) — verifies that
    `list_running_process_instances/1` honors `:limit` and `:after`
    keyset semantics, scopes to root running PIs, and produces a stable
    cursor for the next page.
  - Atomic DOA write batching — verifies that `finish_fni_with_data_objects/3`
    persists the FNI state transition and all Data Object writes in a single
    transaction (all-or-nothing).
  """

  use BfwEngine.Persistence.DataCase, async: false

  alias BfwEngine.Execution.DataObjectWriteIntent
  alias BfwEngine.Persistence.ExecutionAdapter
  alias BfwEngine.Persistence.Repo
  alias BfwEngine.Persistence.Resources.FlowNodeInstance
  alias BfwEngine.Persistence.Resources.ProcessInstance
  alias Ecto.Adapters.SQL, as: EctoSQL

  describe "create_process_instance/1 and update_process_instance/2" do
    test "persists a process instance and reads back matching fields" do
      now = DateTime.utc_now()
      process_version_id = Ash.UUIDv7.generate()

      attributes = %{
        process_version_id: process_version_id,
        state: "running",
        started_at: now,
        started_by: %{"id" => "user-1"},
        started_with_context: %{"orderId" => "42"},
        business_key: "order-42"
      }

      assert {:ok, %{id: process_instance_id}} =
               ExecutionAdapter.create_process_instance(attributes)

      assert {:ok, record} = Ash.get(ProcessInstance, process_instance_id, authorize?: false)

      assert record.process_version_id == process_version_id
      assert record.state == "running"
      assert record.started_by == %{"id" => "user-1"}
      assert record.started_with_context == %{"orderId" => "42"}
      assert record.business_key == "order-42"
      assert record.deleted == false
    end

    test "update_process_instance transitions running PI to finished" do
      now = DateTime.utc_now()

      {:ok, %{id: process_instance_id}} =
        ExecutionAdapter.create_process_instance(%{
          process_version_id: Ash.UUIDv7.generate(),
          state: "running",
          started_at: now
        })

      finished_at = DateTime.utc_now()

      assert :ok =
               ExecutionAdapter.update_process_instance(process_instance_id, %{
                 state: "finished",
                 finished_at: finished_at
               })

      assert {:ok, record} = Ash.get(ProcessInstance, process_instance_id, authorize?: false)
      assert record.state == "finished"
      assert record.finished_at == finished_at
    end

    test "soft-deleted PI is invisible through the primary :read action" do
      now = DateTime.utc_now()

      {:ok, %{id: process_instance_id}} =
        ExecutionAdapter.create_process_instance(%{
          process_version_id: Ash.UUIDv7.generate(),
          state: "running",
          started_at: now
        })

      finished_at = DateTime.utc_now()

      assert :ok =
               ExecutionAdapter.update_process_instance(process_instance_id, %{
                 state: "finished",
                 finished_at: finished_at
               })

      assert {:ok, record} = Ash.get(ProcessInstance, process_instance_id, authorize?: false)

      assert {:ok, _updated} =
               Ash.update(
                 record,
                 %{
                   deleted: true,
                   deleted_at: DateTime.utc_now(),
                   deleted_by: %{"id" => "admin"}
                 },
                 action: :soft_delete,
                 authorize?: false
               )

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Ash.get(ProcessInstance, process_instance_id, authorize?: false)

      assert {:error, :not_found} =
               ExecutionAdapter.get_process_instance_for_retry(process_instance_id)
    end
  end

  describe "list_flow_node_instances/1 resume-scope filter" do
    setup do
      process_instance_id = Ash.UUIDv7.generate()
      now = DateTime.utc_now()

      seed = fn attrs ->
        defaults = %{
          process_instance_id: process_instance_id,
          flow_node_id: "node_#{Ash.UUIDv7.generate()}",
          flow_node_type: "task",
          state: "active",
          started_at: now
        }

        FlowNodeInstance
        |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs))
        |> Ash.create!()
      end

      %{process_instance_id: process_instance_id, seed: seed}
    end

    test "returns only :active, :waiting, and :finished End-Event FNIs",
         %{process_instance_id: process_instance_id, seed: seed} do
      kept_active = seed.(%{state: "active", flow_node_type: "task", flow_node_id: "Task_active"})

      kept_waiting =
        seed.(%{state: "waiting", flow_node_type: "user_task", flow_node_id: "UT_waiting"})

      kept_finished_end =
        seed.(%{state: "finished", flow_node_type: "end_event", flow_node_id: "End_done"})

      _dropped_finished_task =
        seed.(%{state: "finished", flow_node_type: "task", flow_node_id: "Task_done"})

      _dropped_finished_gateway =
        seed.(%{state: "finished", flow_node_type: "exclusive_gateway", flow_node_id: "XOR_done"})

      _dropped_fatal =
        seed.(%{state: "fatal", flow_node_type: "service_task", flow_node_id: "ST_fatal"})

      _dropped_aborted =
        seed.(%{state: "aborted", flow_node_type: "task", flow_node_id: "Task_aborted"})

      _dropped_interrupted =
        seed.(%{state: "interrupted", flow_node_type: "task", flow_node_id: "Task_interrupted"})

      assert {:ok, records} = ExecutionAdapter.list_flow_node_instances(process_instance_id)

      returned_ids = records |> Enum.map(& &1.id) |> Enum.sort()
      expected_ids = [kept_active.id, kept_waiting.id, kept_finished_end.id] |> Enum.sort()

      assert returned_ids == expected_ids
      assert length(records) == 3
    end

    test "drops :finished non-End-Event FNIs but keeps :finished End-Event FNIs",
         %{process_instance_id: process_instance_id, seed: seed} do
      _finished_task = seed.(%{state: "finished", flow_node_type: "task"})
      _finished_user_task = seed.(%{state: "finished", flow_node_type: "user_task"})
      _finished_service_task = seed.(%{state: "finished", flow_node_type: "service_task"})
      _finished_xor = seed.(%{state: "finished", flow_node_type: "exclusive_gateway"})
      _finished_intermediate = seed.(%{state: "finished", flow_node_type: "intermediate_event"})
      kept_end_event = seed.(%{state: "finished", flow_node_type: "end_event"})

      assert {:ok, records} = ExecutionAdapter.list_flow_node_instances(process_instance_id)

      assert length(records) == 1
      assert hd(records).id == kept_end_event.id
      assert hd(records).flow_node_type == "end_event"
    end

    test "scopes results to the requested process_instance_id",
         %{seed: seed} do
      pi_a = Ash.UUIDv7.generate()
      pi_b = Ash.UUIDv7.generate()

      kept_a = seed.(%{process_instance_id: pi_a, state: "active"})
      _other_pi = seed.(%{process_instance_id: pi_b, state: "active"})

      assert {:ok, records} = ExecutionAdapter.list_flow_node_instances(pi_a)
      assert length(records) == 1
      assert hd(records).id == kept_a.id
    end

    test "returns empty list when PI has no FNIs" do
      assert {:ok, []} = ExecutionAdapter.list_flow_node_instances(Ash.UUIDv7.generate())
    end

    test "returns empty list when PI has only terminal non-End-Event FNIs",
         %{process_instance_id: process_instance_id, seed: seed} do
      _ = seed.(%{state: "fatal", flow_node_type: "service_task"})
      _ = seed.(%{state: "aborted", flow_node_type: "task"})
      _ = seed.(%{state: "interrupted", flow_node_type: "task"})
      _ = seed.(%{state: "finished", flow_node_type: "task"})

      assert {:ok, []} = ExecutionAdapter.list_flow_node_instances(process_instance_id)
    end
  end

  describe "list_running_process_instances/1 pagination" do
    setup do
      now = DateTime.utc_now()

      seed_pi = fn attrs ->
        defaults = %{
          process_version_id: Ash.UUIDv7.generate(),
          state: "running",
          started_at: now
        }

        ProcessInstance
        |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs))
        |> Ash.create!()
      end

      %{seed_pi: seed_pi}
    end

    test "empty DB returns no records and no cursor" do
      assert {:ok, %{records: [], next_cursor: nil}} =
               ExecutionAdapter.list_running_process_instances(limit: 10)
    end

    test "single page (5 rows, limit 10) returns all rows and nil cursor",
         %{seed_pi: seed_pi} do
      Enum.each(1..5, fn _ -> seed_pi.(%{}) end)

      assert {:ok, %{records: records, next_cursor: nil}} =
               ExecutionAdapter.list_running_process_instances(limit: 10)

      assert length(records) == 5
    end

    test "exact page boundary (10 rows, limit 10) returns 10 records and a cursor; next call returns empty + nil",
         %{seed_pi: seed_pi} do
      Enum.each(1..10, fn _ -> seed_pi.(%{}) end)

      assert {:ok, %{records: records, next_cursor: cursor}} =
               ExecutionAdapter.list_running_process_instances(limit: 10)

      assert length(records) == 10
      assert is_binary(cursor)
      assert cursor == records |> List.last() |> Map.get(:id)

      assert {:ok, %{records: [], next_cursor: nil}} =
               ExecutionAdapter.list_running_process_instances(limit: 10, after: cursor)
    end

    test "multi-page (25 rows, limit 10) returns 10 + 10 + 5 with no overlap",
         %{seed_pi: seed_pi} do
      Enum.each(1..25, fn _ -> seed_pi.(%{}) end)

      {:ok, %{records: page1, next_cursor: c1}} =
        ExecutionAdapter.list_running_process_instances(limit: 10)

      {:ok, %{records: page2, next_cursor: c2}} =
        ExecutionAdapter.list_running_process_instances(limit: 10, after: c1)

      {:ok, %{records: page3, next_cursor: c3}} =
        ExecutionAdapter.list_running_process_instances(limit: 10, after: c2)

      assert length(page1) == 10
      assert length(page2) == 10
      assert length(page3) == 5
      assert c3 == nil

      all_ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert length(all_ids) == 25
      assert length(Enum.uniq(all_ids)) == 25
    end

    test "filter respected — only root :running PIs are returned",
         %{seed_pi: seed_pi} do
      root_pis = Enum.map(1..5, fn _ -> seed_pi.(%{}) end)

      _finished_pis = Enum.map(1..3, fn _ -> seed_pi.(%{state: "finished"}) end)

      _child_pis =
        Enum.map(1..2, fn _ ->
          seed_pi.(%{parent_process_instance_id: Ash.UUIDv7.generate()})
        end)

      assert {:ok, %{records: records, next_cursor: nil}} =
               ExecutionAdapter.list_running_process_instances(limit: 100)

      returned_ids = records |> Enum.map(& &1.id) |> Enum.sort()
      expected_ids = root_pis |> Enum.map(& &1.id) |> Enum.sort()

      assert returned_ids == expected_ids
      assert length(records) == 5
    end

    test "cursor produces stable, deterministic page boundaries across calls",
         %{seed_pi: seed_pi} do
      pis = Enum.map(1..15, fn _ -> seed_pi.(%{}) end)

      assert {:ok, %{records: page1_a, next_cursor: cursor}} =
               ExecutionAdapter.list_running_process_instances(limit: 10)

      assert {:ok, %{records: page1_b, next_cursor: ^cursor}} =
               ExecutionAdapter.list_running_process_instances(limit: 10)

      assert Enum.map(page1_a, & &1.id) == Enum.map(page1_b, & &1.id)

      assert {:ok, %{records: page2_a, next_cursor: nil}} =
               ExecutionAdapter.list_running_process_instances(limit: 10, after: cursor)

      assert {:ok, %{records: page2_b, next_cursor: nil}} =
               ExecutionAdapter.list_running_process_instances(limit: 10, after: cursor)

      assert Enum.map(page2_a, & &1.id) == Enum.map(page2_b, & &1.id)

      total = page1_a ++ page2_a
      assert length(total) == 15
      assert MapSet.new(Enum.map(total, & &1.id)) == MapSet.new(Enum.map(pis, & &1.id))
    end
  end

  describe "finish_fni_with_data_objects/3 atomicity" do
    setup do
      now = DateTime.utc_now()
      pi_id = Ash.UUIDv7.generate()

      ProcessInstance
      |> Ash.Changeset.for_create(:create, %{
        id: pi_id,
        process_version_id: Ash.UUIDv7.generate(),
        state: "running",
        started_at: now
      })
      |> Ash.create!()

      fni_id = Ash.UUIDv7.generate()

      FlowNodeInstance
      |> Ash.Changeset.for_create(:create, %{
        id: fni_id,
        process_instance_id: pi_id,
        flow_node_id: "Task_1",
        flow_node_type: "task",
        state: "active",
        started_at: now
      })
      |> Ash.create!()

      %{pi_id: pi_id, fni_id: fni_id, now: now}
    end

    defp count_data_objects(pi_id) do
      %{rows: [[count]]} =
        EctoSQL.query!(Repo, "SELECT count(*) FROM data_objects WHERE process_instance_id = $1", [
          dump_uuid!(pi_id)
        ])

      count
    end

    defp count_data_object_writes(pi_id) do
      %{rows: [[count]]} =
        EctoSQL.query!(
          Repo,
          "SELECT count(*) FROM data_object_writes WHERE process_instance_id = $1",
          [
            dump_uuid!(pi_id)
          ]
        )

      count
    end

    defp dump_uuid!(uuid_string) do
      {:ok, bin} = Ecto.UUID.dump(uuid_string)
      bin
    end

    test "success: FNI transitions to finished and DO rows are created",
         %{pi_id: pi_id, fni_id: fni_id, now: now} do
      intents = [
        %DataObjectWriteIntent{
          data_object_id: "DO_1",
          flow_node_instance_id: fni_id,
          process_instance_id: pi_id,
          previous_value: nil,
          value: %{"x" => 42}
        }
      ]

      fni_changes = %{
        state: "finished",
        finished_at: now,
        output_token: %{"result" => true},
        type_properties: %{}
      }

      assert {:ok, %{writes: [write]}} =
               ExecutionAdapter.finish_fni_with_data_objects(fni_id, fni_changes, intents)

      assert is_binary(write.write_id)
      assert %DateTime{} = write.created_at

      {:ok, fni} = Ash.get(FlowNodeInstance, fni_id, authorize?: false)
      assert fni.state == "finished"

      assert count_data_objects(pi_id) == 1
      assert count_data_object_writes(pi_id) == 1
    end

    test "success with empty intents: FNI transitions, no DO rows",
         %{pi_id: pi_id, fni_id: fni_id, now: now} do
      fni_changes = %{
        state: "finished",
        finished_at: now,
        output_token: %{},
        type_properties: %{}
      }

      assert {:ok, %{writes: []}} =
               ExecutionAdapter.finish_fni_with_data_objects(fni_id, fni_changes, [])

      {:ok, fni} = Ash.get(FlowNodeInstance, fni_id, authorize?: false)
      assert fni.state == "finished"

      assert count_data_objects(pi_id) == 0
    end

    test "atomicity: FNI lookup failure rolls back — no DO rows created",
         %{pi_id: pi_id, now: now} do
      bogus_fni_id = Ash.UUIDv7.generate()

      intents = [
        %DataObjectWriteIntent{
          data_object_id: "DO_1",
          flow_node_instance_id: bogus_fni_id,
          process_instance_id: pi_id,
          previous_value: nil,
          value: %{"x" => 99}
        }
      ]

      fni_changes = %{
        state: "finished",
        finished_at: now,
        output_token: %{},
        type_properties: %{}
      }

      assert {:error, _reason} =
               ExecutionAdapter.finish_fni_with_data_objects(bogus_fni_id, fni_changes, intents)

      assert count_data_objects(pi_id) == 0
      assert count_data_object_writes(pi_id) == 0
    end
  end
end
