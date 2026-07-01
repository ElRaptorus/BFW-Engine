defmodule Examples.Plugins.LifecycleAware.LifecycleDemoEventSink do
  @moduledoc """
  Minimal [`EvilEngine.Plugin.EventSink`](https://github.com/ElRaptorus/ThomasTheDaemonEngine/blob/main/apps/engine_sdk/lib/evil_engine/plugin/event_sink.ex)
  registered only to prove `facade.register_event_sink/3` succeeds. `accepts?/1`
  always returns `false`, so no hot-path work runs.
  """

  @behaviour EvilEngine.Plugin.EventSink

  @doc "Initializes this demo sink with empty state; it never accepts engine events."
  @impl true
  def init(_options), do: {:ok, %{}}

  @doc "Declines all events so the lifecycle example only proves sink registration succeeds."
  @impl true
  def accepts?(_event_struct), do: false

  @doc "Returns state unchanged because no events are accepted by this noop sink."
  @impl true
  def handle_event(_event_struct, state), do: {:ok, state}

  @doc "No resources to release for this minimal sink."
  @impl true
  def handle_shutdown(_state), do: :ok
end

defmodule Examples.Plugins.LifecycleAware.LifecyclePlugin do
  @moduledoc """
  Demonstrates `on_load/1` versus `on_ready/1` responsibilities for
  [`EvilEngine.Plugin`](https://github.com/ElRaptorus/ThomasTheDaemonEngine/blob/main/apps/engine_sdk/lib/evil_engine/plugin.ex).
  """

  @behaviour EvilEngine.Plugin

  require Logger

  @doc "Logs facade identity, reads a demo config flag, and registers the noop lifecycle event sink."
  @impl true
  def on_load(engine_facade) do
    Logger.info(
      "lifecycle example on_load: engine_id=#{engine_facade.engine_id} engine_name=#{engine_facade.engine_name} version=#{engine_facade.version}"
    )

    demo_setting = engine_facade.get_config.(:lifecycle_demo_setting)
    Logger.info("lifecycle example on_load: lifecycle_demo_setting=#{inspect(demo_setting)}")

    case engine_facade.register_event_sink.(
           "lifecycle-demo-noop-sink",
           Examples.Plugins.LifecycleAware.LifecycleDemoEventSink,
           []
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:register_event_sink_failed, reason}}
    end
  end

  @doc "Runs a lightweight facade probe after every plugin is loaded to illustrate post-ready work."
  @impl true
  def on_ready(engine_facade) do
    Logger.info("Engine ready, all plugins loaded. Performing health check...")

    probe_outcome = engine_facade.processes.get_latest_version.("nonexistent-process-model-id-for-probe")
    Logger.info("lifecycle example on_ready: processes.get_latest_version probe=#{inspect(probe_outcome)}")
    :ok
  end
end
