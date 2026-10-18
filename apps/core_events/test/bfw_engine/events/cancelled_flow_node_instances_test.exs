defmodule BfwEngine.Events.CancelledFlowNodeInstancesTest do
  @moduledoc """
  A handler whose flow node instance was cancelled (an interrupted boundary,
  an Event-Based Gateway loser) can register a subscription late. Marked flow
  node instances are refused at registration and skipped by publishers.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.Events.CancelledFlowNodeInstances
  alias BfwEngine.Events.MessagePublisher
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.ServiceReset
  alias BfwEngine.Events.SignalPublisher
  alias BfwEngine.Events.SignalSubscriptions

  defmodule PendingMessageAdapter do
    @moduledoc false

    def find_pending_messages(message_name, _correlation) do
      send(Application.fetch_env!(:core_events, :cancelled_test_pid), {:drained, message_name})
      {:ok, []}
    end

    def mark_pending_delivered(_id), do: :ok
  end

  setup do
    message_adapter = Application.get_env(:core_events, :message_persistence_adapter)
    signal_adapter = Application.get_env(:core_events, :signal_persistence_adapter)
    Application.put_env(:core_events, :message_persistence_adapter, nil)
    Application.put_env(:core_events, :signal_persistence_adapter, nil)

    on_exit(fn ->
      Application.put_env(:core_events, :message_persistence_adapter, message_adapter)
      Application.put_env(:core_events, :signal_persistence_adapter, signal_adapter)
      Application.delete_env(:core_events, :cancelled_test_pid)
    end)

    ServiceReset.message_subscriptions()
    ServiceReset.signal_subscriptions()
    MessageSubscriptions.mark_ready()
    SignalSubscriptions.mark_ready()
    :ok
  end

  test "a late message registration of a cancelled loser does not swallow a live publish" do
    CancelledFlowNodeInstances.mark("fni-loser")
    register_message("fni-loser")
    register_message("fni-winner")

    {:ok, result} = MessagePublisher.publish_message(%{name: "order", payload: %{}})

    assert [%{flow_node_instance_id: "fni-winner"}] = result.deliveries

    assert ["fni-winner"] ==
             Enum.map(MessageSubscriptions.lookup("order", :none), & &1.flow_node_instance_id)
  end

  test "a late message registration of a cancelled loser does not drain a pending message" do
    Application.put_env(:core_events, :message_persistence_adapter, PendingMessageAdapter)
    Application.put_env(:core_events, :cancelled_test_pid, self())

    CancelledFlowNodeInstances.mark("fni-loser")
    register_message("fni-loser")
    refute_received {:drained, "order"}

    register_message("fni-winner")
    assert_received {:drained, "order"}
  end

  test "a subscription marked after it registered is skipped and pruned on publish" do
    register_message("fni-interrupted")
    CancelledFlowNodeInstances.mark("fni-interrupted")

    {:ok, result} = MessagePublisher.publish_message(%{name: "order", payload: %{}})

    assert result.deliveries == []
    assert result.pending
    assert MessageSubscriptions.lookup("order", :none) == []
  end

  test "a late signal registration of a cancelled loser is refused" do
    CancelledFlowNodeInstances.mark("fni-loser")
    register_signal("fni-loser")
    register_signal("fni-winner")

    {:ok, result} = SignalPublisher.publish_signal(%{name: "go"})

    assert [%{flow_node_instance_id: "fni-winner"}] = result.deliveries
    assert [%{flow_node_instance_id: "fni-winner"}] = SignalSubscriptions.lookup("go")
  end

  test "marks are removed when the marking process exits" do
    test_pid = self()

    owner =
      spawn(fn ->
        CancelledFlowNodeInstances.mark("fni-owned")
        send(test_pid, :marked)
      end)

    assert_receive :marked
    reference = Process.monitor(owner)
    assert_receive {:DOWN, ^reference, :process, ^owner, _reason}

    assert await_unmarked("fni-owned")
  end

  defp await_unmarked(flow_node_instance_id, attempts_left \\ 50) do
    cond do
      not CancelledFlowNodeInstances.cancelled?(flow_node_instance_id) ->
        true

      attempts_left > 0 ->
        Process.sleep(10)
        await_unmarked(flow_node_instance_id, attempts_left - 1)

      true ->
        false
    end
  end

  defp register_message(flow_node_instance_id) do
    {:ok, _subscription_id} =
      MessageSubscriptions.register(%{
        process_instance_id: "pi-cancelled",
        flow_node_instance_id: flow_node_instance_id,
        flow_node_id: flow_node_instance_id,
        message_name: "order",
        expected_correlation_value: :none,
        kind: :intermediate_catch,
        via_pid: self()
      })
  end

  defp register_signal(flow_node_instance_id) do
    {:ok, _subscription_id} =
      SignalSubscriptions.register(%{
        process_instance_id: "pi-cancelled",
        flow_node_instance_id: flow_node_instance_id,
        flow_node_id: flow_node_instance_id,
        signal_name: "go",
        kind: :intermediate_catch,
        via_pid: self()
      })
  end
end
