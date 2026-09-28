defmodule BfwEngine.Client.NotificationsTest do
  use Slipstream.SocketTest, async: false

  alias BfwEngine.Client
  alias BfwEngine.Client.Notifications

  @client Client.new(base_url: "http://engine.invalid", token: "test-token")

  defp start_client(opts \\ []) do
    options =
      Keyword.merge(
        [client: @client, test_mode?: true, reconnect_delay_milliseconds: 0],
        opts
      )

    start_supervised!({Notifications, options})
  end

  defp spawn_subscriber(notifications, topic) do
    parent = self()

    spawn(fn ->
      :ok = Notifications.subscribe(notifications, topic)
      send(parent, {:subscribed, self()})

      receive do
        :stop -> :ok
      end
    end)
  end

  defp await_subscribed(pid) do
    assert_receive {:subscribed, ^pid}
    pid
  end

  defp await_pending_waiters(notifications, topic, expected_count) do
    Enum.reduce_while(1..50, 0, fn _attempt, _last_count ->
      count = pending_waiter_count(notifications, topic)

      if count == expected_count do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, count}
      end
    end)
  end

  defp pending_waiter_count(notifications, topic) do
    %{assigns: %{pending_joins: pending_joins}} = :sys.get_state(notifications)
    length(Map.get(pending_joins, topic, []))
  end

  test "joins the topic on the first subscribe" do
    notifications = start_client()
    accept_connect(notifications)

    task = Task.async(fn -> Notifications.subscribe(notifications, "engine:events") end)
    assert_join("engine:events", %{}, :ok)
    assert Task.await(task) == :ok
  end

  test "a second subscriber waits until the in-flight join completes" do
    notifications = start_client()
    accept_connect(notifications)

    first = Task.async(fn -> Notifications.subscribe(notifications, "engine:events") end)

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{
                      socket: slipstream_socket,
                      topic: "engine:events"
                    }}

    second = Task.async(fn -> Notifications.subscribe(notifications, "engine:events") end)
    assert await_pending_waiters(notifications, "engine:events", 2) == :ok
    assert Task.yield(first, 0) == nil
    assert Task.yield(second, 0) == nil

    join_event = Map.put(Slipstream.SocketTest.__map_join_reply__(:ok), :topic, "engine:events")

    send(slipstream_socket.socket_pid, {:__slipstream_event__, join_event})

    assert Task.await(first) == :ok
    assert Task.await(second) == :ok
    refute_join("engine:events", %{}, 200)
  end

  test "joins a topic only once for two subscribers" do
    notifications = start_client()
    accept_connect(notifications)

    subscriber_one = spawn_subscriber(notifications, "user_tasks:pending")
    assert_join("user_tasks:pending", %{}, :ok)
    await_subscribed(subscriber_one)

    subscriber_two = spawn_subscriber(notifications, "user_tasks:pending")
    await_subscribed(subscriber_two)
    refute_join("user_tasks:pending", %{}, 200)

    send(subscriber_one, :stop)
    send(subscriber_two, :stop)
  end

  test "leaves the topic after the last unsubscribe" do
    notifications = start_client()
    accept_connect(notifications)

    subscriber = spawn_subscriber(notifications, "engine:events")
    assert_join("engine:events", %{}, :ok)
    await_subscribed(subscriber)

    :ok = Notifications.subscribe(notifications, "engine:events")
    refute_join("engine:events", %{}, 200)

    :ok = Notifications.unsubscribe(notifications, "engine:events")
    refute_leave("engine:events", 200)

    send(subscriber, :stop)
    assert_leave("engine:events")
  end

  test "leaves the topic when the only subscriber's process exits" do
    notifications = start_client()
    accept_connect(notifications)

    subscriber = spawn_subscriber(notifications, "process_instance:pi-1")
    assert_join("process_instance:pi-1", %{}, :ok)
    await_subscribed(subscriber)

    Process.exit(subscriber, :kill)
    assert_leave("process_instance:pi-1")
  end

  test "fans out engine events to subscribers" do
    notifications = start_client()
    accept_connect(notifications)
    parent = self()

    subscriber =
      spawn(fn ->
        :ok = Notifications.subscribe(notifications, "engine:events")
        send(parent, {:subscribed, self()})

        receive do
          {:bfw_engine_event, topic, envelope} ->
            send(parent, {:forwarded, topic, envelope})
        end
      end)

    assert_join("engine:events", %{}, :ok)
    await_subscribed(subscriber)

    envelope = %{"type" => "ProcessInstanceStateChanged", "data" => %{}, "occurredAt" => "now"}
    push(notifications, "engine:events", "engine_event", envelope)

    assert_receive {:forwarded, "engine:events", ^envelope}
  end

  test "delivers a subscription error when the join is rejected" do
    notifications = start_client()
    accept_connect(notifications)
    parent = self()

    task =
      Task.async(fn ->
        :ok = Notifications.subscribe(notifications, "engine:events")

        receive do
          {:bfw_engine_subscription_error, topic, reason} ->
            send(parent, {:error_seen, topic, reason})
            :ok
        after
          1_000 -> :missing
        end
      end)

    assert_join("engine:events", %{}, {:error, %{"reason" => "unauthorized"}})
    assert Task.await(task) == :ok
    assert_receive {:error_seen, "engine:events", _reason}
  end

  test "rejoins all subscribed topics after a reconnect" do
    notifications = start_client()
    accept_connect(notifications)

    subscriber = spawn_subscriber(notifications, "engine:events")
    assert_join("engine:events", %{}, :ok)
    await_subscribed(subscriber)

    disconnect(notifications, :closed_by_remote)
    accept_connect(notifications)

    assert_join("engine:events", %{}, :ok)
    send(subscriber, :stop)
  end

  test "rejoins once when a joined topic closes unexpectedly" do
    notifications = start_client()
    accept_connect(notifications)
    parent = self()

    subscriber =
      spawn(fn ->
        :ok = Notifications.subscribe(notifications, "engine:events")
        send(parent, {:subscribed, self()})

        receive do
          {:bfw_engine_subscription_error, topic, reason} ->
            send(parent, {:error_seen, topic, reason})

          :stop ->
            :ok
        end
      end)

    assert_join("engine:events", %{}, :ok)
    await_subscribed(subscriber)

    send_topic_close(notifications, "engine:events")

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{topic: "engine:events"}}

    send_topic_close(notifications, "engine:events")
    refute_join("engine:events", %{}, 200)
    assert_receive {:error_seen, "engine:events", _reason}
  end

  test "subscribe waits while the socket is still connecting" do
    notifications = start_client()
    task = Task.async(fn -> Notifications.subscribe(notifications, "engine:events", 2_000) end)

    assert Task.yield(task, 50) == nil

    accept_connect(notifications)
    assert_join("engine:events", %{}, :ok)
    assert Task.await(task) == :ok
  end

  test "subscribe returns disconnected immediately after the socket drops" do
    notifications = start_client(reconnect_delay_milliseconds: 60_000)
    accept_connect(notifications)
    disconnect(notifications, :closed_by_remote)
    assert await_connection(notifications, :disconnected) == :ok

    assert {:error, :disconnected} =
             Notifications.subscribe(notifications, "engine:events", 200)
  end

  test "disconnect fails joins that are still in flight" do
    notifications = start_client()
    accept_connect(notifications)

    task = Task.async(fn -> Notifications.subscribe(notifications, "engine:events", 2_000) end)

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{topic: "engine:events"}}

    disconnect(notifications, :closed_by_remote)
    assert Task.await(task) == {:error, :disconnected}
  end

  test "a rejected rejoin drops the topic so the same subscriber can join again" do
    notifications = start_client()
    accept_connect(notifications)
    parent = self()

    subscriber =
      spawn(fn ->
        :ok = Notifications.subscribe(notifications, "engine:events")
        send(parent, {:subscribed, self()})

        receive do
          {:bfw_engine_subscription_error, topic, reason} ->
            send(parent, {:error_seen, topic, reason})

            receive do
              :resubscribe ->
                result = Notifications.subscribe(notifications, "engine:events")
                send(parent, {:resubscribed, result})
            end
        end
      end)

    assert_join("engine:events", %{}, :ok)
    await_subscribed(subscriber)

    send_topic_close(notifications, "engine:events")

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{topic: "engine:events"}}

    send_topic_close(notifications, "engine:events")
    assert_receive {:error_seen, "engine:events", _reason}
    refute notifications in (Process.info(subscriber, :monitored_by) |> elem(1))

    send(subscriber, :resubscribe)
    assert_join("engine:events", %{}, :ok)
    assert_receive {:resubscribed, :ok}
  end

  defp await_connection(notifications, expected) do
    Enum.reduce_while(1..50, nil, fn _attempt, _last ->
      %{assigns: %{connection: connection}} = :sys.get_state(notifications)

      if connection == expected do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, connection}
      end
    end)
  end

  defp send_topic_close(notifications, topic) do
    send(
      notifications,
      {:__slipstream_event__,
       %Slipstream.Events.TopicJoinClosed{
         topic: topic,
         reason: {:error, %{"reason" => "crash"}},
         ref: nil
       }}
    )
  end
end
