defmodule BfwEngine.Events.SubscriptionProcessInstanceIndexTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.SignalSubscriptions

  setup do
    MessageSubscriptions.reset_state()
    SignalSubscriptions.reset_state()
    :ok
  end

  test "unregister_all_for_process_instance on messages does not drop another PI's subscription" do
    {:ok, kept_id} =
      MessageSubscriptions.register(%{
        process_instance_id: "pi-kept",
        flow_node_instance_id: "fni-kept",
        flow_node_id: "Catch_kept",
        message_name: "order",
        expected_correlation_value: :none,
        kind: :intermediate_catch,
        via_pid: self()
      })

    {:ok, _removed_id} =
      MessageSubscriptions.register(%{
        process_instance_id: "pi-removed",
        flow_node_instance_id: "fni-removed",
        flow_node_id: "Catch_removed",
        message_name: "order",
        expected_correlation_value: :none,
        kind: :intermediate_catch,
        via_pid: self()
      })

    MessageSubscriptions.unregister_all_for_process_instance("pi-removed")

    remaining = MessageSubscriptions.lookup("order", :none)
    assert Enum.map(remaining, & &1.subscription_id) == [kept_id]
    assert Enum.all?(remaining, &(&1.process_instance_id == "pi-kept"))
  end

  test "unregister_all_for_process_instance on signals does not drop another PI's subscription" do
    {:ok, kept_id} =
      SignalSubscriptions.register(%{
        process_instance_id: "pi-kept",
        flow_node_instance_id: "fni-kept",
        flow_node_id: "Catch_kept",
        signal_name: "go",
        kind: :intermediate_catch,
        via_pid: self()
      })

    {:ok, _removed_id} =
      SignalSubscriptions.register(%{
        process_instance_id: "pi-removed",
        flow_node_instance_id: "fni-removed",
        flow_node_id: "Catch_removed",
        signal_name: "go",
        kind: :intermediate_catch,
        via_pid: self()
      })

    SignalSubscriptions.unregister_all_for_process_instance("pi-removed")

    remaining = SignalSubscriptions.lookup("go")
    assert Enum.map(remaining, & &1.subscription_id) == [kept_id]
    assert Enum.all?(remaining, &(&1.process_instance_id == "pi-kept"))
  end
end
