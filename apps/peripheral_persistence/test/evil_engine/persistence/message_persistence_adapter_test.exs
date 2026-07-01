defmodule EvilEngine.Persistence.MessagePersistenceAdapterTest do
  @moduledoc """
  Specification-driven tests for `EvilEngine.Persistence.MessagePersistenceAdapter`.

  Verifies the message audit + pending-message contract:
  FIFO single-claim drain, correlation scoping, and TTL expiry sweeps.
  """

  use EvilEngine.Persistence.DataCase, async: false

  alias EvilEngine.Persistence.MessagePersistenceAdapter
  alias EvilEngine.Persistence.Resources.Message
  alias EvilEngine.Persistence.Resources.PendingMessage

  describe "insert_message/1" do
    test "persists an append-only audit row" do
      now = DateTime.utc_now()

      params = %{
        message_name: "payment-received",
        payload: %{"amount" => 100},
        correlation_value: "order-42",
        origin: %{"source" => "rest"},
        published_at: now
      }

      assert {:ok, message_id} = MessagePersistenceAdapter.insert_message(params)
      assert {:ok, record} = Ash.get(Message, message_id, authorize?: false)

      assert record.message_name == "payment-received"
      assert record.payload == %{"amount" => 100}
      assert record.correlation_value == "order-42"
      assert record.origin == %{"source" => "rest"}
      assert record.correlations == []
      assert record.started_process_instance_ids == []
    end
  end

  describe "insert_pending_message/1 and find_pending_messages/2" do
    test "buffers a pending row and returns it FIFO by published_at" do
      now = DateTime.utc_now()
      message_id = Ash.UUIDv7.generate()

      older_params = %{
        message_id: message_id,
        message_name: "payment-received",
        correlation_value: "order-42",
        payload: %{"seq" => 1},
        published_at: DateTime.add(now, -10, :second),
        expires_at: DateTime.add(now, 3600, :second),
        state: "pending"
      }

      newer_params = %{
        message_id: message_id,
        message_name: "payment-received",
        correlation_value: "order-42",
        payload: %{"seq" => 2},
        published_at: now,
        expires_at: DateTime.add(now, 3600, :second),
        state: "pending"
      }

      assert {:ok, _older_id} = MessagePersistenceAdapter.insert_pending_message(older_params)
      assert {:ok, _newer_id} = MessagePersistenceAdapter.insert_pending_message(newer_params)

      assert {:ok, [row]} =
               MessagePersistenceAdapter.find_pending_messages("payment-received", "order-42")

      assert row.payload == %{"seq" => 1}
      assert row.state == "pending"
    end

    test "scopes pending lookup by correlation_value — nil matches only nil" do
      now = DateTime.utc_now()
      message_id = Ash.UUIDv7.generate()

      uncorrelated_params = %{
        message_id: message_id,
        message_name: "broadcast-event",
        correlation_value: nil,
        payload: %{"kind" => "broadcast"},
        published_at: now,
        expires_at: DateTime.add(now, 3600, :second),
        state: "pending"
      }

      correlated_params = %{
        message_id: message_id,
        message_name: "broadcast-event",
        correlation_value: "order-99",
        payload: %{"kind" => "targeted"},
        published_at: now,
        expires_at: DateTime.add(now, 3600, :second),
        state: "pending"
      }

      assert {:ok, _} = MessagePersistenceAdapter.insert_pending_message(uncorrelated_params)
      assert {:ok, _} = MessagePersistenceAdapter.insert_pending_message(correlated_params)

      assert {:ok, [nil_match]} =
               MessagePersistenceAdapter.find_pending_messages("broadcast-event", nil)

      assert nil_match.correlation_value == nil
      assert nil_match.payload == %{"kind" => "broadcast"}

      assert {:ok, [correlated_match]} =
               MessagePersistenceAdapter.find_pending_messages("broadcast-event", "order-99")

      assert correlated_match.correlation_value == "order-99"
    end

    test "excludes expired pending rows from find_pending_messages" do
      now = DateTime.utc_now()
      message_id = Ash.UUIDv7.generate()

      expired_params = %{
        message_id: message_id,
        message_name: "late-payment",
        correlation_value: nil,
        payload: %{"stale" => true},
        published_at: DateTime.add(now, -120, :second),
        expires_at: DateTime.add(now, -60, :second),
        state: "pending"
      }

      assert {:ok, _} = MessagePersistenceAdapter.insert_pending_message(expired_params)

      assert {:ok, []} = MessagePersistenceAdapter.find_pending_messages("late-payment", nil)
    end
  end

  describe "mark_pending_delivered/1" do
    test "single-claim: first mark succeeds, second returns already_claimed" do
      now = DateTime.utc_now()

      {:ok, pending_id} =
        MessagePersistenceAdapter.insert_pending_message(%{
          message_id: Ash.UUIDv7.generate(),
          message_name: "payment-received",
          payload: %{},
          published_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: "pending"
        })

      assert :ok = MessagePersistenceAdapter.mark_pending_delivered(pending_id)

      assert {:error, {:already_claimed, _}} =
               MessagePersistenceAdapter.mark_pending_delivered(pending_id)

      assert {:ok, record} = Ash.get(PendingMessage, pending_id, authorize?: false)
      assert record.state == "delivered"
      assert %DateTime{} = record.delivered_at
    end
  end

  describe "expire_pending_messages/0" do
    test "transitions past-TTL pending rows to expired and returns count" do
      now = DateTime.utc_now()
      message_id = Ash.UUIDv7.generate()

      {:ok, expired_id} =
        MessagePersistenceAdapter.insert_pending_message(%{
          message_id: message_id,
          message_name: "ttl-message",
          payload: %{},
          published_at: DateTime.add(now, -120, :second),
          expires_at: DateTime.add(now, -30, :second),
          state: "pending"
        })

      {:ok, active_id} =
        MessagePersistenceAdapter.insert_pending_message(%{
          message_id: message_id,
          message_name: "ttl-message",
          payload: %{},
          published_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: "pending"
        })

      assert {:ok, 1} = MessagePersistenceAdapter.expire_pending_messages()

      assert {:ok, expired_record} = Ash.get(PendingMessage, expired_id, authorize?: false)
      assert expired_record.state == "expired"
      assert %DateTime{} = expired_record.expired_at

      assert {:ok, active_record} = Ash.get(PendingMessage, active_id, authorize?: false)
      assert active_record.state == "pending"
    end

    test "returns {:ok, 0} when no rows are past TTL" do
      now = DateTime.utc_now()

      assert {:ok, _} =
               MessagePersistenceAdapter.insert_pending_message(%{
                 message_id: Ash.UUIDv7.generate(),
                 message_name: "fresh-message",
                 payload: %{},
                 published_at: now,
                 expires_at: DateTime.add(now, 3600, :second),
                 state: "pending"
               })

      assert {:ok, 0} = MessagePersistenceAdapter.expire_pending_messages()
    end
  end

  describe "append_message_correlation/2 and update_started_process_instance_ids/2" do
    test "appends correlation audit entries to the message row" do
      now = DateTime.utc_now()

      {:ok, message_id} =
        MessagePersistenceAdapter.insert_message(%{
          message_name: "payment-received",
          published_at: now
        })

      correlation_entry = %{
        "process_instance_id" => "pi-1",
        "flow_node_instance_id" => "fni-1"
      }

      assert :ok =
               MessagePersistenceAdapter.append_message_correlation(message_id, correlation_entry)

      assert {:ok, record} = Ash.get(Message, message_id, authorize?: false)
      assert record.correlations == [correlation_entry]
    end

    test "updates started_process_instance_ids on the message row" do
      now = DateTime.utc_now()

      {:ok, message_id} =
        MessagePersistenceAdapter.insert_message(%{
          message_name: "start-trigger",
          published_at: now
        })

      started_ids = ["pi-1", "pi-2"]

      assert :ok =
               MessagePersistenceAdapter.update_started_process_instance_ids(
                 message_id,
                 started_ids
               )

      assert {:ok, record} = Ash.get(Message, message_id, authorize?: false)
      assert record.started_process_instance_ids == started_ids
    end
  end
end
