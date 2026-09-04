import Config

config :logger, level: :warning

# Integration/conformance use the Ecto sandbox (one shared connection per
# test, rolled back at the end). Load tests must not: E8 owns that
# connection longer than ownership_timeout (300s) and then every PI
# explodes with OwnershipError (P89). `mix test.load` and the GitHub
# load-bench job set EVIL_LOAD_TEST_POOL=1 so Repo uses a real pool.
load_test_pool? = System.get_env("EVIL_LOAD_TEST_POOL") in ["1", "true"]

load_test_write_pool_size =
  String.to_integer(System.get_env("EVIL_LOAD_TEST_POOL_SIZE") || "16")

load_test_read_pool_size = max(div(load_test_write_pool_size, 2), 4)

repo_pool =
  if load_test_pool? do
    [
      pool: DBConnection.ConnectionPool,
      pool_size: load_test_write_pool_size,
      queue_target: 5_000,
      queue_interval: 10_000,
      timeout: 120_000
    ]
  else
    [
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: System.schedulers_online() * 2,
      timeout: 120_000
    ]
  end

read_repo_pool =
  if load_test_pool? do
    [
      pool: DBConnection.ConnectionPool,
      pool_size: load_test_read_pool_size,
      queue_target: 5_000,
      queue_interval: 10_000,
      timeout: 120_000
    ]
  else
    [
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: System.schedulers_online() * 2,
      timeout: 120_000
    ]
  end

config :peripheral_persistence,
       EvilEngine.Persistence.Repo,
       [
         username: "evil_engine",
         password: "evil_engine",
         hostname: "localhost",
         port: 5543,
         database: "evil_engine_test#{System.get_env("MIX_TEST_PARTITION")}"
       ] ++ repo_pool

config :peripheral_persistence,
       EvilEngine.Persistence.ReadRepo,
       [
         username: "evil_engine",
         password: "evil_engine",
         hostname: "localhost",
         port: 5543,
         database: "evil_engine_test#{System.get_env("MIX_TEST_PARTITION")}"
       ] ++ read_repo_pool

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
