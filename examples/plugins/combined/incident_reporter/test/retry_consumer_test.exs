defmodule IncidentReporter.RetryConsumerTest do
  @moduledoc """
  Unit tests for the IncidentReporter.RetryConsumer module.

  Uses a mock engine facade with a test-pid-reporting retry function
  and the InMemoryAdapter for bus message injection.
  """

  use ExUnit.Case, async: false

  alias IncidentReporter.MessageBus.InMemoryAdapter
  alias IncidentReporter.RetryConsumer

  defp build_mock_facade(test_pid) do
    %{
      process_instances: %{
        retry: fn process_instance_id, opts ->
          send(test_pid, {:retry_called, process_instance_id, opts})
          :ok
        end
      }
    }
  end

  defp build_failing_facade(test_pid, error) do
    %{
      process_instances: %{
        retry: fn process_instance_id, opts ->
          send(test_pid, {:retry_called, process_instance_id, opts})
          error
        end
      }
    }
  end

  defp start_consumer(facade, connection, queue) do
    RetryConsumer.start_link(
      engine_facade: facade,
      message_bus_adapter: InMemoryAdapter,
      connection: connection,
      consume_queue: queue
    )
  end

  describe "retry command processing" do
    setup do
      {:ok, connection} = InMemoryAdapter.start_link()
      %{connection: connection}
    end

    test "retries a PI when a valid retryProcessInstance command arrives", %{
      connection: connection
    } do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command =
        Jason.encode!(%{
          "type" => "retryProcessInstance",
          "processInstanceId" => "pi-test-001"
        })

      InMemoryAdapter.inject(connection, "test.retry", command)

      assert_receive {:retry_called, "pi-test-001", opts}, 1000
      assert opts == %{}

      assert Process.alive?(consumer_pid)
      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "passes version to retry opts", %{connection: connection} do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command =
        Jason.encode!(%{
          "type" => "retryProcessInstance",
          "processInstanceId" => "pi-test-002",
          "version" => "2.0.0"
        })

      InMemoryAdapter.inject(connection, "test.retry", command)

      assert_receive {:retry_called, "pi-test-002", opts}, 1000
      assert opts == %{"version" => "2.0.0"}

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "passes resetToFlowNodeInstanceId to retry opts", %{connection: connection} do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command =
        Jason.encode!(%{
          "type" => "retryProcessInstance",
          "processInstanceId" => "pi-test-003",
          "resetToFlowNodeInstanceId" => "fni-checkpoint-456"
        })

      InMemoryAdapter.inject(connection, "test.retry", command)

      assert_receive {:retry_called, "pi-test-003", opts}, 1000
      assert opts == %{"resetToFlowNodeInstanceId" => "fni-checkpoint-456"}

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "passes both version and checkpoint", %{connection: connection} do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command =
        Jason.encode!(%{
          "type" => "retryProcessInstance",
          "processInstanceId" => "pi-test-004",
          "version" => "latest",
          "resetToFlowNodeInstanceId" => "fni-abc"
        })

      InMemoryAdapter.inject(connection, "test.retry", command)

      assert_receive {:retry_called, "pi-test-004", opts}, 1000
      assert opts == %{"version" => "latest", "resetToFlowNodeInstanceId" => "fni-abc"}

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end
  end

  describe "error handling" do
    setup do
      {:ok, connection} = InMemoryAdapter.start_link()
      %{connection: connection}
    end

    test "does not crash on retry failure ({:error, reason})", %{connection: connection} do
      facade = build_failing_facade(self(), {:error, :not_found})
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command =
        Jason.encode!(%{
          "type" => "retryProcessInstance",
          "processInstanceId" => "pi-nonexistent"
        })

      InMemoryAdapter.inject(connection, "test.retry", command)

      assert_receive {:retry_called, "pi-nonexistent", _opts}, 1000
      Process.sleep(50)
      assert Process.alive?(consumer_pid)

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "does not crash on retry failure ({:error, code, detail})", %{connection: connection} do
      facade = build_failing_facade(self(), {:error, :process_instance_not_retriable, "running"})
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command =
        Jason.encode!(%{
          "type" => "retryProcessInstance",
          "processInstanceId" => "pi-running"
        })

      InMemoryAdapter.inject(connection, "test.retry", command)

      assert_receive {:retry_called, "pi-running", _opts}, 1000
      Process.sleep(50)
      assert Process.alive?(consumer_pid)

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "ignores commands with unknown type", %{connection: connection} do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command = Jason.encode!(%{"type" => "unknownCommand", "data" => "test"})
      InMemoryAdapter.inject(connection, "test.retry", command)

      refute_receive {:retry_called, _, _}, 200
      assert Process.alive?(consumer_pid)

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "ignores commands without type field", %{connection: connection} do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command = Jason.encode!(%{"processInstanceId" => "pi-no-type"})
      InMemoryAdapter.inject(connection, "test.retry", command)

      refute_receive {:retry_called, _, _}, 200
      assert Process.alive?(consumer_pid)

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "ignores malformed JSON", %{connection: connection} do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      InMemoryAdapter.inject(connection, "test.retry", "not valid json {{{")

      refute_receive {:retry_called, _, _}, 200
      assert Process.alive?(consumer_pid)

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "ignores retryProcessInstance missing processInstanceId", %{connection: connection} do
      facade = build_mock_facade(self())
      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command = Jason.encode!(%{"type" => "retryProcessInstance"})
      InMemoryAdapter.inject(connection, "test.retry", command)

      refute_receive {:retry_called, _, _}, 200
      assert Process.alive?(consumer_pid)

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end

    test "handles duplicate retry — second attempt gets error, consumer survives", %{
      connection: connection
    } do
      call_count = :counters.new(1, [:atomics])

      facade = %{
        process_instances: %{
          retry: fn process_instance_id, opts ->
            current = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)
            send(self(), {:retry_called_from_consumer, process_instance_id, opts, current + 1})

            if current == 0 do
              :ok
            else
              {:error, :process_instance_not_retriable, "running"}
            end
          end
        }
      }

      {:ok, consumer_pid} = start_consumer(facade, connection, "test.retry")

      command =
        Jason.encode!(%{
          "type" => "retryProcessInstance",
          "processInstanceId" => "pi-duplicate"
        })

      InMemoryAdapter.inject(connection, "test.retry", command)
      InMemoryAdapter.inject(connection, "test.retry", command)

      Process.sleep(200)
      assert Process.alive?(consumer_pid)
      assert :counters.get(call_count, 1) == 2

      GenServer.stop(consumer_pid)
      InMemoryAdapter.disconnect(connection)
    end
  end

  describe "InMemoryAdapter" do
    test "connect returns a usable connection" do
      assert {:ok, connection} = InMemoryAdapter.connect([])
      assert is_pid(connection)
      InMemoryAdapter.disconnect(connection)
    end

    test "publish stores messages retrievable by exchange" do
      {:ok, connection} = InMemoryAdapter.start_link()

      :ok = InMemoryAdapter.publish(connection, "exchange_a", "msg1")
      :ok = InMemoryAdapter.publish(connection, "exchange_b", "msg2")
      :ok = InMemoryAdapter.publish(connection, "exchange_a", "msg3")

      assert InMemoryAdapter.get_published(connection, "exchange_a") == ["msg3", "msg1"]
      assert InMemoryAdapter.get_published(connection, "exchange_b") == ["msg2"]

      InMemoryAdapter.disconnect(connection)
    end

    test "inject delivers to all subscribers on the queue" do
      {:ok, connection} = InMemoryAdapter.start_link()

      :ok = InMemoryAdapter.subscribe(connection, "queue_1", self())
      :ok = InMemoryAdapter.inject(connection, "queue_1", "hello")

      assert_receive {:bus_message, "hello"}, 500

      InMemoryAdapter.disconnect(connection)
    end

    test "clear removes published messages" do
      {:ok, connection} = InMemoryAdapter.start_link()

      :ok = InMemoryAdapter.publish(connection, "ex", "msg")
      assert length(InMemoryAdapter.get_published(connection)) == 1

      :ok = InMemoryAdapter.clear(connection)
      assert InMemoryAdapter.get_published(connection) == []

      InMemoryAdapter.disconnect(connection)
    end
  end
end
