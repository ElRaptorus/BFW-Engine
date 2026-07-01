# realtime-monitoring

Connects the Phoenix notification client, subscribes to `engine:events`, starts a short pass-through process, logs a few seconds of traffic, disposes the subscription, deletes the instance, and undeploys.

## Prerequisites

- Engine WebSocket URL derived from `ENGINE_URL` (or override via `DaemonEngineClient` options in your own code).
- JWT accepted by both HTTP and socket.

If HTTP and WebSocket use different ports in your environment, construct `DaemonEngineClient` with `{ wsUrl: ... }` (see client README).

## Run

```bash
pnpm --filter @daemonengine/example-realtime-monitoring start
```

## Expected output

Lines per `EngineEventEnvelope` with type and a small subset of payload fields when present.

## Test

Vitest placeholder only.
