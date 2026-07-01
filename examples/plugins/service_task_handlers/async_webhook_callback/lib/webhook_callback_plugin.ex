defmodule Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackFacadeStore do
  @moduledoc """
  Holds the `EngineFacade` passed to `on_load/1` so asynchronous completions can
  call `service_tasks.finish_async/2` from outside the request cycle.
  """

  use Agent

  @doc "Starts the facade Agent when it is not yet registered so later calls can stash the facade."
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

  @doc "Stores the engine facade reference for asynchronous completions that call back into the engine."
  @spec put(EvilEngine.EngineFacade.t()) :: :ok
  def put(facade) do
    Agent.update(__MODULE__, fn _ -> facade end)
  end

  @doc "Returns the engine facade cached for this example, if one was stored."
  @spec get() :: EvilEngine.EngineFacade.t() | nil
  def get do
    Agent.get(__MODULE__, & &1)
  end
end

defmodule Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackPlugin do
  @moduledoc """
  Registers the `"webhook_callback"` handler and caches the `EngineFacade` in an Agent.
  """

  alias Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackFacadeStore

  @behaviour EvilEngine.Plugin

  @doc "Caches the facade, ensures the Agent is running, and registers the webhook_callback Service Task handler."
  @impl true
  def on_load(facade) do
    :ok = WebhookCallbackFacadeStore.ensure_started()
    WebhookCallbackFacadeStore.put(facade)

    facade.register_service_task_handler.(
      "webhook_callback",
      Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackHandler
    )

    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
