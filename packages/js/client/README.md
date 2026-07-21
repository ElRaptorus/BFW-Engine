# @elraptorus/daemonengine_client

TypeScript client for ThomasTheDaemonEngine -- REST, GraphQL, and WebSocket access to the BPMN 2.0 workflow engine.

## Installation

```bash
pnpm add @elraptorus/daemonengine_client @elraptorus/daemonengine_sdk
# or
npm install @elraptorus/daemonengine_client @elraptorus/daemonengine_sdk
```

The SDK is a peer dependency that provides all type definitions and error classes.

## Quick Start

```typescript
import { DaemonEngineClient } from '@elraptorus/daemonengine_client';

const client = new DaemonEngineClient('http://localhost:4100', 'your-jwt-token');

// Deploy a BPMN process
const bpmnXml = '...';
const { deployed } = await client.processes.deploy(bpmnXml);
console.log('Deployed:', deployed[0].processModelId, deployed[0].version);

// Start a process instance
const { processInstanceId } = await client.processes.start('my-process', {
  payload: { orderId: '12345' },
});

// Finish a user task
await client.userTasks.finish(flowNodeInstanceId, {
  result: { approved: true },
});

// Clean up
client.dispose();
```

## Authentication

The client accepts a JWT factory -- either a static token string or an async function that produces one. The factory is called before every request, enabling automatic token refresh:

```typescript
// Static token
const client = new DaemonEngineClient(url, 'eyJhbGciOiJIUzI1NiI...');

// Async factory for token refresh
const client = new DaemonEngineClient(url, async () => {
  const response = await fetch('/auth/token');
  const { token } = await response.json();
  return token;
});
```

## REST Sub-Clients

```typescript
// Process catalog
await client.processes.getAll();
await client.processes.get('my-process');
await client.processes.get('my-process', { includeXml: true });
await client.processes.getVersions('my-process');
await client.processes.deploy(bpmnXml);
await client.processes.start('my-process', { payload: { key: 'value' } });
await client.processes.enable('my-process');
await client.processes.disable('my-process');
await client.processes.undeploy('my-process');
await client.processes.deleteVersion('my-process', '1.0.0');

// Process instances
await client.processInstances.abort(processInstanceId);
await client.processInstances.delete(processInstanceId);

// User tasks
await client.userTasks.finish(flowNodeInstanceId, { result: { approved: true } });
await client.userTasks.cancel(flowNodeInstanceId);

// Engine introspection
await client.engine.health();
const info = await client.engine.info();
const stats = await client.engine.stats();
const metrics = await client.engine.metrics();
```

## Decision Management (DMN)

Deploy DMN XML, drive the catalog, and evaluate decision tables over REST. IDs are DMN **definitions** IDs (`definitions/@id` in the XML), matching `DecisionDefinition.id` from the GraphQL API.

```typescript
// Deploy one or more DMN documents (atomic batch)
const { deployed } = await client.decisions.deploy(dmnXmlString);
console.log(deployed[0].decisionDefinitionId, deployed[0].version);

// Catalog
await client.decisions.getAll();
await client.decisions.get('my-definitions-id', { includeXml: true });
await client.decisions.getVersions('my-definitions-id');

// Evaluate latest active version
const evaluation = await client.decisions.evaluate(
  'my-definitions-id',
  { customerType: 'gold', orderTotal: 150 },
  { includeUnmatchedDetails: true /* optional execution trace detail */ },
);

// Evaluate a Decision Service (scoped sub-DRG)
const serviceResult = await client.decisions.evaluateService(
  'my-definitions-id',
  'MyDecisionService',
  { Age: 30, Income: 50000 },
);

// Lifecycle
await client.decisions.enable('my-definitions-id');
await client.decisions.disable('my-definitions-id');
await client.decisions.deleteVersion('my-definitions-id', '1.0.0');
await client.decisions.undeploy('my-definitions-id');
```

## Ad-hoc Sub-Process Control

`client.adHocSubprocesses` drives plugin-managed Ad-hoc Sub-Processes (a `bpmn:AdHocSubProcess` with an `implementation` attribute set). All methods take the ad-hoc shell's **child process instance ID**, not the parent process instance or the shell flow node instance ID.

```typescript
// List inner activities with their enablement / activation state
const activities = await client.adHocSubprocesses.getActivities(childProcessInstanceId);
// [{ id, name, type, enabled, performedCount, activeCount }, ...]

// Activate a specific inner activity
const { flowNodeInstanceId } = await client.adHocSubprocesses.activate(
  childProcessInstanceId,
  'AdHocTask_1',
);

// Signal that no further activities should be started; waits for in-flight activities to finish
const { completed } = await client.adHocSubprocesses.complete(childProcessInstanceId);

// Poll current status (active count, performed/enabled activity IDs, completion signal)
const status = await client.adHocSubprocesses.getStatus(childProcessInstanceId);
```

