defmodule EvilEngine.Events.EventSubprocessSubscriptionTest do
  @moduledoc """
  Unit coverage for the Event Subprocess subscription kinds (ESP-D13/D13b/D13c):

  - `MessagePublisher` treats `:event_subprocess_start` as a gated tier-2
    delivery: it fires only when no tier-1 (catch/boundary/receive-task)
    subscription consumed the message, and it counts as a delivery so a
    standalone message start (tier 3) is suppressed.
  - `SignalPublisher` broadcasts to every subscription including
    `:event_subprocess_start` (signals have no catch-wins-over-start gate).
  """
  use ExUnit.Case, async: false

  alias EvilEngine.Events.MessagePublisher
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.SignalPublisher
  alias EvilEngine.Events.SignalSubscriptions

  setup do
    MessageSubscriptions.reset_state()
    SignalSubscriptions.reset_state()
    :ok
  end

  defp register_message(kind, message_name, flow_node_id, correlation \\ :none) do
    {:ok, _} =
      MessageSubscriptions.register(%{
        process_instance_id: "pi_" <> flow_node_id,
        flow_node_instance_id: "fni_" <> flow_node_id,
        flow_node_id: flow_node_id,
        message_name: message_name,
        expected_correlation_value: correlation,
        kind: kind,
        via_pid: self()
      })
  end

  defp register_signal(kind, signal_name, flow_node_id) do
    {:ok, _} =
      SignalSubscriptions.register(%{
        process_instance_id: "pi_" <> flow_node_id,
        flow_node_instance_id: "fni_" <> flow_node_id,
        flow_node_id: flow_node_id,
        signal_name: signal_name,
        kind: kind,
        via_pid: self()
      })
  end

  describe "MessagePublisher ESP message-start tiering" do
    test "an inline catch (tier 1) wins and the ESP start (tier 2) is suppressed" do
      register_message(:intermediate_catch, "order", "Catch_1")
      register_message(:event_subprocess_start, "order", "ESP_Start_1")

      {:ok, result} =
        MessagePublisher.publish_message(%{name: "order", payload: %{}, skip_pending: true})

      assert_receive {:message_arrived, _message_id, _payload, _triggerer}
      refute_receive {:event_subprocess_message, "ESP_Start_1", _}
      assert length(result.deliveries) == 1
    end

    test "an ESP message start fires as a delivery when no tier-1 subscription exists" do
      register_message(:event_subprocess_start, "order", "ESP_Start_1")

      {:ok, result} =
        MessagePublisher.publish_message(%{
          name: "order",
          payload: %{amount: 5},
          skip_pending: true
        })

      assert_receive {:event_subprocess_message, "ESP_Start_1", %{amount: 5}}
      # Counts as a delivery → suppresses a standalone message start (tier 3).
      assert length(result.deliveries) == 1
      assert result.started_process_instance_ids == []
    end

    test "an ESP message start with a mismatched correlation does not fire" do
      register_message(:event_subprocess_start, "order", "ESP_Start_1", "A")

      {:ok, result} =
        MessagePublisher.publish_message(%{
          name: "order",
          payload: %{},
          correlation_value: "B",
          skip_pending: true
        })

      refute_receive {:event_subprocess_message, "ESP_Start_1", _}
      assert result.deliveries == []
    end
  end

  describe "SignalPublisher broadcast includes ESP starts" do
    test "an ESP signal start receives the broadcast alongside an inline catch" do
      register_signal(:intermediate_catch, "cancel", "Catch_1")
      register_signal(:event_subprocess_start, "cancel", "ESP_Start_1")

      {:ok, result} = SignalPublisher.publish_signal(%{name: "cancel"})

      assert_receive {:signal_arrived, _signal_id, _triggerer}
      assert_receive {:event_subprocess_signal, "ESP_Start_1"}
      assert length(result.deliveries) == 2
    end
  end
end
