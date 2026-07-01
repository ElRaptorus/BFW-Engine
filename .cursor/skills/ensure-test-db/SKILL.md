---
name: ensure-test-db
description: >-
  Ensure the PostgreSQL Docker container required by integration tests and the
  quality gate is running and ready. Use BEFORE running any command that touches
  the database: `mix quality`, `mix test.integration`, `mix test.full`,
  per-app tests in `peripheral_persistence`, or any test tagged `:integration`.
  Agents MUST NOT skip this step or report "DB not running" as an acceptable
  outcome.
---

# Ensure Test Database

**This skill is MANDATORY before any test run that requires PostgreSQL.**
Skipping it and reporting "PostgreSQL is not running" is NOT acceptable.

## When to use

Use this skill (i.e. execute the steps below) **before** running any of:

- `mix quality`
- `mix test.full`
- `mix test.integration`
- `mix test.conformance`
- `mix test` in `apps/peripheral_persistence/`
- Any individual test file tagged `@tag :integration`
- The thorough-review skill (§1 Quality Gate)

## Step 1: Check if the container exists and is running

```bash
docker inspect --format='{{.State.Running}}' evil-engine-postgres-test 2>/dev/null
```

- **Output `true`** → Container exists and is running. Skip to Step 3.
- **Output `false`** → Container exists but is stopped. Go to Step 2a.
- **Error / empty** → Container does not exist. Go to Step 2b.

## Step 2a: Start an existing stopped container

```bash
docker start evil-engine-postgres-test
```

Then proceed to Step 3.

## Step 2b: Create the container from scratch

Run the bootstrap script at the project root:

```bash
bash scripts/create-test-db.sh
```

This script:
1. Creates a `postgres:16-alpine` container named `evil-engine-postgres-test`
2. Exposes port **5543** (maps to container port 5432)
3. Sets credentials: user `evil_engine`, password `evil_engine`, database `evil_engine_dev`
4. Runs `MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate`

Then proceed to Step 3.

## Step 3: Verify the database is ready

```bash
docker exec evil-engine-postgres-test pg_isready -U evil_engine
```

Expected output contains `accepting connections`. If the container just
started, PostgreSQL may need a few seconds to initialize. Retry up to 3
times with a 2-second sleep between attempts.

## Step 4: Run pending migrations (if needed)

After schema changes, migrations may be pending:

```bash
MIX_ENV=test mix ecto.migrate
```

This is safe to run even when no migrations are pending — it exits
immediately with no side effects.

## Connection parameters (for reference)

These match `config/test.exs`:

| Parameter | Value |
|-----------|-------|
| Host | `localhost` |
| Port | `5543` |
| User | `evil_engine` |
| Password | `evil_engine` |
| Database | `evil_engine_test` (with optional `MIX_TEST_PARTITION` suffix) |
| Container name | `evil-engine-postgres-test` |
| Image | `postgres:16-alpine` |

## Troubleshooting

### Port 5543 already in use

Another process is occupying the port. Find it with `lsof -i :5543` or
`ss -tlnp | grep 5543` and stop it, or remove the stale container:

```bash
docker rm -f evil-engine-postgres-test
bash scripts/create-test-db.sh
```

### Container starts but tests still fail with "connection refused"

PostgreSQL may not be ready yet. Wait a few seconds and retry. The
`pg_isready` check in Step 3 is the authoritative readiness signal.

### "role evil_engine does not exist"

The container was recreated without the correct environment variables.
Remove and re-create:

```bash
docker rm -f evil-engine-postgres-test
bash scripts/create-test-db.sh
```
