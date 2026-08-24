# Quickstart

This guide walks you through setting up the engine locally, deploying a BPMN process, and starting your first process instance.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Elixir | 1.19.5 / OTP 28 | Runtime |
| Rust | 1.94+ | FEEL expression NIF (compiled at build time) |
| PostgreSQL | 16+ | Persistence (JSONB + LZ4) |
| asdf or mise | latest | Version management (optional but recommended) |

Install pinned versions from `.tool-versions`:

```bash
asdf install    # or: mise install
```

## Option A: Docker Compose (Recommended)

The fastest path. Engine + PostgreSQL in two containers:

```bash
docker compose up --build
```

- Engine (HTTP, GraphQL, WebSocket): `http://localhost:4000`
- PostgreSQL: `localhost:5432` (db: `evil_engine_dev`)

## Option B: Local Development

```bash
mix deps.get
mix compile
mix ash_postgres.migrate
mix evil.partitions.ensure
mix phx.server
```

## Mint a Dev Token

Authenticated endpoints require a JWT. The dev setup ships with a known HS256 secret:

```bash
# Quick admin token (24h expiry)
mix evil.mint_token

# Custom claims
mix evil.mint_token --sub operator-1 --roles admin,viewer --exp 3600
```

Store the token for subsequent requests:

```bash
export TOKEN=$(mix evil.mint_token)
```

See [Authentication](../api/authentication.md) for production JWT configuration.

## Deploy a BPMN Process

Every BPMN file must include the mandatory `<evil:version>` extension element. Minimal example:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                  xmlns:evil="https://evilengine.dev/schema/bpmn">
  <bpmn:process id="hello_world" isExecutable="true">
    <bpmn:extensionElements>
      <evil:version>1.0.0</evil:version>
    </bpmn:extensionElements>
    <bpmn:startEvent id="start"/>
    <bpmn:endEvent id="end"/>
    <bpmn:sequenceFlow id="flow1" sourceRef="start" targetRef="end"/>
  </bpmn:process>
</bpmn:definitions>
```

Deploy it:

```bash
curl -X POST http://localhost:4000/processes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sources": ["'"$(cat hello_world.bpmn)"'"]}'
```

A successful deploy returns `201` with the deployed process details. See [Deploying Processes](../handbook/deploying-processes.md) for batch deploys, versioning, and the linter gate.

## Start a Process Instance

```bash
curl -X POST http://localhost:4000/processes/hello_world/start \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"payload": {"greeting": "Hello, World!"}}'
```

The response includes the `process_instance_id` and current state. See [Starting Process Instances](../handbook/starting-instances.md) for start event resolution and payload details.

## Check Engine Health

No authentication required:

```bash
curl http://localhost:4000/health
# {"status":"ok","uptime_seconds":42}

curl http://localhost:4000/info
# {"engine_id":"...","engine_name":"...","version":"0.0.1","auth_disabled":false}
```

## Next Steps

- [Core Concepts](concepts.md) -- understand the engine's domain model
- [REST API Reference](../api/rest-reference.md) -- full endpoint documentation
- [GraphQL API Reference](../api/graphql-reference.md) -- read-only queries (no mutations or subscriptions)
- [Operations Guide](../operations/deployment.md) -- production deployment
