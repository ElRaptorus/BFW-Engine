# batch-deploy

Deploys three distinct BPMN models in one REST call, lists the catalog, lists versions for `example-batch-process-a`, deploys `2.0.0` for the same process id from `process_a_v2.bpmn`, lists versions again, briefly disables and re-enables the process, deletes version `1.0.0`, and undeploys every sample model.

Extra BPMN file: `process_a_v2.bpmn` (same process id as `process_a.bpmn`, bumped `evil:version`).

## Prerequisites

- JWT with deploy and delete BPMN permissions.

## Run

```bash
pnpm --filter @daemonengine/example-batch-deploy start
```

## Expected output

Logs for each catalog and version step, then undeploy confirmations.

## Test

Vitest placeholder only.
