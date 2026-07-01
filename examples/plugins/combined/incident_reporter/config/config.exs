import Config

config :incident_reporter,
  message_bus_adapter: IncidentReporter.MessageBus.RabbitMqAdapter,
  connection_opts: [host: "localhost", port: 5672],
  publish_exchange: "evil.incidents",
  consume_queue: "evil.retry_commands"

if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
