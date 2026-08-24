# Additional Plugin Behaviours

Beyond the primary Service Task, Event Sink, and API Extension behaviours, the engine provides extra extension points. **MonitoringPanel, TimerSource, DataStoreAdapter, and the plugin PersistenceAdapter are not implemented in v1** — registration is accepted and ignored at runtime so existing sketches still compile.

## MonitoringPanel

**Not in v1.** Would contribute a fragment to the admin HTML page. Registration is accepted and unused.

```elixir
@behaviour EvilEngine.Plugin.MonitoringPanel

@callback render(assigns :: map()) :: term()
@callback panel_title() :: String.t()
```

Registration:

```elixir
facade.register_monitoring_panel.(MyPlugin.StatusPanel)
```

## TimerSource

**Not in v1.** Would supply custom timer evaluation for non-standard timer dialects. Core timers already parse ISO 8601 date, duration, and cycle. Registration is accepted and unused.

```elixir
@behaviour EvilEngine.Plugin.TimerSource

@callback timer_type() :: atom()
@callback evaluate(definition :: String.t(), context :: map()) ::
            {:ok, DateTime.t()} | {:error, term()}
```

Registration:

```elixir
facade.register_timer_source.("cron", MyPlugin.CronTimer)
```

## DataStoreAdapter

**Not in v1.** BPMN DataStores are a parser no-op. Registration is accepted and unused. Do not imply write-through.

```elixir
@behaviour EvilEngine.Plugin.DataStoreAdapter

@callback store_id() :: String.t()
@callback read(key :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
@callback write(key :: String.t(), value :: term(), opts :: keyword()) :: :ok | {:error, term()}
```

Registration:

```elixir
facade.register_data_store_adapter.("redis-main", MyPlugin.RedisStore)
```

## NamedScript

Handles `<evil:scriptRef>` execution for a specific script key. Unique by key. The engine dispatches to the registered module when a Script Task has a matching `evil:scriptRef` value. Scripts are always synchronous — no handler parking.

```elixir
@behaviour EvilEngine.Plugin.NamedScript

@callback handle_enter(flow_node :: map(), payload :: map(), context :: map()) ::
            {:ok, map()} | {:error, term()}
```

The `flow_node` map includes `type_data` with `script_format`, `script`, `script_ref`, and other Script Task fields. The `payload` is the token payload after input mappings have been applied. The `context` contains the standard handler context (process model, identity, data objects, etc.).

Registration:

```elixir
facade.register_named_script.("my_validation", MyPlugin.CustomScript)
```

## Related

- [Getting Started](getting-started.md) -- plugin lifecycle and loading
- [Engine Facade Reference](engine-facade.md) -- registration API
