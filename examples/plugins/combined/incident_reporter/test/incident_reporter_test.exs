defmodule IncidentReporter.EventSinkTest do
  @moduledoc """
  Unit tests for the IncidentReporter.EventSink module.

  Uses the InMemoryAdapter to verify incident publication without a real
  message broker.
  """

  use ExUnit.Case, async: true

  alias BfwEngine.Types.Event
  alias IncidentReporter.EventSink
  alias IncidentReporter.MessageBus.InMemoryAdapter

  defp build_state_changed_event(overrides) do
    Map.merge(
      %Event.ProcessInstanceStateChanged{
        process_instance_id: "pi-#{System.unique_integer([:positive])}",
        process_model_id: "TestProcess",
        version: "1.0.0",
        parent_process_instance_id: nil,
        old_state: :running,
        new_state: :fatal,
        occurred_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "accepts?/1" do
    test "accepts ProcessInstanceStateChanged with new_state :fatal" do
      event = build_state_changed_event(%{new_state: :fatal})
      assert EventSink.accepts?(event)
    end

    test "accepts ProcessInstanceStateChanged with new_state :aborted" do
      event = build_state_changed_event(%{new_state: :aborted})
      assert EventSink.accepts?(event)
    end

    test "rejects ProcessInstanceStateChanged with new_state :running" do
      event = build_state_changed_event(%{new_state: :running})
      refute EventSink.accepts?(event)
    end

    test "rejects ProcessInstanceStateChanged with new_state :finished" do
      event = build_state_changed_event(%{new_state: :finished})
      refute EventSink.accepts?(event)
    end

    test "rejects unrelated event structs" do
      event = %Event.EngineStarted{engine_id: "test", started_at: DateTime.utc_now()}
      refute EventSink.accepts?(event)
    end
  end

  describe "init/1" do
    test "initializes state with required options" do
      {:ok, connection} = InMemoryAdapter.start_link()

      assert {:ok, state} =
               EventSink.init(
                 message_bus_adapter: InMemoryAdapter,
                 connection: connection,
                 publish_exchange: "test.incidents"
               )

      assert state.message_bus_adapter == InMemoryAdapter
      assert state.connection == connection
      assert state.publish_exchange == "test.incidents"
      assert state.incidents_published == 0

      InMemoryAdapter.disconnect(connection)
    end

    test "raises on missing required options" do
      assert_raise KeyError, fn ->
        EventSink.init(message_bus_adapter: InMemoryAdapter)
      end
    end
  end

  describe "handle_event/2 — incident publication" do
    setup do
      {:ok, connection} = InMemoryAdapter.start_link()

      {:ok, sink_state} =
        EventSink.init(
          message_bus_adapter: InMemoryAdapter,
          connection: connection,
          publish_exchange: "test.incidents"
        )

      %{connection: connection, sink_state: sink_state}
    end

    test "publishes a JSON incident for a fatal PI", %{
      connection: connection,
      sink_state: sink_state
    } do
      event =
        build_state_changed_event(%{
          process_instance_id: "pi-fatal-123",
          process_model_id: "OrderProcess",
          version: "2.0.0",
          parent_process_instance_id: "pi-parent-456",
          old_state: :running,
          new_state: :fatal
        })

      assert {:ok, updated_state} = EventSink.handle_event(event, sink_state)
      assert updated_state.incidents_published == 1

      published = InMemoryAdapter.get_published(connection, "test.incidents")
      assert length(published) == 1

      incident = Jason.decode!(hd(published))
      assert incident["type"] == "incident"
      assert incident["processInstanceId"] == "pi-fatal-123"
      assert incident["processModelId"] == "OrderProcess"
      assert incident["version"] == "2.0.0"
      assert incident["parentProcessInstanceId"] == "pi-parent-456"
      assert incident["previousState"] == "running"
      assert incident["newState"] == "fatal"
      assert is_binary(incident["occurredAt"])

      InMemoryAdapter.disconnect(connection)
    end

    test "publishes a JSON incident for an aborted PI", %{
      connection: connection,
      sink_state: sink_state
    } do
      event =
        build_state_changed_event(%{
          process_instance_id: "pi-aborted-789",
          old_state: :running,
          new_state: :aborted
        })

      assert {:ok, updated_state} = EventSink.handle_event(event, sink_state)
      assert updated_state.incidents_published == 1

      published = InMemoryAdapter.get_published(connection, "test.incidents")
      assert length(published) == 1

      incident = Jason.decode!(hd(published))
      assert incident["newState"] == "aborted"
      assert incident["processInstanceId"] == "pi-aborted-789"

      InMemoryAdapter.disconnect(connection)
    end

    test "increments counter across multiple incidents", %{
      connection: connection,
      sink_state: sink_state
    } do
      event1 = build_state_changed_event(%{new_state: :fatal})
      event2 = build_state_changed_event(%{new_state: :aborted})

      {:ok, state_after_first} = EventSink.handle_event(event1, sink_state)
      {:ok, state_after_second} = EventSink.handle_event(event2, state_after_first)

      assert state_after_second.incidents_published == 2
      assert length(InMemoryAdapter.get_published(connection, "test.incidents")) == 2

      InMemoryAdapter.disconnect(connection)
    end

    test "handles null parent_process_instance_id", %{
      connection: connection,
      sink_state: sink_state
    } do
      event =
        build_state_changed_event(%{
          parent_process_instance_id: nil,
          new_state: :fatal
        })

      {:ok, _state} = EventSink.handle_event(event, sink_state)

      published = InMemoryAdapter.get_published(connection, "test.incidents")
      incident = Jason.decode!(hd(published))
      assert is_nil(incident["parentProcessInstanceId"])

      InMemoryAdapter.disconnect(connection)
    end
  end

  describe "handle_shutdown/1" do
    test "returns :ok" do
      assert :ok = EventSink.handle_shutdown(%{incidents_published: 42})
    end
  end
end
