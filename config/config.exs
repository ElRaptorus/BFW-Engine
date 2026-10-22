# Compile-time defaults. Per-env overrides live in
# `dev.exs` / `test.exs` / `prod.exs`. Runtime-only, environment-driven
# settings (the `BFE_*` vars documented in `docs/architecture/configuration.md`)
# live in `runtime.exs`.
import Config

# --- Logging --------------------------------------------------------------
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :process_instance_id,
    :flow_node_instance_id,
    :process_model_id,
    :reason
  ]

config :logger, level: :info

# --- Json encoder -------------------------------------------------------
config :phoenix, :json_library, Jason
config :ash, :json_library, Jason

# --- Ash ------------------------------------------------------------------
# Per the plan, Ash is the primary data-modelling framework (§1). The
# `BfwEngine.Persistence` owns the Ash domains and the Repo.
#
# `default_string_length_count` is required since Ash 3.33. `:codepoints`
# matches PostgreSQL `LENGTH` / `char_length`, so `min_length` / `max_length`
# constraints agree with what the data layer stores.
# https://hexdocs.pm/ash/backwards-compatibility-config.html#default_string_length_count
config :ash,
  include_embedded_source_by_default?: false,
  custom_types: [],
  known_types: [],
  default_page_type: :keyset,
  default_string_length_count: :codepoints,
  policies: [no_filter_static_forbidden_reads?: false]

config :bfw_engine,
  ash_domains: [BfwEngine.Persistence.Api],
  ecto_repos: [BfwEngine.Persistence.Repo, BfwEngine.Persistence.ReadRepo]

# --- Phoenix / HTTP ------------------------------------------------------
# Minimal stub endpoint configs so the Phoenix supervision tree starts.
# Real env values (port, secret, etc.) are set in runtime.exs.
config :bfw_engine, BfwEngineWeb.Http.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: BfwEngineWeb.Http.ErrorJSON],
    layout: false
  ],
  pubsub_server: BfwEngine.PubSub

# --- Task Dispatch (Service Task + Script Task) ---------------------------
config :bfw_engine,
  service_task_dispatch: BfwEngine.Plugins.RegistryDispatch,
  script_dispatch: BfwEngine.Plugins.ScriptRegistryDispatch,
  persistence_adapter: BfwEngine.Persistence.ExecutionAdapter,
  called_element_resolver: BfwEngine.Persistence.CalledElementResolverImpl,
  decision_resolver: BfwEngine.Persistence.DecisionResolverImpl,
  token_max_bytes: 65_536,
  dmn_evaluation_timeout_ms: 30_000,
  persistence_retry_max_attempts: 5,
  persistence_retry_initial_backoff_ms: 100

# --- ModelCache loader (auto-heal cache misses from DB) ------------------
config :bfw_engine,
  bpmn_model_cache_loader: {BfwEngine.Persistence.ExecutionAdapter, :load_bpmn_xml}

config :bfw_engine,
  dmn_model_cache_loader: {BfwEngine.Persistence.ExecutionAdapter, :load_dmn_xml},
  max_import_depth: 10

# --- Event sink modules ---------------------------------------------
# Maps sink names to their implementing modules. The database and websocket
# sinks live outside `BfwEngine.Events`, so we configure their modules here
# to avoid cross-domain imports.
config :bfw_engine,
  sink_modules: %{
    "console" => BfwEngine.Events.Sinks.Console,
    "telemetry" => BfwEngine.Telemetry.Sink,
    "websocket" => BfwEngineWeb.Ws.Sinks.WebSocket
  },
  message_start_event_handler:
    {BfwEngine.Execution.MessageStartHandler, :start_processes_for_message},
  message_persistence_adapter: BfwEngine.Persistence.MessagePersistenceAdapter,
  signal_start_event_handler:
    {BfwEngine.Execution.SignalStartHandler, :start_processes_for_signal},
  signal_persistence_adapter: BfwEngine.Persistence.SignalPersistenceAdapter

# --- Auth provider registry (boundary injection) ----------------------
# `BfwEngine.Plugins` must not compile-depend on `BfwEngine.Auth` (API).
# The ProviderRegistry module reference is injected at runtime.
config :bfw_engine, auth_provider_registry: BfwEngine.Auth.ProviderRegistry

# --- Timers --------------------------------------------------
config :bfw_engine,
  tick_interval_ms: 1_000,
  timer_start_target: BfwEngine.Execution.TimerStartListener,
  persistence_module: BfwEngine.Persistence.TimerStartScheduleAdapter

# --- Telemetry -----------------------------------------------------------
# In-process `:telemetry` plus optional Prometheus scrape (`BFE_METRICS_ENABLED`).
config :bfw_engine,
  db_queue_time_warning_ms: 500

# --- GraphQL safety limits (S-4) -----------------------------------------
# Runtime overrides are read from BFE_GRAPHQL_* in runtime.exs.
# Complexity default 10000 is sized for the Studio debugger snapshot
# (`dataObjectValues` with limit 500 → AshGraphql score 6500).
config :bfw_engine,
  graphql_max_depth: 16,
  graphql_max_complexity: 10_000,
  graphql_introspection_disabled: false

import_config "#{config_env()}.exs"
