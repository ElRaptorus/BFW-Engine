defmodule BfwEngine.Events.SingleClaimRoutingTest do
  @moduledoc """
  A catch, boundary, or receive subscription consumes exactly one message or
  signal: publishers claim it before delivering, and a registration drains
  at most one pending row, the oldest. Event Subprocess starts are
  persistent and never claimed.
  """
  use ExUnit.Case, async: false

  alias BfwEngine.Events.MessagePublisher
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.ServiceReset
  alias BfwEngine.Events.SignalPublisher
  alias BfwEngine.Events.SignalSubscriptions

  defmodule InMemoryAdapter do
    @moduledoc false

    # Implements the message and signal persistence callbacks the routing code uses.

    def start,
      do: Agent.start_link(fn -> %{pending: [], claimed: [], stale: []} end, name: __MODULE__)

    def pending_ids, do: Agent.get(__MODULE__, fn state -> Enum.map(state.pending, & &1.id) end)

    def claimed_ids, do: Agent.get(__MODULE__, & &1.claimed)

    # Rows another drain takes before this drain marks them: the mark fails and the row is gone.
    def make_stale(ids), do: Agent.update(__MODULE__, &%{&1 | stale: ids})

    def insert_message(_attributes), do: {:ok, "audit"}
    def insert_signal(_attributes), do: {:ok, "audit"}

    def insert_pending_message(attributes) do
      push_pending(%{
        id: "row-" <> attributes.message_id,
        message_id: attributes.message_id,
        message_name: attributes.message_name,
        correlation_value: attributes.correlation_value,
        payload: attributes.payload
      })
    end

    def insert_pending_signal(attributes) do
      push_pending(%{
        id: "row-" <> attributes.signal_id,
        signal_id: attributes.signal_id,
        signal_name: attributes.signal_name
      })
    end

    defp push_pending(row) do
      Agent.update(__MODULE__, fn state -> %{state | pending: state.pending ++ [row]} end)
      {:ok, row.id}
    end

    def find_pending_messages(message_name, correlation_value) do
      {:ok,
       Agent.get(__MODULE__, fn state ->
         Enum.filter(state.pending, fn row ->
           row[:message_name] == message_name and row[:correlation_value] == correlation_value
         end)
       end)}
    end

    def find_pending_signals(signal_name) do
      {:ok,
       Agent.get(__MODULE__, fn state ->
         Enum.filter(state.pending, &(&1[:signal_name] == signal_name))
       end)}
    end

    def mark_pending_delivered(id) do
      Agent.get_and_update(__MODULE__, fn state ->
        cond do
          id in state.stale ->
            {{:error, :already_claimed},
             %{
               state
               | stale: List.delete(state.stale, id),
                 pending: Enum.reject(state.pending, &(&1.id == id))
             }}

          Enum.any?(state.pending, &(&1.id == id)) ->
            {:ok,
             %{
               state
               | pending: Enum.reject(state.pending, &(&1.id == id)),
                 claimed: state.claimed ++ [id]
             }}

          true ->
            {{:error, :already_claimed}, state}
        end
      end)
    end

    def cancel_pending_for_message(_name, _correlation), do: {:ok, 0}
    def cancel_pending_for_signal_name(_name), do: {:ok, 0}
    def append_message_correlation(_message_id, _correlation), do: :ok
    def append_signal_delivery(_signal_id, _delivery), do: :ok
    def update_started_process_instance_ids(_id, _ids), do: :ok
  end

  setup do
    previous = %{
      message: Application.get_env(:core_events, :message_persistence_adapter),
      signal: Application.get_env(:core_events, :signal_persistence_adapter),
      handler: Application.get_env(:core_events, :message_start_event_handler)
    }

    start_supervised!(%{id: InMemoryAdapter, start: {InMemoryAdapter, :start, []}})
    Application.put_env(:core_events, :message_persistence_adapter, InMemoryAdapter)
    Application.put_env(:core_events, :signal_persistence_adapter, InMemoryAdapter)

    on_exit(fn ->
      Application.put_env(:core_events, :message_persistence_adapter, previous.message)
      Application.put_env(:core_events, :signal_persistence_adapter, previous.signal)
      restore_env(:message_start_event_handler, previous.handler)
    end)

    ServiceReset.message_subscriptions()
    ServiceReset.signal_subscriptions()
    MessageSubscriptions.mark_ready()
    SignalSubscriptions.mark_ready()
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:core_events, key)
  defp restore_env(key, value), do: Application.put_env(:core_events, key, value)

  describe "racing live publications" do
    test "a second message for the same waiting catch is not delivered and goes pending" do
      register_message("fni-catch")

      {:ok, first} = MessagePublisher.publish_message(%{name: "order", payload: %{n: 1}})
      {:ok, second} = MessagePublisher.publish_message(%{name: "order", payload: %{n: 2}})

      assert [%{flow_node_instance_id: "fni-catch"}] = first.deliveries
      assert_received {:message_arrived, _message_id, %{n: 1}, nil}

      assert second.deliveries == []
      assert second.pending
      refute_received {:message_arrived, _message_id, %{n: 2}, nil}
    end

    test "a second signal for the same waiting catch is not delivered and goes pending" do
      register_signal("fni-catch")

      {:ok, first} = SignalPublisher.publish_signal(%{name: "go"})
      {:ok, second} = SignalPublisher.publish_signal(%{name: "go"})

      assert [%{flow_node_instance_id: "fni-catch"}] = first.deliveries
      assert second.deliveries == []
      assert second.pending
    end

    test "every distinct waiting catch of a key still receives the message once" do
      register_message("fni-one")
      register_message("fni-two")

      {:ok, result} = MessagePublisher.publish_message(%{name: "order", payload: %{}})

      assert ["fni-one", "fni-two"] ==
               result.deliveries |> Enum.map(& &1.flow_node_instance_id) |> Enum.sort()
    end

    test "an Event Subprocess start subscription is never claimed" do
      register_message("ESP_Start", :event_subprocess_start)
      register_signal("ESP_Start", :event_subprocess_start)

      {:ok, first} = MessagePublisher.publish_message(%{name: "order", payload: %{}})
      {:ok, second} = MessagePublisher.publish_message(%{name: "order", payload: %{}})
      {:ok, _signal} = SignalPublisher.publish_signal(%{name: "go"})
      {:ok, second_signal} = SignalPublisher.publish_signal(%{name: "go"})

      assert length(first.deliveries) == 1
      assert length(second.deliveries) == 1
      assert length(second_signal.deliveries) == 1
      assert [%{kind: :event_subprocess_start}] = MessageSubscriptions.lookup("order", :none)
      assert [%{kind: :event_subprocess_start}] = SignalSubscriptions.lookup("go")
    end

    test "claim/1 succeeds exactly once for a subscription" do
      register_message("fni-catch")
      [subscription] = MessageSubscriptions.lookup("order", :none)

      assert MessageSubscriptions.claim(subscription)
      refute MessageSubscriptions.claim(subscription)
      assert MessageSubscriptions.lookup("order", :none) == []
    end
  end

  describe "pending drain takes one row per registration" do
    test "two catches registering in turn each get one message, oldest first" do
      publish_pending_messages(2)

      register_message("fni-first")
      assert_received {:message_arrived, _id, %{n: 1}, nil}
      refute_received {:message_arrived, _id, %{n: 2}, nil}
      assert length(InMemoryAdapter.pending_ids()) == 1

      register_message("fni-second")
      assert_received {:message_arrived, _id, %{n: 2}, nil}
      assert InMemoryAdapter.pending_ids() == []
    end

    test "one pending row reaches only the first of two registrations" do
      publish_pending_messages(1)

      register_message("fni-first")
      register_message("fni-second")

      assert_received {:message_arrived, _id, %{n: 1}, nil}
      refute_received {:message_arrived, _id, _payload, nil}
    end

    test "a drained one-shot subscription is claimed and leaves the registry" do
      publish_pending_messages(1)

      register_message("fni-first")

      assert MessageSubscriptions.lookup("order", :none) == []
    end

    test "an empty backlog keeps the registration in place" do
      register_message("fni-first")

      assert [%{flow_node_instance_id: "fni-first"}] = MessageSubscriptions.lookup("order", :none)
    end

    test "when every row was taken by another drain the subscription stays registered" do
      publish_pending_messages(1)
      InMemoryAdapter.make_stale(InMemoryAdapter.pending_ids())

      register_message("fni-first")

      refute_received {:message_arrived, _id, _payload, nil}
      assert [%{flow_node_instance_id: "fni-first"}] = MessageSubscriptions.lookup("order", :none)
    end

    test "signals follow the same rule" do
      publish_pending_signals(2)

      register_signal("fni-first")
      assert_received {:signal_arrived, _id, nil}
      assert length(InMemoryAdapter.pending_ids()) == 1

      register_signal("fni-second")
      assert_received {:signal_arrived, _id, nil}
      assert InMemoryAdapter.pending_ids() == []
    end

    test "an Event Subprocess start takes one row per registration and stays registered" do
      publish_pending_messages(2)

      register_message("ESP_Start", :event_subprocess_start)

      assert_received {:event_subprocess_message, "ESP_Start", %{n: 1}}
      refute_received {:event_subprocess_message, "ESP_Start", %{n: 2}}
      assert length(InMemoryAdapter.pending_ids()) == 1
      assert [%{kind: :event_subprocess_start}] = MessageSubscriptions.lookup("order", :none)
    end
  end

  defp publish_pending_messages(count) do
    Application.put_env(:core_events, :message_start_event_handler, nil)

    for number <- 1..count do
      {:ok, result} = MessagePublisher.publish_message(%{name: "order", payload: %{n: number}})
      assert result.pending
    end
  end

  defp publish_pending_signals(count) do
    for _number <- 1..count do
      {:ok, result} = SignalPublisher.publish_signal(%{name: "go"})
      assert result.pending
    end
  end

  defp register_message(flow_node_instance_id, kind \\ :intermediate_catch) do
    {:ok, _subscription_id} =
      MessageSubscriptions.register(%{
        process_instance_id: "pi-routing",
        flow_node_instance_id: flow_node_instance_id,
        flow_node_id: flow_node_instance_id,
        message_name: "order",
        expected_correlation_value: :none,
        kind: kind,
        via_pid: self()
      })
  end

  defp register_signal(flow_node_instance_id, kind \\ :intermediate_catch) do
    {:ok, _subscription_id} =
      SignalSubscriptions.register(%{
        process_instance_id: "pi-routing",
        flow_node_instance_id: flow_node_instance_id,
        flow_node_id: flow_node_instance_id,
        signal_name: "go",
        kind: kind,
        via_pid: self()
      })
  end
end
