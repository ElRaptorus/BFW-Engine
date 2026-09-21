defmodule BfwEngine.Persistence.TimerStartScheduleAdapterTest do
  @moduledoc """
  Tests for `BfwEngine.Persistence.TimerStartScheduleAdapter`.

  Covers create / get / update / delete-for-version, armed listing,
  unique (process_version_id, flow_node_id) conflicts, and FK rejection.
  """

  use BfwEngine.Persistence.DataCase, async: false

  alias BfwEngine.Persistence.Resources.Process
  alias BfwEngine.Persistence.Resources.ProcessVersion
  alias BfwEngine.Persistence.TimerStartScheduleAdapter

  describe "create_schedule/1 and get_schedule/1" do
    test "persists a cycle schedule and reads it back" do
      version = insert_process_version()
      next_fire_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        process_version_id: version.id,
        process_model_id: "timer-persist-process",
        flow_node_id: "TimerStart_1",
        kind: "cycle",
        iso_spec: "R/PT1S",
        enabled: true,
        next_fire_at: next_fire_at,
        cycle_total: nil,
        cycle_remaining: nil
      }

      assert {:ok, record} = TimerStartScheduleAdapter.create_schedule(attrs)
      assert is_binary(record.id)
      assert record.process_version_id == to_string(version.id)
      assert record.process_model_id == "timer-persist-process"
      assert record.flow_node_id == "TimerStart_1"
      assert record.kind == "cycle"
      assert record.iso_spec == "R/PT1S"
      assert record.enabled == true
      assert DateTime.compare(record.next_fire_at, next_fire_at) == :eq

      assert {:ok, fetched} = TimerStartScheduleAdapter.get_schedule(record.id)
      assert fetched.id == record.id
      assert fetched.flow_node_id == "TimerStart_1"
    end

    test "get_schedule returns not_found for an unknown id" do
      assert {:error, :not_found} =
               TimerStartScheduleAdapter.get_schedule(Ash.UUIDv7.generate())
    end
  end

  describe "update_schedule/2" do
    test "updates enabled and scheduler_ref" do
      version = insert_process_version()

      {:ok, record} =
        TimerStartScheduleAdapter.create_schedule(%{
          process_version_id: version.id,
          process_model_id: "timer-persist-process",
          flow_node_id: "TimerStart_1",
          kind: "cycle",
          iso_spec: "R/PT1S",
          enabled: true,
          next_fire_at: DateTime.utc_now()
        })

      assert {:ok, updated} =
               TimerStartScheduleAdapter.update_schedule(record.id, %{
                 enabled: false,
                 scheduler_ref: "timer-ref-1"
               })

      assert updated.enabled == false
      assert updated.scheduler_ref == "timer-ref-1"
    end
  end

  describe "list_armed_schedules/0" do
    test "omits disabled and exhausted schedules" do
      version = insert_process_version()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, armed} =
        TimerStartScheduleAdapter.create_schedule(%{
          process_version_id: version.id,
          process_model_id: "timer-persist-process",
          flow_node_id: "TimerStart_armed",
          kind: "cycle",
          iso_spec: "R/PT1S",
          enabled: true,
          next_fire_at: now
        })

      {:ok, _disabled} =
        TimerStartScheduleAdapter.create_schedule(%{
          process_version_id: version.id,
          process_model_id: "timer-persist-process",
          flow_node_id: "TimerStart_disabled",
          kind: "cycle",
          iso_spec: "R/PT1S",
          enabled: false,
          next_fire_at: now
        })

      {:ok, _exhausted} =
        TimerStartScheduleAdapter.create_schedule(%{
          process_version_id: version.id,
          process_model_id: "timer-persist-process",
          flow_node_id: "TimerStart_exhausted",
          kind: "cycle",
          iso_spec: "R3/PT1S",
          enabled: true,
          next_fire_at: nil
        })

      assert {:ok, armed_schedules} = TimerStartScheduleAdapter.list_armed_schedules()
      armed_ids = Enum.map(armed_schedules, & &1.id)
      assert armed.id in armed_ids
      refute Enum.any?(armed_schedules, &(&1.flow_node_id == "TimerStart_disabled"))
      refute Enum.any?(armed_schedules, &(&1.flow_node_id == "TimerStart_exhausted"))
    end
  end

  describe "delete_schedules_for_version/1" do
    test "deletes only the matching version's rows" do
      version_a = insert_process_version()
      version_b = insert_process_version()

      {:ok, _schedule_a} =
        TimerStartScheduleAdapter.create_schedule(%{
          process_version_id: version_a.id,
          process_model_id: "process-a",
          flow_node_id: "TimerStart_1",
          kind: "cycle",
          iso_spec: "R/PT1S",
          enabled: true,
          next_fire_at: DateTime.utc_now()
        })

      {:ok, schedule_b} =
        TimerStartScheduleAdapter.create_schedule(%{
          process_version_id: version_b.id,
          process_model_id: "process-b",
          flow_node_id: "TimerStart_1",
          kind: "cycle",
          iso_spec: "R/PT1S",
          enabled: true,
          next_fire_at: DateTime.utc_now()
        })

      assert :ok = TimerStartScheduleAdapter.delete_schedules_for_version(version_a.id)

      assert {:ok, []} =
               TimerStartScheduleAdapter.list_all_schedules(process_version_id: version_a.id)

      assert {:ok, [^schedule_b]} =
               TimerStartScheduleAdapter.list_all_schedules(process_version_id: version_b.id)
    end
  end

  describe "uniqueness and foreign keys" do
    test "duplicate process_version_id and flow_node_id is an error" do
      version = insert_process_version()

      attrs = %{
        process_version_id: version.id,
        process_model_id: "timer-persist-process",
        flow_node_id: "TimerStart_1",
        kind: "cycle",
        iso_spec: "R/PT1S",
        enabled: true,
        next_fire_at: DateTime.utc_now()
      }

      assert {:ok, _first} = TimerStartScheduleAdapter.create_schedule(attrs)
      assert {:error, _reason} = TimerStartScheduleAdapter.create_schedule(attrs)
    end

    test "unknown process_version_id is an error" do
      assert {:error, _reason} =
               TimerStartScheduleAdapter.create_schedule(%{
                 process_version_id: Ash.UUIDv7.generate(),
                 process_model_id: "missing-version",
                 flow_node_id: "TimerStart_1",
                 kind: "cycle",
                 iso_spec: "R/PT1S",
                 enabled: true,
                 next_fire_at: DateTime.utc_now()
               })
    end
  end

  defp insert_process_version do
    unique = System.unique_integer([:positive])

    {:ok, process} =
      Ash.create(
        Process,
        %{
          process_model_id: "timer-start-adapter-#{unique}",
          name: "Timer Start Adapter"
        },
        authorize?: false
      )

    {:ok, version} =
      Ash.create(
        ProcessVersion,
        %{
          process_id: process.id,
          version: "1.0.0",
          bpmn_xml: "<xml/>"
        },
        authorize?: false
      )

    version
  end
end
