import Config

# Logs are JSON in prod (see `docs/architecture/observability.md`).
# logger_json v7 uses Erlang's :logger formatter system (tuple form for
# compile-time config; the module is loaded lazily by the logger handler).
config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: [
       :request_id,
       :process_instance_id,
       :flow_node_instance_id,
       :process_model_id,
       :process_version_id
     ]}

config :logger, level: :info

# Use the built-in JSON module (Elixir >= 1.18) instead of Jason.
config :logger_json, encoder: JSON

# All other runtime values — DB URL, HTTP port, JWT config, seeding
# directory, retention knobs, payload cap, … — are sourced from `TDE_*`
# env vars in `runtime.exs` per `docs/architecture/configuration.md`.
