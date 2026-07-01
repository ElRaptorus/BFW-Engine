defmodule Examples.ServiceTaskHandlers.WebhookCallback.WebhookCallbackReceiver do
  @moduledoc """
  Sketch GenServer that a Phoenix controller, Bandit handler, or plug could call when
  an external partner POSTs webhook results back.

  The HTTP layer should authenticate the caller, map the payload to a result map,
  then delegate here so the Service Task receives the async output through the
  official facade closures.
  """

  use GenServer

  @doc "Starts the receiver GenServer and captures the facade used to complete or fail async service tasks."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    facade = Keyword.fetch!(options, :facade)
    GenServer.start_link(__MODULE__, %{facade: facade}, Keyword.take(options, [:name]))
  end

  @doc "Forwards a successful async completion to the engine facade for the given flow node instance."
  @spec complete_async(GenServer.server(), String.t(), map()) :: :ok
  def complete_async(server, flow_node_instance_id, result_map) do
    GenServer.cast(server, {:complete_async, flow_node_instance_id, result_map})
  end

  @doc "Forwards a failed async completion to the engine facade with an error code and message."
  @spec fail_async(GenServer.server(), String.t(), String.t(), String.t()) :: :ok
  def fail_async(server, flow_node_instance_id, error_code, error_message) do
    GenServer.cast(server, {:fail_async, flow_node_instance_id, error_code, error_message})
  end

  @doc "Starts the GenServer with only the facade reference in the process state."
  @impl true
  def init(state), do: {:ok, state}

  @doc "Completes or fails the parked async service task by invoking the matching facade service task closure."
  @impl true
  def handle_cast({:complete_async, flow_node_instance_id, result_map}, state) do
    _ = state.facade.service_tasks.finish_async.(flow_node_instance_id, result_map)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:fail_async, flow_node_instance_id, error_code, error_message}, state) do
    _ = state.facade.service_tasks.fail_async.(flow_node_instance_id, error_code, error_message)
    {:noreply, state}
  end
end
