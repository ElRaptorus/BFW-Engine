defmodule Examples.EventSinks.StructuredLogger.LoggerPlugin do
  @moduledoc """
  Example plugin that registers a newline-delimited JSON log sink.

  Copy this module and `LoggerSink` into your own OTP application.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.EventSinks.StructuredLogger.LoggerSink

  @doc "Registers the structured logger sink writing newline-delimited JSON to stdout."
  @impl true
  def on_load(facade) do
    facade.register_event_sink.("structured_logger", LoggerSink, output: :stdout)
    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
