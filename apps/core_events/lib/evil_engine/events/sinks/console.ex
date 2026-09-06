defmodule EvilEngine.Events.Sinks.Console do
  @moduledoc """
  Structured JSON log sink. Default ON.

  Emits each accepted event as a structured JSON line to stdout via
  `Logger`. Filtered by `TDE_LOG_MIN_SEVERITY` (default `info`).
  """

  @behaviour EvilEngine.Plugin.EventSink

  require Logger

  @severity_order ~w(verbose debug info warn error)a

  @impl true
  def init(opts) do
    min_severity =
      opts
      |> Keyword.get(:min_severity, "info")
      |> String.to_existing_atom()

    {:ok, %{min_severity: min_severity}}
  end

  @impl true
  def accepts?(%EvilEngine.Types.Event.SinkFailed{}), do: false
  def accepts?(_event), do: true

  @impl true
  def handle_event(event, state) do
    severity = event_severity(event)

    if severity_at_or_above?(severity, state.min_severity) do
      metadata = build_metadata(event)
      log_at_level(severity, event, metadata)
    end

    {:ok, state}
  end

  @impl true
  def handle_shutdown(_state), do: :ok

  defp event_severity(%EvilEngine.Types.Event.EngineShutdown{}), do: :warn
  defp event_severity(%EvilEngine.Types.Event.SinkFailed{}), do: :error
  defp event_severity(_event), do: :info

  defp severity_at_or_above?(level, min) do
    severity_index(level) >= severity_index(min)
  end

  defp severity_index(level) do
    case Enum.find_index(@severity_order, &(&1 == level)) do
      nil -> 2
      index -> index
    end
  end

  defp build_metadata(event) do
    base = %{event_type: event.__struct__ |> Module.split() |> List.last()}

    base
    |> maybe_add(:engine_id, Map.get(event, :engine_id))
    |> maybe_add(:process_instance_id, Map.get(event, :process_instance_id))
    |> maybe_add(:flow_node_instance_id, Map.get(event, :flow_node_instance_id))
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp log_at_level(level, event, metadata) do
    payload = fn -> Jason.encode!(Map.merge(metadata, Map.from_struct(event))) end

    case level do
      :error -> Logger.error(payload)
      :warn -> Logger.warning(payload)
      _ -> Logger.info(payload)
    end
  end
end
