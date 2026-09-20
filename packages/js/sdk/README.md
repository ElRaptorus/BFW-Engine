# @elraptorus/daemonengine_sdk

Type definitions, error classes, event types, BPMN XML and DMN 1.5 parsers for ThomasTheDaemonEngine.

This package is the **contract layer** between the engine and all consumers (the client library, plugins, and third-party integrations). It contains no runtime network code -- only types, lightweight parsers, and error constructors.

## Installation

```bash
pnpm add @elraptorus/daemonengine_sdk
# or
npm install @elraptorus/daemonengine_sdk
```

## BPMN Parser

Parse BPMN 2.0 XML (with `evil:*` extensions) into a typed model:

```typescript
import { parseBpmn } from '@elraptorus/daemonengine_sdk';

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                  xmlns:evil="https://evilengine.dev/schema/bpmn"
                  id="Definitions_1">
  <bpmn:process id="my-process" isExecutable="true">
    <bpmn:extensionElements>
      <evil:version>1.0.0</evil:version>
    </bpmn:extensionElements>
    <bpmn:startEvent id="Start_1">
      <bpmn:outgoing>Flow_1</bpmn:outgoing>
    </bpmn:startEvent>
    <bpmn:endEvent id="End_1">
      <bpmn:incoming>Flow_1</bpmn:incoming>
    </bpmn:endEvent>
    <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
  </bpmn:process>
</bpmn:definitions>`;

const model = parseBpmn(xml);
console.log(model.processes[0].id);        // "my-process"
console.log(model.processes[0].version);   // "1.0.0"
```

## DMN Parser

Parse DMN 1.5 XML into a typed model covering all CL3 elements (decision tables, literal expressions, all boxed expression types, Decision Services, BKMs, DMNDI). Same structure as the engine's DMN parser:

```typescript
import { readFileSync } from 'node:fs';
import { parseDmn, DmnHitPolicy, type DmnDecisionTable } from '@elraptorus/daemonengine_sdk';

const xml = readFileSync('discount.dmn', 'utf8');
const definitions = parseDmn(xml);

console.log(definitions.id, definitions.name);
for (const decision of definitions.decisions) {
  const table = decision.expression as DmnDecisionTable;
  if (!table) continue;
  console.log(decision.id, table.hitPolicy, table.rules.length);
  if (table.hitPolicy === DmnHitPolicy.Unique) {
    console.log('UNIQUE hit policy');
  }
}
```

## Type Imports

```typescript
import type {
  ProcessModel,
  ProcessInstance,
  FlowNodeInstance,
  StartResult,
  DeployResponse,
  StatsResponse,
  EngineInfoResponse,
  DmnDefinitions,
  DmnDecision,
  DmnDecisionTable,
  DmnInput,
  DmnOutput,
  DmnRule,
  DmnInputEntry,
  DmnOutputEntry,
  DmnDeployResponse,
  EvaluationResult,
  EvaluationTrace,
  DecisionTrace,
  InputTrace,
  RuleTrace,
  InputEntryTrace,
  AdHocActivity,
  AdHocActivateResult,
  AdHocStatus,
  AdHocCompleteResult,
} from '@elraptorus/daemonengine_sdk';
```

## Error Class Hierarchy

All errors extend `DaemonEngineError`, which carries `statusCode`, `errorCode`, `message`, and `rawBody`. Use `instanceof` to narrow:

```typescript
import {
  DaemonEngineError,
  NotFoundError,
  ForbiddenError,
  ProcessDisabledError,
  ParseError,
  VersionExistsError,
  UnauthorizedError,
} from '@elraptorus/daemonengine_sdk';

