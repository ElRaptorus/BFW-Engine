import Config

# --- Logging -------------------------------------------------------------
config :logger, level: :debug

# --- Persistence --------------------------------------------------------
config :peripheral_persistence, BfwEngine.Persistence.Repo,
  username: "bfw_engine",
  password: "bfw_engine",
  hostname: "localhost",
  database: "bfw_engine_dev",
  pool_size: 10,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :peripheral_persistence, BfwEngine.Persistence.ReadRepo,
  username: "bfw_engine",
  password: "bfw_engine",
  hostname: "localhost",
  database: "bfw_engine_dev",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# --- Phoenix HTTP -------------------------------------------------------
config :api_web, BfwEngineWeb.Http.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  url: [host: "localhost"],
  server: true,
  code_reloader: false,
  debug_errors: true,
  check_origin: false,
  secret_key_base: "dev_secret_key_base_REPLACE_IN_RUNTIME_EXS_AT_LEAST_64_CHARS_PLEASE"

# --- Auth (dev defaults) -------------------------------------------------
config :api_auth,
  auth_disabled: true,
  hs256_secret: "AveOmnissiah_FromTheHolyForgesOfMars_NotAProductionSecret_Mechanicus!!"
