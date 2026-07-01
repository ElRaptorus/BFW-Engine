# Redis Cache Service Task — Example Plugin

Demonstrates registering a handler that issues Redis commands based on fields in
the token payload (`get`, `set`, `delete`).

## Async contract

Redis is an external system — even though calls are typically fast, the
connection can be down, slow, or partitioned. The handler validates the
operation synchronously, then spawns a Task for the Redis command and
completes the FNI through the engine facade.

## Stubbed commands

`RedisCacheHandler.redis_command/1` forwards to `RedisCacheConnection.stub_command/1`,
which keeps an in-memory map inside an Agent. In production, store a Redix
connection pid in the Agent (or a pool) and replace the body with:

```elixir
Redix.command!(connection_pid, command_parts)
```

## Docker one-liner

```bash
docker run --name evil-redis -p 6379:6379 -d redis:7-alpine
```

## Further reading

- [`EvilEngine.Plugin.ServiceTaskHandler`](../../../../apps/engine_sdk/lib/evil_engine/plugin/service_task_handler.ex)
- [`docs/architecture/plugins.md`](../../../../docs/architecture/plugins.md)
