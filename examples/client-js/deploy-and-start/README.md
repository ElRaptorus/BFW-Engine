# deploy-and-start

Deploys a minimal BPMN process from disk and starts one instance.

## Prerequisites

- Engine HTTP API reachable (often from docker compose).
- `ENGINE_TOKEN`: JWT accepted by the engine (claims must allow deploy and start for the example process).

## Run

From `packages/js` after install:

```bash
pnpm --filter @bfw-engine/example-deploy-and-start start
```

Or from this directory:

```bash
pnpm start
```

Optional: `ENGINE_URL` (default `http://localhost:4000`).

## Expected output

Logs the deploy response, then the new process instance identifier and initial state (typically `running`). The example does not wait for completion.

## Test

`pnpm test` only registers a placeholder; integration against a live engine is left as a manual or CI step.
