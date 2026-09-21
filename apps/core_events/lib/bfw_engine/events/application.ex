defmodule BfwEngine.Events.Application do
  @moduledoc false

  use Application

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Events.MessageSubscriptions
  alias BfwEngine.Events.PendingSweeper
  alias BfwEngine.Events.SignalSubscriptions
  alias BfwEngine.Events.SinkRegistrar

  @impl true
  def start(_type, _args) do
    sweeper_enabled? =
      Application.get_env(:core_events, :pending_sweeper_enabled, true)

    base_children = [
      {Phoenix.PubSub, name: BfwEngine.Events.pubsub_name()},
      {Registry, keys: :unique, name: BfwEngine.Events.SinkRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: BfwEngine.Events.SinkSupervisor},
      MessageSubscriptions,
      SignalSubscriptions,
      EngineEventBus
    ]

    sweeper_children = if sweeper_enabled?, do: [PendingSweeper], else: []

    children =
      base_children ++ sweeper_children ++ [{Task, &SinkRegistrar.register_all/0}]

    opts = [strategy: :one_for_one, name: BfwEngine.Events.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
