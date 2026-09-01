defmodule Examples.EventSinks.WebhookForwarder.WebhookPlugin do
  @moduledoc """
  Example plugin that registers an HTTP webhook forwarder sink.

  Copy this module and `WebhookSink` into your own OTP application.
  """

  @behaviour EvilEngine.Plugin

  alias Examples.EventSinks.WebhookForwarder.WebhookSink

  @doc "Registers the webhook forwarder sink with a placeholder URL and JSON headers."
  @impl true
  def on_load(facade) do
    facade.register_event_sink.("webhook_forwarder", WebhookSink,
      url: "http://127.0.0.1:1/engine-events",
      headers: [{"content-type", "application/json"}],
      filter_types: nil
    )

    :ok
  end

  @doc "Performs no extra work once every plugin has finished loading."
  @impl true
  def on_ready(_facade), do: :ok
end
