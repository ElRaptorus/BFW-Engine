defmodule BfwEngine.Events.SinkRegistrar do
  @moduledoc """
  One-shot task that registers event sinks at boot based on config flags.

  Reads the `*_sink_enabled` keys from `:core_events` config and the
  `sink_modules` map, then calls `EngineEventBus.register_sink/2` for
  each enabled sink. Runs once during application startup and exits.

  Sink modules that live outside `core_events` (websocket, telemetry)
  are referenced via the `sink_modules` config map to preserve dependency direction
  (Core never imports Peripheral/API).
  """

  require Logger

  alias BfwEngine.Events.EngineEventBus

  @sink_config_keys %{
    "console" => :console_sink_enabled,
    "telemetry" => :telemetry_sink_enabled,
    "websocket" => :websocket_sink_enabled
  }

  @doc """
  Register all enabled sinks. Called from the Application supervisor
  as a one-shot child.
  """
  @spec register_all() :: :ok
  def register_all do
    sink_modules = Application.get_env(:core_events, :sink_modules, %{})

    for {name, config_key} <- @sink_config_keys,
        Application.get_env(:core_events, config_key, false),
        module = Map.get(sink_modules, name),
        module_available?(module) do
      opts = sink_opts(name)

      case EngineEventBus.register_sink(name, module, opts) do
        :ok ->
          Logger.info("EventSink '#{name}' registered (#{inspect(module)})")

        {:error, reason} ->
          Logger.warning("EventSink '#{name}' failed to register: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp module_available?(module) do
    case Code.ensure_loaded(module) do
      {:module, _} -> true
      {:error, _} -> false
    end
  end

  defp sink_opts("console") do
    min_severity = Application.get_env(:core_events, :log_min_severity, "info")
    [min_severity: min_severity]
  end

  defp sink_opts(_name), do: []
end
