defmodule Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqFacadeStore do
  @moduledoc """
  Agent copy of `EngineFacade` for helper processes that complete RabbitMQ-driven work.
  """

  use Agent

  @doc "Starts the facade Agent when it is not yet registered so helper processes can read it later."
  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, _pid} = Agent.start_link(fn -> nil end, name: __MODULE__)
        :ok

      _pid ->
        :ok
    end
  end

  @doc "Stores the engine facade reference for the RabbitMQ consumer and async completions."
  @spec put(BfwEngine.EngineFacade.t()) :: :ok
  def put(facade), do: Agent.update(__MODULE__, fn _ -> facade end)

  @doc "Returns the cached engine facade, or nil if this store has not been written yet."
  @spec get() :: BfwEngine.EngineFacade.t() | nil
  def get, do: Agent.get(__MODULE__, & &1)
end

defmodule Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqPlugin do
  @moduledoc """
  Registers the `"rabbitmq"` handler, caches `EngineFacade`, and starts `RabbitmqConsumer`.
  """

  alias Examples.ServiceTaskHandlers.RabbitmqRoundtrip.{RabbitmqConsumer, RabbitmqFacadeStore}

  @behaviour BfwEngine.Plugin

  @doc "Caches the facade, starts the stub consumer, and registers the rabbitmq Service Task handler."
  @impl true
  def on_load(facade) do
    :ok = RabbitmqFacadeStore.ensure_started()
    RabbitmqFacadeStore.put(facade)

    {:ok, _consumer_pid} = RabbitmqConsumer.start_link(facade: facade)

    facade.register_service_task_handler.(
      "rabbitmq",
      Examples.ServiceTaskHandlers.RabbitmqRoundtrip.RabbitmqHandler
    )

    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
