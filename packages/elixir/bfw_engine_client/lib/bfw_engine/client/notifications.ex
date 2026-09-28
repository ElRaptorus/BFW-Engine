defmodule BfwEngine.Client.Notifications do
  @moduledoc """
  A Slipstream process delivering real-time Engine events over the
  `/socket/websocket` Phoenix Channel endpoint.

  Start one process per identity (service token or per-user token) and
  `subscribe/2` or `subscribe/3` to as many topics as needed — `"engine:events"`,
  `"user_tasks:pending"`, or `"process_instance:<id>"`. Topic joins are
  reference-counted: the underlying Phoenix Channel is joined once per
  topic on the first subscriber and left once the last subscriber for that
  topic goes away (including via process death, tracked with
  `Process.monitor/1`).

  ## Starting

      {:ok, notifications} =
        BfwEngine.Client.Notifications.start_link(
          client: BfwEngine.Client.new(base_url: "http://localhost:4100", token: "eyJ...")
        )

  `:client` may also be an MFA tuple `{module, function, arguments}`,
  resolved every time a connection is (re-)established so the token stays
  fresh:

      {:ok, notifications} =
        BfwEngine.Client.Notifications.start_link(
          client: {MyApp.Engine, :client, []}
        )

  ## Subscribing

      :ok = BfwEngine.Client.Notifications.subscribe(notifications, "process_instance:\#{process_instance_id}")

  Every delivered event arrives as a message to the subscriber process:

      receive do
        {:bfw_engine_event, topic, %{"type" => type, "data" => data, "occurredAt" => occurred_at}} ->
          ...
      end

  A join the Engine rejects (or a channel the Engine later closes) is
  reported the same way, so subscribers do not need to poll or await:

      receive do
        {:bfw_engine_subscription_error, topic, reason} -> ...
      end

  The token is only ever placed in the `Authorization` header sent by the
  resolved `BfwEngine.Client` and in the socket handshake's `token` query
  parameter — it is never logged.
  """

  use Slipstream

  alias BfwEngine.Client

  @engine_event_name "engine_event"
  @websocket_protocol_version "2.0.0"
  @reconnect_delay_milliseconds 1_000
  @default_subscribe_timeout 5_000

  @typedoc """
  Either a resolved client, or an MFA tuple resolved to one at every
  connection attempt.
  """
  @type client_resolver :: Client.t() | {module(), atom(), [term()]}

  @doc """
  Starts the Notifications process.

  ## Options

    * `:client` (required) - a `t:BfwEngine.Client.t/0`, or an
      `{module, function, arguments}` tuple resolved on every connection
      attempt.
    * `:name` - an optional `GenServer` name.
    * `:test_mode?` - forwarded to `Slipstream.connect/2` on every
      connection attempt. See `Slipstream.SocketTest`. Defaults to `false`.
    * `:reconnect_delay_milliseconds` - delay before a fixed-delay
      reconnect attempt after a disconnect. Defaults to `1_000`; tests can
      lower this to avoid waiting on the real timer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, init_options} = Keyword.pop(options, :name)
    genserver_options = if name, do: [name: name], else: []
    Slipstream.start_link(__MODULE__, init_options, genserver_options)
  end

  @doc """
  Subscribes the calling process to `topic`.

  Joins the underlying Phoenix Channel topic if this is the first
  subscriber. Every caller that arrives while that join is still in
  flight, or while the socket is still connecting, waits for the same
  result. The call returns `:ok` after the join succeeds, or after a
  rejection has already been delivered as
  `{:bfw_engine_subscription_error, topic, reason}`. Idempotent for a
  subscriber already subscribed to `topic`, and immediate when the
  topic is already joined.

  While the socket is disconnected the call returns
  `{:error, :disconnected}` at once. `timeout` bounds the wait and
  defaults to 5000 milliseconds.
  """
  @spec subscribe(GenServer.server(), String.t(), timeout()) ::
          :ok | {:error, :disconnected}
  def subscribe(notifications, topic, timeout \\ @default_subscribe_timeout)

  def subscribe(notifications, topic, timeout) when is_binary(topic) do
    GenServer.call(notifications, {:subscribe, self(), topic}, timeout)
  end

  @doc """
  Unsubscribes the calling process from `topic`.

  Leaves the underlying Phoenix Channel topic once the last subscriber for
  it is gone.
  """
  @spec unsubscribe(GenServer.server(), String.t()) :: :ok
  def unsubscribe(notifications, topic) when is_binary(topic) do
    GenServer.call(notifications, {:unsubscribe, self(), topic})
  end

  @impl Slipstream
  def init(options) do
    client_resolver = Keyword.fetch!(options, :client)
    test_mode? = Keyword.get(options, :test_mode?, false)

    reconnect_delay_milliseconds =
      Keyword.get(options, :reconnect_delay_milliseconds, @reconnect_delay_milliseconds)

    socket =
      new_socket()
      |> assign(:client_resolver, client_resolver)
      |> assign(:test_mode?, test_mode?)
      |> assign(:reconnect_delay_milliseconds, reconnect_delay_milliseconds)
      |> assign(:connection, :connecting)
      |> assign(:topics, %{})
      |> assign(:pending_joins, %{})
      |> assign(:rejoining, MapSet.new())

    case connect_with_fresh_client(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    socket =
      socket
      |> assign(:connection, :connected)
      |> then(fn connected_socket ->
        Enum.reduce(Map.keys(connected_socket.assigns.topics), connected_socket, &join(&2, &1))
      end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    # ponytail: fixed-delay reconnect, not the exponential backoff Slipstream's
    # own `reconnect/1` provides — acceptable ceiling for a client library
    # whose host application can restart the process if reconnection is slow.
    Process.send_after(
      self(),
      :reconnect_with_fresh_client,
      socket.assigns.reconnect_delay_milliseconds
    )

    socket =
      socket
      |> assign(:connection, :disconnected)
      |> fail_pending_joins()

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    socket =
      socket
      |> reply_pending_join(topic)
      |> clear_rejoin(topic)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_topic_close(_topic, :left, socket), do: {:ok, socket}

  def handle_topic_close(topic, reason, socket) do
    cond do
      Map.has_key?(socket.assigns.pending_joins, topic) ->
        notify_subscribers(socket, topic, {:bfw_engine_subscription_error, topic, reason})
        {:ok, reply_pending_join(socket, topic)}

      MapSet.member?(socket.assigns.rejoining, topic) ->
        notify_subscribers(socket, topic, {:bfw_engine_subscription_error, topic, reason})
        {:ok, drop_topic(socket, topic)}

      true ->
        socket = assign(socket, :rejoining, MapSet.put(socket.assigns.rejoining, topic))
        {:ok, join(socket, topic)}
    end
  end

  @impl Slipstream
  def handle_message(topic, @engine_event_name, envelope, socket) do
    notify_subscribers(socket, topic, {:bfw_engine_event, topic, envelope})
    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_call({:subscribe, subscriber_pid, topic}, from, socket) do
    if socket.assigns.connection == :disconnected do
      {:reply, {:error, :disconnected}, socket}
    else
      subscribe_while_available(subscriber_pid, topic, from, socket)
    end
  end

  def handle_call({:unsubscribe, subscriber_pid, topic}, _from, socket) do
    subscribers = Map.get(socket.assigns.topics, topic, %{})

    socket =
      case Map.pop(subscribers, subscriber_pid) do
        {nil, _subscribers} ->
          socket

        {monitor_reference, remaining_subscribers} ->
          Process.demonitor(monitor_reference, [:flush])
          remove_or_update_topic(socket, topic, remaining_subscribers)
      end

    {:reply, :ok, socket}
  end

  @impl Slipstream
  def handle_info(:reconnect_with_fresh_client, socket) do
    socket = assign(socket, :connection, :connecting)

    case connect_with_fresh_client(socket) do
      {:ok, socket} -> {:noreply, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  def handle_info({:DOWN, monitor_reference, :process, subscriber, _reason}, socket) do
    socket =
      socket.assigns.topics
      |> Enum.filter(fn {_topic, subscribers} ->
        Map.get(subscribers, subscriber) == monitor_reference
      end)
      |> Enum.reduce(socket, fn {topic, subscribers}, socket ->
        remove_or_update_topic(socket, topic, Map.delete(subscribers, subscriber))
      end)

    {:noreply, socket}
  end

  defp subscribe_while_available(subscriber_pid, topic, from, socket) do
    subscribers = Map.get(socket.assigns.topics, topic, %{})
    already_tracking? = Map.has_key?(subscribers, subscriber_pid)
    joined? = join_status(socket, topic) == :joined
    join_in_flight? = Map.has_key?(socket.assigns.pending_joins, topic)

    socket =
      if already_tracking? do
        socket
      else
        monitor_reference = Process.monitor(subscriber_pid)
        subscribers = Map.put(subscribers, subscriber_pid, monitor_reference)
        put_topic_subscribers(socket, topic, subscribers)
      end

    cond do
      already_tracking? or joined? ->
        {:reply, :ok, socket}

      join_in_flight? or socket.assigns.connection == :connecting ->
        {:noreply, put_pending_join(socket, topic, from)}

      true ->
        {:noreply, join(put_pending_join(socket, topic, from), topic)}
    end
  end

  defp fail_pending_joins(socket) do
    Enum.each(socket.assigns.pending_joins, fn {_topic, waiters} ->
      Enum.each(waiters, &GenServer.reply(&1, {:error, :disconnected}))
    end)

    socket.assigns.pending_joins
    |> Map.keys()
    |> Enum.reduce(socket, fn topic, socket ->
      if join_status(socket, topic) == :joined, do: socket, else: drop_topic(socket, topic)
    end)
    |> assign(:pending_joins, %{})
  end

  defp drop_topic(socket, topic) do
    {subscribers, topics} = Map.pop(socket.assigns.topics, topic, %{})

    Enum.each(subscribers, fn {_subscriber_pid, monitor_reference} ->
      Process.demonitor(monitor_reference, [:flush])
    end)

    socket
    |> assign(:topics, topics)
    |> assign(:rejoining, MapSet.delete(socket.assigns.rejoining, topic))
  end

  defp put_pending_join(socket, topic, from) do
    pending_joins =
      Map.update(socket.assigns.pending_joins, topic, [from], fn waiters ->
        [from | waiters]
      end)

    assign(socket, :pending_joins, pending_joins)
  end

  defp reply_pending_join(socket, topic) do
    {waiters, pending_joins} = Map.pop(socket.assigns.pending_joins, topic, [])

    Enum.each(waiters, &GenServer.reply(&1, :ok))

    assign(socket, :pending_joins, pending_joins)
  end

  defp clear_rejoin(socket, topic) do
    assign(socket, :rejoining, MapSet.delete(socket.assigns.rejoining, topic))
  end

  defp put_topic_subscribers(socket, topic, subscribers) do
    assign(socket, :topics, Map.put(socket.assigns.topics, topic, subscribers))
  end

  defp remove_or_update_topic(socket, topic, subscribers) when map_size(subscribers) == 0 do
    socket
    |> assign(:topics, Map.delete(socket.assigns.topics, topic))
    |> leave(topic)
  end

  defp remove_or_update_topic(socket, topic, subscribers) do
    put_topic_subscribers(socket, topic, subscribers)
  end

  defp notify_subscribers(socket, topic, message) do
    socket.assigns.topics
    |> Map.get(topic, %{})
    |> Map.keys()
    |> Enum.each(&send(&1, message))

    socket
  end

  defp connect_with_fresh_client(socket) do
    client = resolve_client(socket.assigns.client_resolver)
    connect(socket, uri: websocket_uri(client), test_mode?: socket.assigns.test_mode?)
  end

  defp resolve_client(%Client{} = client), do: client
  defp resolve_client({module, function, arguments}), do: apply(module, function, arguments)

  defp websocket_uri(%Client{base_url: base_url, token: token}) do
    query =
      URI.encode_query(%{"token" => resolve_token(token), "vsn" => @websocket_protocol_version})

    String.replace(base_url, ~r/^http/, "ws") <> "/socket/websocket?" <> query
  end

  defp resolve_token(nil), do: ""
  defp resolve_token(token) when is_binary(token), do: token
  defp resolve_token(token) when is_function(token, 0), do: token.()
end
