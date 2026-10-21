defmodule BfwEngine.Events.SubscriptionLivenessTest do
  @moduledoc """
  Publishers skip and prune subscriptions whose `via_pid` is dead, and
  `unregister_all_for_flow_node_instance/1` removes only the subscriptions
  of that flow node instance (C1).
  """
  use ExUnit.Case, async: false

  alias BfwEngine.Events.MessagePublisher
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.ServiceReset
  alias BfwEngine.Events.SignalPublisher
  alias BfwEngine.Events.SignalSubscriptions

  setup do
    message_adapter = Application.get_env(:core_events, :message_persistence_adapter)
    signal_adapter = Application.get_env(:core_events, :signal_persistence_adapter)
    Application.put_env(:core_events, :message_persistence_adapter, nil)
    Application.put_env(:core_events, :signal_persistence_adapter, nil)

    on_exit(fn ->
      Application.put_env(:core_events, :message_persistence_adapter, message_adapter)
      Application.put_env(:core_events, :signal_persistence_adapter, signal_adapter)
    end)

    ServiceReset.message_subscriptions()
    ServiceReset.signal_subscriptions()
    MessageSubscriptions.mark_ready()
    SignalSubscriptions.mark_ready()
    :ok
  end

  describe "MessagePublisher" do
    test "a subscription with a dead via_pid is no delivery and is removed" do
      register_message(:boundary, "fni-dead", dead_pid())

      {:ok, result} = MessagePublisher.publish_message(%{name: "order", payload: %{}})

      assert result.deliveries == []
      assert result.pending
      assert MessageSubscriptions.lookup("order", :none) == []
    end

    test "a live Event Subprocess start still fires when a dead catch shares its key" do
      register_message(:intermediate_catch, "fni-dead", dead_pid())
      register_message(:event_subprocess_start, "ESP_Start_1", self())

      {:ok, result} = MessagePublisher.publish_message(%{name: "order", payload: %{amount: 5}})

      assert_receive {:event_subprocess_message, "ESP_Start_1", %{amount: 5}}
      assert [%{flow_node_instance_id: "ESP_Start_1"}] = result.deliveries

      assert [%{kind: :event_subprocess_start}] = MessageSubscriptions.lookup("order", :none)
    end

    test "unregister_all_for_flow_node_instance removes only that flow node instance's rows" do
      register_message(:boundary, "fni-cancelled", self())
      register_message(:intermediate_catch, "fni-kept", self())
      register_message(:event_subprocess_start, "ESP_Start_1", self())

      MessageSubscriptions.unregister_all_for_flow_node_instance("fni-cancelled")

      remaining_ids =
        "order"
        |> MessageSubscriptions.lookup(:none)
        |> Enum.map(& &1.flow_node_instance_id)
        |> Enum.sort()

      assert remaining_ids == ["ESP_Start_1", "fni-kept"]

      MessageSubscriptions.unregister_all_for_process_instance("pi-liveness")
      assert MessageSubscriptions.lookup("order", :none) == []
    end
  end

  describe "SignalPublisher" do
    test "a subscription with a dead via_pid is no delivery and is removed" do
      register_signal(:intermediate_catch, "fni-dead", dead_pid())
      register_signal(:boundary, "fni-live", self())

      {:ok, result} = SignalPublisher.publish_signal(%{name: "go"})

      assert_receive {:signal_arrived, _signal_id, _triggerer}
      assert [%{flow_node_instance_id: "fni-live"}] = result.deliveries
      assert SignalSubscriptions.lookup("go") == []
    end

    test "unregister_all_for_flow_node_instance keeps Event Subprocess starts" do
      register_signal(:boundary, "fni-cancelled", self())
      register_signal(:event_subprocess_start, "ESP_Start_1", self())

      SignalSubscriptions.unregister_all_for_flow_node_instance("fni-cancelled")

      assert [%{kind: :event_subprocess_start}] = SignalSubscriptions.lookup("go")
    end
  end

  defp register_message(kind, flow_node_instance_id, via_pid) do
    {:ok, _subscription_id} =
      MessageSubscriptions.register(%{
        process_instance_id: "pi-liveness",
        flow_node_instance_id: flow_node_instance_id,
        flow_node_id: flow_node_instance_id,
        message_name: "order",
        expected_correlation_value: :none,
        kind: kind,
        via_pid: via_pid
      })
  end

  defp register_signal(kind, flow_node_instance_id, via_pid) do
    {:ok, _subscription_id} =
      SignalSubscriptions.register(%{
        process_instance_id: "pi-liveness",
        flow_node_instance_id: flow_node_instance_id,
        flow_node_id: flow_node_instance_id,
        signal_name: "go",
        kind: kind,
        via_pid: via_pid
      })
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    reference = Process.monitor(pid)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}
    pid
  end
end
