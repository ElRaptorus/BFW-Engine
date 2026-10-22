defmodule BfwEngine.Application do
  @moduledoc """
  OTP application callback of the Engine.

  Starts one supervisor per subsystem, in dependency order: a subsystem may
  rely on every subsystem started before it.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]
  use Application

  alias BfwEngine.Events.EngineEventBus
  alias BfwEngine.Types.Event
  alias BfwEngineWeb.Http.Endpoint

  @impl true
  def start(_type, _args) do
    children = [
      BfwEngine.Timers.Supervisor,
      BfwEngine.BPMN.Supervisor,
      BfwEngine.Events.Supervisor,
      BfwEngine.DMN.Supervisor,
      BfwEngine.Execution.ApplicationSupervisor,
      BfwEngine.Persistence.Supervisor,
      BfwEngine.Plugins.Supervisor,
      BfwEngine.Telemetry.Supervisor,
      BfwEngine.Auth.Supervisor,
      BfwEngineWeb.Supervisor
    ]

    # A subsystem supervisor that gives up stops the Engine instead of being
    # restarted on its own: its siblings hold state that depends on it.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 0,
      name: BfwEngine.Supervisor
    )
  end

  # Runs before any subsystem stops. Process instances persist and exit while
  # the Repo is still up; sinks drain while the Endpoint can still deliver.
  @impl true
  def prep_stop(state) do
    BfwEngine.Execution.shutdown_process_instances()

    EngineEventBus.publish(%Event.EngineShutdown{
      engine_id: Application.get_env(:bfw_engine, :engine_id, "default"),
      reason: :shutdown,
      occurred_at: DateTime.utc_now()
    })

    # `publish/1` casts to the bus; `shutdown_sinks/0` is a call queued after
    # that cast, so every sink receives EngineShutdown before `handle_shutdown/1`.
    EngineEventBus.shutdown_sinks()

    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end
end
