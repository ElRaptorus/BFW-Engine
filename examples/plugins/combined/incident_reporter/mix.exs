defmodule IncidentReporter.MixProject do
  use Mix.Project

  def project do
    [
      app: :incident_reporter,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [
        plugin_module: IncidentReporter,
        message_bus_adapter: IncidentReporter.MessageBus.RabbitMqAdapter,
        connection_opts: [],
        publish_exchange: "evil.incidents",
        consume_queue: "evil.retry_commands"
      ]
    ]
  end

  defp deps do
    [
      {:engine_sdk, path: "../../../../apps/engine_sdk"},
      {:jason, "~> 1.4"}
      # For the RabbitMQ adapter, add {:amqp, "~> 3.3"} to your own project's deps.
      # The adapter uses dynamic dispatch (apply/3) and compiles without the amqp package.
    ]
  end
end
