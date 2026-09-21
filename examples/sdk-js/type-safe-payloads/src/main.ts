import type {
  AbortRequest,
  DeployResponse,
  FinishUserTaskRequest,
  ProcessModel,
  StartRequest,
  StartResult,
} from '@elraptorus/bfw_engine_sdk';
import {
  FlowNodeInstanceState,
  FlowNodeType,
  ProcessInstanceState,
} from '@elraptorus/bfw_engine_sdk';

export async function main(): Promise<void> {
  const startRequest: StartRequest = {
    startEventId: 'Start_order_message',
    payload: { orderId: 'order-42', approved: true },
    businessKey: 'ref-demo-001',
  };

  const finishUserTaskRequest: FinishUserTaskRequest = {
    result: { decision: 'confirmed', actorId: 'user-7' },
  };

  const abortRequest: AbortRequest = {
    reason: 'Customer cancelled before settlement.',
  };

  const deployResponse: DeployResponse = {
    deployed: [
      { processModelId: 'order-fulfillment-demo', version: '2.1.0' },
    ],
  };

  const startResult: StartResult = {
    processInstanceId: '00000000-0000-0000-0000-000000000001',
    processModelId: 'order-fulfillment-demo',
    version: '2.1.0',
    state: 'running',
  };

  const processModelShape: ProcessModel = {
    id: 'internal-uuid-or-bpmn-id-depending-on-wire',
    processModelId: 'order-fulfillment-demo',
    definitionsId: 'Definitions_order_demo',
    version: '2.1.0',
    name: 'Order fulfillment demo',
    enabled: true,
  };

  const stateIllustrations = {
    processRunning: ProcessInstanceState.Running,
    flowNodeWaiting: FlowNodeInstanceState.Waiting,
    flowNodeKind: FlowNodeType.UserTask,
  };

  console.log('StartRequest\n', JSON.stringify(startRequest, null, 2));
  console.log('FinishUserTaskRequest\n', JSON.stringify(finishUserTaskRequest, null, 2));
  console.log('AbortRequest\n', JSON.stringify(abortRequest, null, 2));
  console.log('DeployResponse\n', JSON.stringify(deployResponse, null, 2));
  console.log('StartResult\n', JSON.stringify(startResult, null, 2));
  console.log('ProcessModel (illustrative)\n', JSON.stringify(processModelShape, null, 2));
  console.log('Enum illustrations\n', JSON.stringify(stateIllustrations, null, 2));

  /*
  The assignments below do not type-check under strict TypeScript:

  const brokenStartRequest: StartRequest = { startEventId: 42 };
  const brokenPayloadKey: StartRequest = { payload: 'not-a-record' };
  const brokenFinishShape: FinishUserTaskRequest = { result: 'string' };
  const brokenAbort: AbortRequest = { reason: 404 };
  const brokenStartResult: StartResult = { ...startResult, state: 'finished' };
  const brokenEnumAssign: ProcessInstanceState = 'RUNNING';
  const brokenEnumCompare = ProcessInstanceState.Running === 'RUNNING';
  */
}

main().catch(console.error);
