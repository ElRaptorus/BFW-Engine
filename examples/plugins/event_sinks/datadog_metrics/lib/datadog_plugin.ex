defmodule Examples.EventSinks.DatadogMetrics.DatadogPlugin do
  @moduledoc """
  Example plugin that registers a DataDog-style metrics sink.

  Copy this module and `DatadogSink` into your own OTP application.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.EventSinks.DatadogMetrics.DatadogSink

  @doc "Registers the datadog event sink with example API key and batch size."
  @impl true
  def on_load(facade) do
    facade.register_event_sink.("datadog", DatadogSink,
      api_key: "replace-with-datadog-api-key",
      batch_size: 10
    )

    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
