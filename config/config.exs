# Umbrella-wide compile-time defaults. Per-env overrides live in
# `dev.exs` / `test.exs` / `prod.exs`. Runtime-only, environment-driven
# settings (the `EVIL_*` vars documented in ImplementationPlan.md §14.3)
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
# `peripheral_persistence` app owns the Ash domains and the Repo.
config :ash,
  include_embedded_source_by_default?: false,
  custom_types: [],
  known_types: [],
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

config :peripheral_persistence,
  ash_domains: [EvilEngine.Persistence.Api],
  ecto_repos: [EvilEngine.Persistence.Repo, EvilEngine.Persistence.ReadRepo]

# --- Phoenix / HTTP ------------------------------------------------------
# Minimal stub endpoint configs so the Phoenix supervision tree starts.
# Real env values (port, secret, etc.) are set in runtime.exs.
config :api_web, EvilEngineWeb.Http.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: EvilEngineWeb.Http.ErrorJSON],
    layout: false
  ],
  pubsub_server: EvilEngine.PubSub

# --- Task Dispatch (Service Task + Script Task) ---------------------------
config :core_execution,
  service_task_dispatch: EvilEngine.Plugins.RegistryDispatch,
  script_dispatch: EvilEngine.Plugins.ScriptRegistryDispatch,
  persistence_adapter: EvilEngine.Persistence.ExecutionAdapter,
  called_element_resolver: EvilEngine.Persistence.CalledElementResolverImpl,
  decision_resolver: EvilEngine.Persistence.DecisionResolverImpl,
  token_max_bytes: 65_536,
  dmn_evaluation_timeout_ms: 30_000,
  persistence_retry_max_attempts: 5,
  persistence_retry_initial_backoff_ms: 100

# --- ModelCache loader (auto-heal cache misses from DB) ------------------
config :core_bpmn,
  model_cache_loader: {EvilEngine.Persistence.ExecutionAdapter, :load_bpmn_xml}

config :core_dmn,
  model_cache_loader: {EvilEngine.Persistence.ExecutionAdapter, :load_dmn_xml},
  max_import_depth: 10

# --- Event sink modules ---------------------------------------------
# Maps sink names to their implementing modules. The database and websocket
# sinks live outside core_events, so we configure their modules here
# to avoid cross-domain imports.
config :core_events,
  sink_modules: %{
    "console" => EvilEngine.Events.Sinks.Console,
    "telemetry" => EvilEngine.Telemetry.Sink,
    "websocket" => EvilEngineWeb.Ws.Sinks.WebSocket
  },
  message_start_event_handler:
    {EvilEngine.Execution.MessageStartHandler, :start_processes_for_message},
  message_persistence_adapter: EvilEngine.Persistence.MessagePersistenceAdapter,
  signal_start_event_handler:
    {EvilEngine.Execution.SignalStartHandler, :start_processes_for_signal},
  signal_persistence_adapter: EvilEngine.Persistence.SignalPersistenceAdapter

# --- Auth provider registry (boundary injection) ----------------------
# peripheral_plugins (Peripheral) must not compile-depend on api_auth (API).
# The ProviderRegistry module reference is injected at runtime.
config :peripheral_plugins, auth_provider_registry: EvilEngine.Auth.ProviderRegistry

# --- Timers --------------------------------------------------
config :core_timers,
  tick_interval_ms: 1_000,
  timer_start_target: EvilEngine.Execution.TimerStartListener,
  persistence_module: EvilEngine.Persistence.TimerStartScheduleAdapter

# --- Telemetry -----------------------------------------------------------
# --- Telemetry -----------------------------------------------------------
# The in-process `:telemetry` counter set (§11) — no OTel/Prometheus in v1.
config :peripheral_telemetry,
  enabled: true,
  db_queue_time_warning_ms: 500

# --- GraphQL safety limits (S-4) -----------------------------------------
# Runtime overrides are read from EVIL_GRAPHQL_* in runtime.exs.
config :api_web,
  graphql_max_depth: 16,
  graphql_max_complexity: 1000,
  graphql_introspection_disabled: false

import_config "#{config_env()}.exs"
