# Implementing Persistence Adapters

**Not implemented in v1.** `facade.register_persistence_adapter` is accepted and ignored at runtime. This plugin behaviour is **not** `EvilEngine.Execution.Persistence` (the in-tree execution adapter swapped via `:core_execution, :persistence_adapter` config, which tests already use).

Do not treat this as write-through or as a PostgreSQL replacement.

## Behaviour (reserved)

```elixir
@behaviour EvilEngine.Plugin.PersistenceAdapter

@callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
@callback persist(changeset :: term(), state :: term()) :: {:ok, term()} | {:error, term()}
```

## Registration

Registration is unique per adapter id, but the runtime does not invoke the adapter in v1:

```elixir
def on_load(facade) do
  facade.register_persistence_adapter.("custom", MyPlugin.CustomPersistence)
  :ok
end
```

## Related

- [Getting Started](getting-started.md) -- plugin lifecycle
- [Database Administration](../operations/database.md) -- default persistence setup