try {
  await client.processes.start('my-process');
} catch (error) {
  if (error instanceof ProcessDisabledError) {
    console.log('Process is disabled:', error.message);
  } else if (error instanceof ForbiddenError) {
    console.log('Missing claim:', error.requiredClaim);
  } else if (error instanceof DaemonEngineError) {
    console.log('Engine error:', error.statusCode, error.errorCode);
  }
}
```

Full error class list:

| Class | Error Code | HTTP Status |
|-------|-----------|-------------|
| `UnauthorizedError` | (status-based) | 401 |
| `ForbiddenError` | `forbidden` | 403 |
| `NotFoundError` | (status-based) | 404 |
| `ProcessNotFoundError` | `process_not_found` | 404 |
| `ProcessDisabledError` | `process_disabled` | 422 |
| `ParseError` | `parse_error` | 400/422 |
| `VersionExistsError` | `version_exists` | 409 |
| `ActiveInstancesExistError` | `active_instances_exist` | 409 |
| `ProcessInstanceAlreadyTerminalError` | `process_already_terminal` | 422 |
| `ProcessInstanceNotTerminalError` | `process_instance_not_terminal` | 422 |
| `ProcessInstanceNotRetriableError` | `process_instance_not_retriable` | 422 |
| `IncompatibleVersionMigrationError` | `version_migration_incompatible` | 422 |
| `FniNotWaitingError` | `fni_not_waiting`, `fni_already_finished`, `fni_already_aborted`, `fni_already_interrupted`, `fni_already_fatal` | 422 |
| `DeployValidationFailedError` | `validation_failed` | 422 |
| `LinterGateFailedError` | `linter_gate_failed` | 422 |
| `ContractViolationError` | `contract_violation` | 422 |
| `PayloadTooLargeError` | `payload_too_large` | 413 |
| `RateLimitedError` | `rate_limited` | 429 |
| `EngineAtCapacityError` | `engine_at_capacity` | 503 |
| `ServiceUnavailableError` | `service_unavailable` | 503 |
| `InternalEngineError` | `internal_error` | 500 |
| `DecisionDefinitionNotFoundError` | `decision_definition_not_found` | 404 |
| `DecisionVersionNotFoundError` | `decision_version_not_found` | 404 |
| `DecisionVersionExistsError` | `decision_version_exists` | 409 |
| `DecisionDefinitionDisabledError` | `decision_definition_disabled` | 422 |
| `DmnParseError` | `dmn_parse_error` | 400 |
| `DmnEvaluationError` | `dmn_evaluation_error` | 422 |
| `DmnCycleError` | `dmn_cycle_error` | 422 |
| `BkmNotFoundError` | `bkm_not_found` | 404 |
| `DecisionServiceNotFoundError` | `service_not_found` | 404 |
| `RetryCheckpointInsideAdhocSubprocessError` | `retry_checkpoint_inside_adhoc_subprocess` | 422 |
| `RetryInsideAdhocSubprocessError` | `retry_inside_adhoc_subprocess` | 422 |
| `RetryCheckpointIsNonRetryableError` | `retry_checkpoint_is_non_retryable` | 422 |
| `NotATimerEventError` | `not_a_timer_event` | 422 |
| `DispatchFailedError` | `dispatch_failed` | 500 |
| `ConflictError` | `conflict` | 409 |
| `BadRequestError` | `bad_request` | 400 |
| `NoMatchingConditionError` | `no_matching_condition` | 422 |
| `NoDecisionsError` | `no_decisions` | 422 |

## Plugin types

`EngineFacade` mirrors the in-BEAM Elixir facade passed to plugin `on_load` / `on_ready`. PersistenceAdapter, MonitoringPanel, TimerSource, and DataStoreAdapter plugin capabilities do not exist — do not register them.

## WebSocket Event Types

```typescript
import type {
  EngineEventEnvelope,
  ProcessInstanceStateChanged,
  ProcessInstanceRetried,
  FlowNodeInstanceStarted,
  FlowNodeInstanceFinished,
  UserTaskCreated,
  UserTaskFinished,
  CallActivityChildStarted,
  DataObjectWritten,
  AdHocActivityActivated,
  AdHocSubProcessCompleted,
} from '@elraptorus/daemonengine_sdk';
```

`SubProcessChildStarted` also carries an `isAdHocSubprocess` boolean discriminating ad-hoc sub-process children from embedded/transaction/event sub-process children.

## License

MIT
