defmodule BfwEngine.Events.Supervisor do
  @moduledoc false

  use Supervisor

  alias BfwEngine.Events.CancelledFlowNodeInstances
  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.PendingSweeper
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Events.SinkRegistrar

  # The ETS table is created in the caller (the Engine's root supervisor), so
  # it outlives restarts of this supervisor's children.
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_options) do
    :ok = CancelledFlowNodeInstances.create_table()
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    sweeper_enabled? =
      Application.get_env(:bfw_engine, :pending_sweeper_enabled, true)

    base_children = [
      {Phoenix.PubSub, name: BfwEngine.Events.pubsub_name()},
      {Registry, keys: :unique, name: BfwEngine.Events.SinkRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: BfwEngine.Events.SinkSupervisor},
      CancelledFlowNodeInstances,
      MessageSubscriptions,
      SignalSubscriptions,
      EngineEventBus
    ]

    sweeper_children = if sweeper_enabled?, do: [PendingSweeper], else: []

    children =
      base_children ++ sweeper_children ++ [{Task, &SinkRegistrar.register_all/0}]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
