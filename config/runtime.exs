# Runtime configuration read from the `TDE_*` environment variables
# documented in `docs/architecture/configuration.md`.
#
# This file runs at *release boot* (not compile time). Only directives
# here can shape the running system from the environment.
import Config

require Logger

defmodule EvilEngine.Config.Env do
  @moduledoc false

  @doc "Read an env var, fall back, and trim whitespace."
  @spec get(String.t(), String.t() | nil) :: String.t() | nil
  def get(name, default \\ nil) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.trim(value)
    end
  end

  @doc "Read an integer env var with a default."
  @spec get_int(String.t(), integer()) :: integer()
  def get_int(name, default) do
    case get(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  @doc "Read a boolean env var (true/false/on/off/1/0)."
  @spec get_bool(String.t(), boolean()) :: boolean()
  def get_bool(name, default) do
    case get(name) do
      nil -> default
      v when v in ["true", "on", "1", "yes"] -> true
      v when v in ["false", "off", "0", "no"] -> false
      _ -> default
    end
  end

  @doc """
  Read a comma- or whitespace-separated list env var.

  Returns `[]` for an unset / empty var. Order is preserved — important
  for `TDE_PLUGINS_INBEAM` where it dictates `on_load` invocation order
  (§9.2.2).
  """
  @spec get_list(String.t()) :: [String.t()]
  def get_list(name) do
    case get(name) do
      nil ->
        []

      raw ->
        raw
        |> String.split([",", " ", "\t", "\n"], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end

alias EvilEngine.Config.Env

# --- Persistence (§14.3) --------------------------------------------------
if config_env() == :prod do
  database_url = Env.get("TDE_DATABASE_URL")
  db_host = Env.get("TDE_DATABASE_HOST")

  repo_opts =
    cond do
      database_url ->
        [url: database_url]

      db_host ->
        [
          hostname: db_host,
          port: Env.get_int("TDE_DATABASE_PORT", 5432),
          database:
            Env.get("TDE_DATABASE_NAME") ||
              raise("TDE_DATABASE_NAME is required when using TDE_DATABASE_HOST"),
          username:
            Env.get("TDE_DATABASE_USER") ||
              raise("TDE_DATABASE_USER is required when using TDE_DATABASE_HOST"),
          password:
            Env.get("TDE_DATABASE_PASS") ||
              raise("TDE_DATABASE_PASS is required when using TDE_DATABASE_HOST")
        ]

      true ->
        raise """
        No database configuration found. Set either:
          - TDE_DATABASE_URL  (e.g. ecto://USER:PASS@HOST/DATABASE)
          - TDE_DATABASE_HOST + TDE_DATABASE_PORT + TDE_DATABASE_NAME +
            TDE_DATABASE_USER + TDE_DATABASE_PASS
        """
    end

  repo_opts =
    repo_opts
    |> Keyword.put(:pool_size, Env.get_int("TDE_DB_POOL_SIZE", 100))
    |> then(fn o ->
      if Env.get_bool("TDE_DB_IPV6", false),
        do: Keyword.put(o, :socket_options, [:inet6]),
        else: o
    end)
    |> then(fn o ->
      case Env.get_bool("TDE_DB_SSL", false) do
        true -> Keyword.put(o, :ssl, true)
        false -> o
      end
    end)

  config :peripheral_persistence, EvilEngine.Persistence.Repo, repo_opts

  read_repo_opts =
    repo_opts
    |> Keyword.put(:pool_size, Env.get_int("TDE_DB_READ_POOL_SIZE", 50))
    |> Keyword.delete(:pool)

  config :peripheral_persistence, EvilEngine.Persistence.ReadRepo, read_repo_opts

  secret_key_base =
    Env.get("TDE_HTTP_SECRET_KEY_BASE") ||
      raise """
      environment variable TDE_HTTP_SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  http_port = Env.get_int("TDE_HTTP_PORT", 4000)

  check_origin =
    case Env.get("TDE_WS_CHECK_ORIGIN", "false") do
      v when v in ["false", "off", "0"] -> false
      v when v in ["true", "on", "1"] -> true
      urls -> String.split(urls, ",", trim: true)
    end

  config :api_web, EvilEngineWeb.Http.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: http_port],
    secret_key_base: secret_key_base,
    check_origin: check_origin,
    server: true
end

# --- DB pool tuning (all environments) ------------------------------------
# CoDel queue parameters and checkout resilience. These apply to every Repo
# in every environment — prod, dev, and test all benefit from bounded retry
# and sane queue thresholds.
config :peripheral_persistence, :db_pool_tuning,
  checkout_retries: Env.get_int("TDE_DB_CHECKOUT_RETRIES", 3),
  queue_target: Env.get_int("TDE_DB_QUEUE_TARGET", 100),
  queue_interval: Env.get_int("TDE_DB_QUEUE_INTERVAL", 2000),
  timeout: Env.get_int("TDE_DB_CHECKOUT_TIMEOUT", 15_000)

# --- Developer UI gating (Swagger UI, GraphQL Playground, OpenAPI spec) ----
config :api_web,
  devtools_enabled: Env.get_bool("TDE_DEVTOOLS_ENABLED", config_env() != :prod),
  expose_openapi_spec: Env.get_bool("TDE_EXPOSE_OPENAPI_SPEC", false)

# --- Payload cap ----------------------------------
# Unset → 65536. Explicit values below 1024 refuse to boot (no silent clamp).
config :core_execution,
  token_max_bytes:
    EvilEngine.Execution.PayloadCap.parse_token_max_bytes(Env.get("TDE_TOKEN_MAX_BYTES")),
  persistence_retry_max_attempts: Env.get_int("TDE_PERSISTENCE_RETRY_MAX_ATTEMPTS", 5),
  persistence_retry_initial_backoff_ms:
    Env.get_int("TDE_PERSISTENCE_RETRY_INITIAL_BACKOFF_MS", 100)

# --- PI admission control (Layer 1) ----------------------------------
pi_limit =
  case Env.get("TDE_MAX_CONCURRENT_PIS", "infinity") do
    "infinity" ->
      :infinity

    raw ->
      n = String.to_integer(raw)

      if n < 1 do
        raise "TDE_MAX_CONCURRENT_PIS must be a positive integer or \"infinity\" (got #{inspect(raw)})"
      end

      n
  end

config :core_execution, :max_concurrent_process_instances, pi_limit

# --- Resume pagination (PF-1) ----------------------------------------------
resume_batch_size = Env.get_int("TDE_RESUME_BATCH_SIZE", 1000)

if resume_batch_size < 1 do
  raise "TDE_RESUME_BATCH_SIZE must be a positive integer (got #{inspect(resume_batch_size)})"
end

config :core_execution, :resume_batch_size, resume_batch_size

# --- Start rate limiting (Layer 2) -----------------------------------
config :api_web,
  pi_start_rate_limit: Env.get_int("TDE_PI_START_RATE_LIMIT", 0),
  pi_start_rate_window_ms: Env.get_int("TDE_PI_START_RATE_WINDOW_MS", 1000)

# --- GraphQL safety limits (S-4) -----------------------------------------
# TDE_GRAPHQL_MAX_DEPTH        — max field nesting depth (default 16, sized for Process Model recursion)
# TDE_GRAPHQL_MAX_COMPLEXITY   — max query complexity score (default 10000, sized for
#                                Studio debugger `dataObjectValues(limit: 500)` → score 6500)
# TDE_GRAPHQL_INTROSPECTION_DISABLED — "true" to block __schema / __type
graphql_max_depth = Env.get_int("TDE_GRAPHQL_MAX_DEPTH", 16)

if graphql_max_depth < 1 do
  raise "TDE_GRAPHQL_MAX_DEPTH must be a positive integer (got #{inspect(graphql_max_depth)})"
end

graphql_max_complexity = Env.get_int("TDE_GRAPHQL_MAX_COMPLEXITY", 10_000)

if graphql_max_complexity < 1 do
  raise "TDE_GRAPHQL_MAX_COMPLEXITY must be a positive integer (got #{inspect(graphql_max_complexity)})"
end

config :api_web,
  graphql_max_depth: graphql_max_depth,
  graphql_max_complexity: graphql_max_complexity,
  graphql_introspection_disabled: Env.get_bool("TDE_GRAPHQL_INTROSPECTION_DISABLED", false)

# --- Seeding directory -------------------------------------
config :core_bpmn, seeding_directory: Env.get("TDE_SEEDING_DIRECTORY")

# --- Timer precision ---------------------------------------
config :core_timers, tick_ms: Env.get_int("TDE_TIMER_TICK_MS", 1000)

# --- Event sinks -------------------------------------------
config :core_events,
  console_sink_enabled: Env.get_bool("TDE_EVENT_SINK_CONSOLE", true),
  telemetry_sink_enabled: Env.get_bool("TDE_EVENT_SINK_TELEMETRY", true),
  websocket_sink_enabled: Env.get_bool("TDE_EVENT_SINK_WEBSOCKET", true),
  log_min_severity: Env.get("TDE_LOG_MIN_SEVERITY", "info")

# --- Partitioning ----------------------------------------
partition_interval =
  case Env.get("TDE_PARTITION_INTERVAL", "quarterly") |> String.downcase() do
    v when v in ~w(monthly quarterly half_yearly yearly off) -> String.to_atom(v)
    _ -> :quarterly
  end

config :peripheral_persistence,
  partition_interval: partition_interval

# --- Retention ---------------------------------
config :peripheral_persistence, :retention,
  run_interval: Env.get("TDE_RETENTION_RUN_INTERVAL", "PT1H"),
  batch_size: Env.get_int("TDE_RETENTION_BATCH_SIZE", 500),
  finished_days: Env.get("TDE_RETENTION_FINISHED_DAYS"),
  error_days: Env.get("TDE_RETENTION_ERROR_DAYS"),
  fatal_days: Env.get("TDE_RETENTION_FATAL_DAYS"),
  aborted_days: Env.get("TDE_RETENTION_ABORTED_DAYS"),
  escalated_days: Env.get("TDE_RETENTION_ESCALATED_DAYS"),
  compensated_days: Env.get("TDE_RETENTION_COMPENSATED_DAYS"),
  cancelled_days: Env.get("TDE_RETENTION_CANCELLED_DAYS"),
  engine_audit_days: Env.get("TDE_RETENTION_ENGINE_AUDIT_DAYS"),
  partition_ahead_months: max(Env.get_int("TDE_PARTITION_AHEAD_MONTHS", 3), 1),
  jsonb_compression: Env.get("TDE_JSONB_COMPRESSION", "lz4"),
  pending_messages_keep_after_transition:
    Env.get_bool("TDE_PENDING_MESSAGES_KEEP_AFTER_TRANSITION", true),
  pending_signals_keep_after_transition:
    Env.get_bool("TDE_PENDING_SIGNALS_KEEP_AFTER_TRANSITION", true)

# --- Pending TTLs + sweeper --------------------------
config :core_events,
  message_pending_ttl: Env.get("TDE_MESSAGE_PENDING_TTL", "PT60S"),
  signal_pending_ttl: Env.get("TDE_SIGNAL_PENDING_TTL", "PT60S"),
  pending_sweeper_interval: Env.get_int("TDE_PENDING_SWEEPER_INTERVAL", 10_000)

# --- Linter-gate -------------------------------------------
config :core_bpmn, :linter_gate,
  rules: Env.get("TDE_LINTER_GATE"),
  skip_seeding: Env.get_bool("TDE_LINTER_GATE_SKIP_SEEDING", false)

# --- JWT -----------------------------------------------------
auth_disabled = Env.get_bool("TDE_AUTH_DISABLED", false)
hs256_secret = Env.get("TDE_JWT_HS256_SECRET")
jwks_url = Env.get("TDE_JWT_JWKS_URL")
jwks_refresh_seconds = Env.get_int("TDE_JWKS_REFRESH_SECONDS", 3600)

if auth_disabled != true and is_nil(hs256_secret) and is_nil(jwks_url) and config_env() == :prod do
  raise """
  No JWT key material configured and TDE_AUTH_DISABLED is not set.
  Set at least one of:
    - TDE_JWT_HS256_SECRET (min 32 bytes)
    - TDE_JWT_JWKS_URL
  Or set TDE_AUTH_DISABLED=true for development.
  """
end

if not is_nil(hs256_secret) and byte_size(hs256_secret) < 32 and config_env() == :prod do
  raise "TDE_JWT_HS256_SECRET must be at least 32 bytes (got #{byte_size(hs256_secret)})"
end

jwt_opts =
  [auth_disabled: auth_disabled, jwks_refresh_seconds: jwks_refresh_seconds]
  |> then(fn o -> if jwks_url, do: Keyword.put(o, :jwks_url, jwks_url), else: o end)
  |> then(fn o -> if hs256_secret, do: Keyword.put(o, :hs256_secret, hs256_secret), else: o end)
  |> then(fn o ->
    case Env.get("TDE_JWT_AUDIENCE") do
      nil -> o
      v -> Keyword.put(o, :audience, v)
    end
  end)
  |> then(fn o ->
    case Env.get("TDE_JWT_ISSUER") do
      nil -> o
      v -> Keyword.put(o, :issuer, v)
    end
  end)

config :api_auth, jwt_opts

# --- Engine identity ------------------------------------------------------
{:ok, hostname} = :inet.gethostname()

config :peripheral_telemetry,
  engine_id: Env.get("TDE_ENGINE_ID", to_string(hostname)),
  engine_name: Env.get("TDE_ENGINE_NAME", to_string(hostname))

# --- Prometheus metrics / DB pool telemetry ---------------------------------
config :peripheral_telemetry,
  metrics_enabled: Env.get_bool("TDE_METRICS_ENABLED", true),
  db_queue_time_warning_ms: Env.get_int("TDE_DB_QUEUE_TIME_WARNING_MS", 500)

# --- Plugin loading -----------------------------------
config :peripheral_plugins,
  inbeam_apps: Enum.map(Env.get_list("TDE_PLUGINS_INBEAM"), &String.to_atom/1),
  include_plugins: Env.get_list("TDE_PLUGINS_INCLUDE"),
  exclude_plugins: Env.get_list("TDE_PLUGINS_EXCLUDE")
