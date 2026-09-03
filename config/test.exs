import Config

config :logger, level: :warning

config :peripheral_persistence, EvilEngine.Persistence.Repo,
  username: "evil_engine",
  password: "evil_engine",
  hostname: "localhost",
  port: 5543,
  database: "evil_engine_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Load tests (L6 10k resume orphan sweep) hold the shared sandbox connection
  # longer than the 15s runtime default. Keep sandbox {:shared, self()}.
  timeout: 120_000

config :peripheral_persistence, EvilEngine.Persistence.ReadRepo,
  username: "evil_engine",
  password: "evil_engine",
  hostname: "localhost",
  port: 5543,
  database: "evil_engine_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  timeout: 120_000

config :api_web, EvilEngineWeb.Http.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: "test_secret_key_base_64_characters_minimum_for_the_test_env_only!"

# Print fewer lines per test; surface real engine behaviour instead of
# fixture boilerplate.
# --- Auth (test defaults) ------------------------------------------------
config :api_auth,
  auth_disabled: true,
  hs256_secret: "test_only_secret_at_least_32_bytes!"

# --- Partitioning (use monthly in tests for max coverage of partition logic)
config :peripheral_persistence, partition_interval: :monthly

# --- Persistence adapter (NoOp for unit tests; integration tests wire their own) ---
config :core_execution,
  persistence_adapter: EvilEngine.Execution.Persistence.NoOp,
  called_element_resolver: EvilEngine.Execution.CalledElementResolver.NoOp,
  decision_resolver: EvilEngine.Execution.DecisionResolver.NoOp,
  dmn_evaluation_timeout_ms: 5_000

# --- Event sinks ----------------------------------------------------------
config :core_events,
  console_sink_enabled: false,
  telemetry_sink_enabled: false,
  websocket_sink_enabled: false,
  pending_sweeper_enabled: false

config :core_dmn,
  model_cache_loader: nil,
  max_import_depth: 10

# --- Timers (fast tick for tests) -----------------------------------------
config :core_timers,
  tick_interval_ms: 50,
  timer_start_target: EvilEngine.Execution.TimerStartListener,
  persistence_module: EvilEngine.Timers.Persistence.NoOp

config :ex_unit, capture_log: true
