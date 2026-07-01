# Implementing Persistence Adapters

A Persistence Adapter replaces or chains the default AshPostgres persistence layer. This is an advanced extension point for engines that need non-standard storage backends or additional persistence logic.

## Behaviour

```elixir
@behaviour EvilEngine.Plugin.PersistenceAdapter

@callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
@callback persist(changeset :: term(), state :: term()) :: {:ok, term()} | {:error, term()}
```

## Registration

Registration is unique. If `chain: true` is set, the adapter chains after the default; otherwise, last-wins replaces it:

```elixir
def on_load(facade) do
  facade.register_persistence_adapter.("custom", MyPlugin.CustomPersistence)
  :ok
end
```

## Use Cases

- Write-through to an external audit system
- Replicate to a secondary database
- Replace PostgreSQL with a different storage engine

## Related

- [Getting Started](getting-started.md) -- plugin lifecycle
- [Database Administration](../operations/database.md) -- default persistence setup
