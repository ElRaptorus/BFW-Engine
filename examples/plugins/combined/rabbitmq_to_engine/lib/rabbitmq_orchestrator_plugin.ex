defmodule Examples.Plugins.Combined.RabbitmqToEngine.RabbitmqOrchestratorPlugin do
  @moduledoc """
  Registers an event sink, caches `EngineFacade`, and starts the stub RabbitMQ
  consumer after the engine reaches ready state.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.Plugins.Combined.RabbitmqToEngine.{
    FacadeStore,
    OrchestratorMetricsSink,
    RabbitmqConsumer
  }

  @doc "Ensures the facade Agent exists, registers the metrics sink, and stores the facade for the consumer."
  @impl true
  def on_load(engine_facade) do
    :ok = ensure_facade_store_started()
    :ok = FacadeStore.put(engine_facade)

    case engine_facade.register_event_sink.(
           "orchestrator_metrics",
           OrchestratorMetricsSink,
           []
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:register_event_sink_failed, reason}}
    end
  end

  @doc "Starts the stub RabbitMQ consumer GenServer after the engine reports all plugins ready."
  @impl true
  def on_ready(engine_facade) do
    {:ok, _consumer_pid} = RabbitmqConsumer.start_link(engine_facade: engine_facade, name: RabbitmqConsumer)
    :ok
  end

  defp ensure_facade_store_started do
    case FacadeStore.start_link(name: FacadeStore) do
      {:ok, _agent_pid} -> :ok
      {:error, {:already_started, _agent_pid}} -> :ok
    end
  end
end
