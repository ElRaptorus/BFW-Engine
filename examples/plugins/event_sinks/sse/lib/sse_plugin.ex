defmodule Examples.EventSinks.Sse.SsePlugin do
  @moduledoc """
  Registers the SSE EventSink and mounts `GET /events/stream` on the engine HTTP server.

  Does **not** start a second HTTP listener. Routes live on the existing Bandit/Phoenix server.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.EventSinks.Sse.{ConnectionHub, SsePlug, SseSink}

  @doc "Starts the connection hub, registers the sse sink, and mounts the /events RestApiExtension."
  @impl true
  def on_load(facade) do
    ConnectionHub.ensure_started()

    with :ok <- register_sink(facade),
         :ok <- register_extension(facade) do
      :ok
    end
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok

  defp register_sink(facade) do
    case facade.register_event_sink.("sse", SseSink, []) do
      :ok -> :ok
      {:error, reason} -> {:error, {:register_event_sink_failed, reason}}
    end
  end

  defp register_extension(facade) do
    case facade.register_rest_api_extension.("/events", SsePlug) do
      :ok -> :ok
      error -> {:error, {:register_rest_api_extension_failed, error}}
    end
  end
end
