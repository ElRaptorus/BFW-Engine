defmodule Examples.Plugins.Combined.RabbitmqToEngine.RabbitmqOrchestratorTest do
  use ExUnit.Case, async: false

  alias EvilEngine.EngineFacade
  alias EvilEngine.Types.Event
  alias Examples.Plugins.Combined.RabbitmqToEngine.{
    FacadeStore,
    OrchestratorCustomEvent,
    OrchestratorMetricsSink,
    RabbitmqConsumer
  }

  setup do
    case FacadeStore.start_link(name: FacadeStore) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end

    on_exit(fn ->
      case Process.whereis(FacadeStore) do
        nil ->
          :ok

        pid ->
          if Process.alive?(pid) do
            Agent.stop(pid)
          end
      end
    end)

    :ok
  end

  test "consumer processes a queue body and calls processes.start with parsed payload" do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    on_exit(fn ->
      if Process.alive?(calls_agent) do
        Agent.stop(calls_agent)
      end
    end)

    process_model_id = "orchestrated-process"
    process_version_resource = %{id: "process-version-orchestrator"}

    facade = %EngineFacade{
      engine_id: "test-engine",
      engine_name: "test-engine-name",
      version: "0.0.0-test",
      processes: %EngineFacade.Processes{
        get_latest_version: fn ^process_model_id ->
          {:ok, process_version_resource}
        end,
        start: fn start_arguments ->
          Agent.update(calls_agent, fn events -> events ++ [{:start, start_arguments}] end)
          {:ok, self()}
        end
      },
      publish_event: fn published_event ->
        Agent.update(calls_agent, fn events -> events ++ [{:publish, published_event}] end)
        :ok
      end
    }

    :ok = FacadeStore.put(facade)

    {:ok, consumer_pid} = RabbitmqConsumer.start_link(engine_facade: facade)

    message_body =
      Jason.encode!(%{
        "process_model_id" => process_model_id,
        "payload" => %{"source" => "fake-queue"}
      })

    send(consumer_pid, {:deliver_test_message, message_body})

    :sys.get_state(consumer_pid)

    recorded_calls = Agent.get(calls_agent, & &1)
    assert [{:start, start_arguments}, {:publish, %OrchestratorCustomEvent{}}] = recorded_calls

    assert Keyword.fetch!(start_arguments, :payload) == %{"source" => "fake-queue"}
    assert {:ok, _} = Keyword.fetch(start_arguments, :process_instance_id)
    assert Keyword.fetch!(start_arguments, :process_version_id) == process_version_resource.id

    GenServer.stop(consumer_pid, :normal, 5_000)
  end

  test "orchestrator metrics sink accepts process instance state changes and rejects engine started" do
    pi_event = %Event.ProcessInstanceStateChanged{
      process_instance_id: "pi-1",
      process_model_id: "model-1",
      version: "1.0.0",
      parent_process_instance_id: nil,
      old_state: :running,
      new_state: :completed,
      occurred_at: ~U[2026-05-14T12:00:00Z]
    }

    engine_started = %Event.EngineStarted{
      engine_id: "engine-1",
      engine_name: "e1",
      version: "1",
      started_at: ~U[2026-05-14T12:00:00Z]
    }

    assert OrchestratorMetricsSink.accepts?(pi_event)
    refute OrchestratorMetricsSink.accepts?(engine_started)
  end

  test "orchestrator metrics sink increments per accepted event type" do
    {:ok, state} = OrchestratorMetricsSink.init([])

    orchestrator_event = %OrchestratorCustomEvent{
      type: "orchestrator:process_started",
      process_model_id: "orchestrated-process",
      process_instance_id: "pi-abc",
      payload: %{},
      timestamp: ~U[2026-05-14T12:00:00Z]
    }

    pi_event = %Event.ProcessInstanceStateChanged{
      process_instance_id: "pi-1",
      process_model_id: "model-1",
      version: "1.0.0",
      parent_process_instance_id: nil,
      old_state: nil,
      new_state: :running,
      occurred_at: ~U[2026-05-14T12:00:01Z]
    }

    assert {:ok, state_after_orchestrator} = OrchestratorMetricsSink.handle_event(orchestrator_event, state)
    assert state_after_orchestrator.orchestrator_dispatches == 1

    assert {:ok, state_after_pi} = OrchestratorMetricsSink.handle_event(pi_event, state_after_orchestrator)
    assert state_after_pi.process_instance_state_events == 1
  end
end
