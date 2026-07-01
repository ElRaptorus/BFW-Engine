defmodule IncidentReporter.MessageBus.InMemoryAdapter do
  @moduledoc """
  In-memory implementation of `IncidentReporter.MessageBus.Adapter` for tests.

  Uses an Agent to store published messages and subscriber registrations.
  No real broker is needed. Messages published via `publish/3` are stored
  and can be retrieved with `get_published/1`. Messages injected via
  `inject/3` are delivered to registered subscribers.
  """

  @behaviour IncidentReporter.MessageBus.Adapter

  use Agent

  @doc """
  Start the in-memory adapter's backing Agent.

  Returns `{:ok, pid}`. The pid doubles as the "connection" handle
  passed to all other callbacks.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    Agent.start_link(
      fn -> %{published: [], subscribers: %{}} end,
      name: name
    )
  end

  @impl true
  def connect(_opts) do
    start_link()
  end

  @impl true
  def publish(connection, exchange, payload) when is_binary(payload) do
    Agent.update(connection, fn state ->
      %{state | published: [{exchange, payload} | state.published]}
    end)
  end

  @impl true
  def subscribe(connection, queue, subscriber) do
    Agent.update(connection, fn state ->
      current_subscribers = Map.get(state.subscribers, queue, [])

      %{
        state
        | subscribers: Map.put(state.subscribers, queue, [subscriber | current_subscribers])
      }
    end)
  end

  @impl true
  def disconnect(connection) do
    Agent.stop(connection, :normal)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Retrieve all messages published to a given exchange.

  Returns a list of `{exchange, payload}` tuples in reverse chronological
  order (most recent first).
  """
  @spec get_published(pid()) :: [{String.t(), binary()}]
  def get_published(connection) do
    Agent.get(connection, fn state -> state.published end)
  end

  @doc """
  Retrieve only messages published to a specific exchange.
  """
  @spec get_published(pid(), String.t()) :: [binary()]
  def get_published(connection, exchange) do
    Agent.get(connection, fn state ->
      state.published
      |> Enum.filter(fn {stored_exchange, _payload} -> stored_exchange == exchange end)
      |> Enum.map(fn {_exchange, payload} -> payload end)
    end)
  end

  @doc """
  Inject a message into the adapter as if it arrived from the bus.

  Delivers `{:bus_message, payload}` to all subscribers registered on
  the given queue.
  """
  @spec inject(pid(), String.t(), binary()) :: :ok
  def inject(connection, queue, payload) when is_binary(payload) do
    subscribers =
      Agent.get(connection, fn state ->
        Map.get(state.subscribers, queue, [])
      end)

    Enum.each(subscribers, fn subscriber_pid ->
      send(subscriber_pid, {:bus_message, payload})
    end)

    :ok
  end

  @doc """
  Clear all published messages (useful between test cases).
  """
  @spec clear(pid()) :: :ok
  def clear(connection) do
    Agent.update(connection, fn state -> %{state | published: []} end)
  end
end
