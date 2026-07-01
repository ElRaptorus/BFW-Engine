defmodule EvilEngine.Events.Application do
  @moduledoc false

  use Application

  alias EvilEngine.Events.EngineEventBus
  alias EvilEngine.Events.MessageSubscriptions
  alias EvilEngine.Events.PendingSweeper
  alias EvilEngine.Events.SignalSubscriptions
  alias EvilEngine.Events.SinkRegistrar

  @impl true
  def start(_type, _args) do
    sweeper_enabled? =
      Application.get_env(:core_events, :pending_sweeper_enabled, true)

    base_children = [
      {Phoenix.PubSub, name: EvilEngine.Events.pubsub_name()},
      {Registry, keys: :unique, name: EvilEngine.Events.SinkRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: EvilEngine.Events.SinkSupervisor},
      MessageSubscriptions,
      SignalSubscriptions,
      EngineEventBus
    ]

    sweeper_children = if sweeper_enabled?, do: [PendingSweeper], else: []

    children =
      base_children ++ sweeper_children ++ [{Task, &SinkRegistrar.register_all/0}]

    opts = [strategy: :one_for_one, name: EvilEngine.Events.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
