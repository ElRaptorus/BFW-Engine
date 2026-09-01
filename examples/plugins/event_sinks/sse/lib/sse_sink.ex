defmodule Examples.EventSinks.Sse.SseSink do
  @moduledoc """
  EventSink that Jason-encodes typed engine events and broadcasts them to SSE subscribers.
  """

  @behaviour EvilEngine.Plugin.EventSink

  alias EvilEngine.Types.Event
  alias Examples.EventSinks.Sse.ConnectionHub

  @doc "Ensures the connection hub is running."
  @impl true
  def init(_options) do
    ConnectionHub.ensure_started()
    {:ok, %{}}
  end

  @doc "Accepts every engine event so connected clients can watch the full stream."
  @impl true
  def accepts?(_event), do: true

  @doc "Encodes the event as camelCase JSON and broadcasts it with a severity label."
  @impl true
  def handle_event(event, state) do
    json_body = Jason.encode!(event)
    ConnectionHub.broadcast(json_body, severity_for(event))
    {:ok, state}
  end

  @doc "No resources to release besides the hub, which outlives a single sink worker restart."
  @impl true
  def handle_shutdown(_state), do: :ok

  defp severity_for(%Event.SinkFailed{}), do: "error"
  defp severity_for(%Event.PluginQuarantined{}), do: "error"
  defp severity_for(%Event.EngineOverloaded{}), do: "warning"
  defp severity_for(_event), do: "info"
end