Engine-managed Ad-hoc Sub-Processes (no `implementation` attribute) do not require any of these calls — the engine drives activation and completion itself based on `ordering`, `completionCondition`, and `evil:ActiveElements`. Real-time notifications for both modes (`AdHocActivityActivated`, `AdHocSubProcessCompleted`) arrive over `client.notifications`, not this REST sub-client — see [WebSocket Event Subscriptions](#websocket-event-subscriptions).

## GraphQL Typed Queries

The GraphQL client provides fully typed field selection, filtering, sorting, pagination, and relationship loading -- no raw GraphQL strings needed:

```typescript
// Offset pagination
const { data, pageInfo } = await client.graphql.queryProcessInstances({
  fields: ['id', 'state', 'processModelId', 'startedAt'],
  filter: { state: { eq: 'running' } },
  sort: [{ field: 'startedAt', direction: 'desc' }],
  pagination: { mode: 'offset', limit: 20, offset: 0 },
});

// Cursor pagination
const result = await client.graphql.queryProcessInstances({
  fields: ['id', 'state'],
  pagination: { mode: 'cursor', first: 10 },
});

// Get single with nested includes
const instance = await client.graphql.getProcessInstance(processInstanceId, {
  fields: ['id', 'state', 'startedAt'],
  include: {
    flowNodeInstances: { fields: ['id', 'state', 'flowNodeId', 'flowNodeType'] },
  },
});

// Raw GraphQL escape hatch
const result = await client.graphql.raw<{ processModels: unknown }>(
  `query { processModels { results { id name } } }`,
);
```

## WebSocket Event Subscriptions

Real-time engine event notifications via Phoenix Channels:

```typescript
// Connect
await client.notifications.connect();

// Engine-wide events
const subscription = client.notifications.onEngineEvent((event) => {
  switch (event.type) {
    case 'ProcessInstanceStateChanged':
      console.log(event.data.processInstanceId, event.data.oldState, '->', event.data.newState);
      break;
    case 'UserTaskCreated':
      console.log('New user task:', event.data.flowNodeInstanceId);
      break;
  }
});

// Process instance-scoped events
const piSubscription = await client.notifications.subscribeProcessInstance(
  processInstanceId,
  (event) => {
    console.log('PI event:', event.type, event.data);
  },
);

// Unsubscribe
subscription.dispose();
piSubscription.dispose();

// Disconnect
client.notifications.disconnect();
// or
client.dispose();
```

## Error Handling

All errors thrown by the client are instances of `DaemonEngineError` (from `@elraptorus/daemonengine_sdk`). Use `instanceof` to narrow to specific error types:

```typescript
import {
  DaemonEngineError,
  ProcessDisabledError,
  ForbiddenError,
  NotFoundError,
  UnauthorizedError,
  DecisionDefinitionNotFoundError,
  DmnEvaluationError,
  DmnParseError,
} from '@elraptorus/daemonengine_sdk';

try {
  await client.processes.start('my-process');
} catch (error) {
  if (error instanceof UnauthorizedError) {
    console.log('Token expired or invalid');
  } else if (error instanceof ForbiddenError) {
    console.log('Missing claim:', error.requiredClaim);
  } else if (error instanceof ProcessDisabledError) {
    console.log('Process is disabled');
  } else if (error instanceof NotFoundError) {
    console.log('Resource not found');
  } else if (error instanceof DaemonEngineError) {
    console.log('Engine error:', error.statusCode, error.errorCode, error.message);
    console.log('Raw body:', error.rawBody);
  }
}
```

Decision-related subclasses (also thrown by `client.decisions.*`):

| Class | Typical cause |
|-------|---------------|
| `DecisionDefinitionNotFoundError` | Unknown definitions ID or undeployed decision |
| `DecisionDefinitionDisabledError` | Evaluation requested while definition is disabled |
| `DecisionVersionNotFoundError` | Referenced semantic version does not exist |
| `DecisionVersionExistsError` | Deploy would create a duplicate stored version |
| `DecisionServiceNotFoundError` | Decision Service ID does not exist in the model |
| `DmnParseError` | DMN XML failed validation at deploy time |
| `DmnEvaluationError` | Evaluation failed (hit policy, FEEL, missing inputs, etc.) |

## License

MIT
