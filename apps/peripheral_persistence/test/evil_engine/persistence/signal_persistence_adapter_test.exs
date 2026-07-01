defmodule EvilEngine.Persistence.SignalPersistenceAdapterTest do
  @moduledoc """
  Specification-driven tests for `EvilEngine.Persistence.SignalPersistenceAdapter`.

  Verifies the signal audit + pending-signal contract:
  broadcast by signal name, FIFO single-claim drain, and TTL expiry sweeps.
  Signals carry no payload and no correlation value.
  """

  use EvilEngine.Persistence.DataCase, async: false

  alias EvilEngine.Persistence.Resources.PendingSignal
  alias EvilEngine.Persistence.Resources.Signal
  alias EvilEngine.Persistence.SignalPersistenceAdapter

  describe "insert_signal/1" do
    test "persists an append-only audit row without payload" do
      now = DateTime.utc_now()

      params = %{
        signal_name: "shipment-ready",
        origin: %{"source" => "plugin:metrics"},
        published_at: now
      }

      assert {:ok, signal_id} = SignalPersistenceAdapter.insert_signal(params)
      assert {:ok, record} = Ash.get(Signal, signal_id, authorize?: false)

      assert record.signal_name == "shipment-ready"
      assert record.origin == %{"source" => "plugin:metrics"}
      assert record.deliveries == []
      assert record.started_process_instance_ids == []
    end
  end

  describe "insert_pending_signal/1 and find_pending_signals/1" do
    test "buffers a pending row and returns it FIFO by published_at" do
      now = DateTime.utc_now()
      signal_id = Ash.UUIDv7.generate()

      older_params = %{
        signal_id: signal_id,
        signal_name: "shipment-ready",
        published_at: DateTime.add(now, -10, :second),
        expires_at: DateTime.add(now, 3600, :second),
        state: "pending"
      }

      newer_params = %{
        signal_id: signal_id,
        signal_name: "shipment-ready",
        published_at: now,
        expires_at: DateTime.add(now, 3600, :second),
        state: "pending"
      }

      assert {:ok, _older_id} = SignalPersistenceAdapter.insert_pending_signal(older_params)
      assert {:ok, _newer_id} = SignalPersistenceAdapter.insert_pending_signal(newer_params)

      assert {:ok, [row]} = SignalPersistenceAdapter.find_pending_signals("shipment-ready")
      assert row.signal_name == "shipment-ready"
      assert row.state == "pending"
      assert DateTime.compare(row.published_at, now) == :lt
    end

    test "scopes lookup to the requested signal_name" do
      now = DateTime.utc_now()

      assert {:ok, _} =
               SignalPersistenceAdapter.insert_pending_signal(%{
                 signal_id: Ash.UUIDv7.generate(),
                 signal_name: "signal-a",
                 published_at: now,
                 expires_at: DateTime.add(now, 3600, :second),
                 state: "pending"
               })

      assert {:ok, _} =
               SignalPersistenceAdapter.insert_pending_signal(%{
                 signal_id: Ash.UUIDv7.generate(),
                 signal_name: "signal-b",
                 published_at: now,
                 expires_at: DateTime.add(now, 3600, :second),
                 state: "pending"
               })

      assert {:ok, [row]} = SignalPersistenceAdapter.find_pending_signals("signal-a")
      assert row.signal_name == "signal-a"
    end

    test "excludes expired pending rows from find_pending_signals" do
      now = DateTime.utc_now()

      assert {:ok, _} =
               SignalPersistenceAdapter.insert_pending_signal(%{
                 signal_id: Ash.UUIDv7.generate(),
                 signal_name: "stale-signal",
                 published_at: DateTime.add(now, -120, :second),
                 expires_at: DateTime.add(now, -60, :second),
                 state: "pending"
               })

      assert {:ok, []} = SignalPersistenceAdapter.find_pending_signals("stale-signal")
    end
  end

  describe "mark_pending_delivered/1" do
    test "single-claim: first mark succeeds, second returns already_claimed" do
      now = DateTime.utc_now()

      {:ok, pending_id} =
        SignalPersistenceAdapter.insert_pending_signal(%{
          signal_id: Ash.UUIDv7.generate(),
          signal_name: "shipment-ready",
          published_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: "pending"
        })

      assert :ok = SignalPersistenceAdapter.mark_pending_delivered(pending_id)

      assert {:error, {:already_claimed, _}} =
               SignalPersistenceAdapter.mark_pending_delivered(pending_id)

      assert {:ok, record} = Ash.get(PendingSignal, pending_id, authorize?: false)
      assert record.state == "delivered"
      assert %DateTime{} = record.delivered_at
    end
  end

  describe "expire_pending_signals/0" do
    test "transitions past-TTL pending rows to expired and returns count" do
      now = DateTime.utc_now()
      signal_id = Ash.UUIDv7.generate()

      {:ok, expired_id} =
        SignalPersistenceAdapter.insert_pending_signal(%{
          signal_id: signal_id,
          signal_name: "ttl-signal",
          published_at: DateTime.add(now, -120, :second),
          expires_at: DateTime.add(now, -30, :second),
          state: "pending"
        })

      {:ok, active_id} =
        SignalPersistenceAdapter.insert_pending_signal(%{
          signal_id: signal_id,
          signal_name: "ttl-signal",
          published_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: "pending"
        })

      assert {:ok, 1} = SignalPersistenceAdapter.expire_pending_signals()

      assert {:ok, expired_record} = Ash.get(PendingSignal, expired_id, authorize?: false)
      assert expired_record.state == "expired"
      assert %DateTime{} = expired_record.expired_at

      assert {:ok, active_record} = Ash.get(PendingSignal, active_id, authorize?: false)
      assert active_record.state == "pending"
    end

    test "returns {:ok, 0} when no rows are past TTL" do
      now = DateTime.utc_now()

      assert {:ok, _} =
               SignalPersistenceAdapter.insert_pending_signal(%{
                 signal_id: Ash.UUIDv7.generate(),
                 signal_name: "fresh-signal",
                 published_at: now,
                 expires_at: DateTime.add(now, 3600, :second),
                 state: "pending"
               })

      assert {:ok, 0} = SignalPersistenceAdapter.expire_pending_signals()
    end
  end

  describe "append_signal_delivery/2 and update_started_process_instance_ids/2" do
    test "appends delivery audit entries to the signal row" do
      now = DateTime.utc_now()

      {:ok, signal_id} =
        SignalPersistenceAdapter.insert_signal(%{
          signal_name: "shipment-ready",
          published_at: now
        })

      delivery_entry = %{
        "process_instance_id" => "pi-1",
        "flow_node_instance_id" => "fni-1"
      }

      assert :ok = SignalPersistenceAdapter.append_signal_delivery(signal_id, delivery_entry)

      assert {:ok, record} = Ash.get(Signal, signal_id, authorize?: false)
      assert record.deliveries == [delivery_entry]
    end

    test "updates started_process_instance_ids on the signal row" do
      now = DateTime.utc_now()

      {:ok, signal_id} =
        SignalPersistenceAdapter.insert_signal(%{
          signal_name: "start-trigger",
          published_at: now
        })

      started_ids = ["pi-1", "pi-2"]

      assert :ok =
               SignalPersistenceAdapter.update_started_process_instance_ids(
                 signal_id,
                 started_ids
               )

      assert {:ok, record} = Ash.get(Signal, signal_id, authorize?: false)
      assert record.started_process_instance_ids == started_ids
    end
  end
end
