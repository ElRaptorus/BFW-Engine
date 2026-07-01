# error-handling

Runs a sequence of failing calls against a live engine to show typed errors from `@elraptorus/daemonengine_sdk`. The BPMN process ID is `example-error-handling-process` (deployed at startup, undeployed at the end).

Covered types:

- `ProcessNotFoundError` — start a model that is not deployed (the SDK name; there is no `ProcessModelNotFoundError` export).
- `NotFoundError` — `get` on an unknown model id.
- `UnauthorizedError` — second client with a broken JWT calling `engine.stats()`.
- `PayloadTooLargeError` — start with an oversized payload (tunable if your engine cap differs).
- `ValidationError` — shape is shown via `mapResponseError` from `@elraptorus/daemonengine_client` for an unmapped `422` body (real engines usually return more specific subclasses such as `DeployValidationFailedError`).
- `VersionExistsError` — deploy the same BPMN version twice.
- `DaemonEngineError` — duplicate BPMN strings in one `deploy` batch (`batch_conflict` / HTTP 409), which the mapper surfaces as the base class.

## Prerequisites

- Engine reachable; JWT with deploy and related permissions for the sample process.

## Run

```bash
pnpm --filter @daemonengine/example-error-handling start
```

## Test

Vitest placeholder only.
