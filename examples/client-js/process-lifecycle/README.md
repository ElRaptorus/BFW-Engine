# process-lifecycle

Deploys a pass-through process, observes the first run until it reaches a terminal state via GraphQL polling, then starts a second instance, aborts it, verifies `aborted`, deletes it, and undeploys the model.

## Prerequisites

- Running engine with GraphQL enabled.
- JWT with deploy, start, abort, delete process instance, and delete BPMN rights as needed.

## Run

```bash
pnpm --filter @bfw-engine/example-process-lifecycle start
```

## Expected output

State transitions logged for the first instance until it completes. Abort and delete steps logged for the second. Undeploy completes the cleanup.

## Test

Vitest file is a placeholder only.
