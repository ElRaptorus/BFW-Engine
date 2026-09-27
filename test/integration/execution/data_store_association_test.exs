defmodule BfwEngine.Integration.Execution.DataStoreAssociationTest do
  @moduledoc """
  Integration test for Data Store associations (task E1.0b). Deploys a
  process that reads from and writes to a Data Store both at the top
  level and inside an embedded subprocess, and asserts that the store
  associations are a runtime no-op: no `data_object_writes` rows, no
  `DataObjectWritten` events, and the `dataObjects` FEEL binding
  continues to reflect only the real Data Objects.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  describe "DS-I1: Data Store associations are a runtime no-op" do
    test "PI finishes; store DOAs/DIAs write nothing and leave dataObjects untouched", %{
      collector: collector
    } do
      process_instance_id =
        http_deploy_and_start("data_store_association.bpmn", "DataStoreAssociation", %{
          "payload" => %{"amount" => 10}
        })

      wait_for_process_instance(process_instance_id)

      assert_pi_state!(process_instance_id, "finished")
      assert_all_fnis_state!(process_instance_id, "finished")

      events = EventCollector.get_events(collector)

      outer_do = fetch_data_object(process_instance_id, "DO_Outer")
      assert outer_do != nil
      assert outer_do.value == %{"outer_value" => 10, "verified" => true}

      child_started =
        Enum.find(events, &match?(%Event.SubProcessChildStarted{}, &1))

      assert child_started != nil, "expected a SubProcessChildStarted event"
      child_process_instance_id = child_started.child_process_instance_id

      inner_do = fetch_data_object(child_process_instance_id, "DO_Inner")
      assert inner_do != nil
      assert inner_do.value == %{"inner_value" => 11}

      outer_writes = fetch_data_object_writes(process_instance_id)
      inner_writes = fetch_data_object_writes(child_process_instance_id)
      writes = outer_writes ++ inner_writes
      write_target_ids = Enum.map(writes, & &1.data_object_id)

      assert length(outer_writes) == 2
      assert length(inner_writes) == 1
      refute "DSR_Outer" in write_target_ids
      refute "DSR_Inner" in write_target_ids
      refute "Store_Outer" in write_target_ids
      refute "Store_Inner" in write_target_ids

      do_events = Enum.filter(events, &match?(%Event.DataObjectWritten{}, &1))
      written_data_object_ids = Enum.map(do_events, & &1.data_object_id)

      assert length(do_events) == 3
      refute "DSR_Outer" in written_data_object_ids
      refute "DSR_Inner" in written_data_object_ids
    end
  end
end
