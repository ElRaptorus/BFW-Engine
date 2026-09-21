# user-task-workflow

Deploys a process with a single user task, starts with a payload, locates the waiting user-task flow node instance via GraphQL, finishes the task, waits until the process instance is `finished`, then deletes the instance and undeploys.

## Prerequisites

- Engine with GraphQL and user-task REST endpoints.
- JWT must allow lane visibility for the task (no lane is set on the task in the sample BPMN, so a typical admin-style test token works).

## Run

```bash
pnpm --filter @bfw-engine/example-user-task-workflow start
```

## Expected output

Logs instance id, polling output for waiting FNIs, finish operation, and final `finished` state.

## Test

Placeholder Vitest todo only.
