import { describe, expect, it } from 'vitest';

import { FlowNodeType, ProcessInstanceState } from '@elraptorus/daemonengine_sdk';
import type { AbortRequest, DeployResponse, FinishUserTaskRequest, StartRequest } from '@elraptorus/daemonengine_sdk';

describe('type-safe payloads', () => {
  it('constructs StartRequest with the expected optional fields', () => {
    const startRequest: StartRequest = {
      startEventId: 'Start_1',
      payload: { orderId: 'x' },
      businessKey: 'corr-1',
    };
    expect(startRequest.startEventId).toBe('Start_1');
    expect(startRequest.payload).toEqual({ orderId: 'x' });
    expect(startRequest.businessKey).toBe('corr-1');
  });

  it('constructs FinishUserTaskRequest with a result payload', () => {
    const finishUserTaskRequest: FinishUserTaskRequest = {
      result: { decision: 'confirmed', actorId: 'user-7' },
    };
    expect(finishUserTaskRequest.result).toBeDefined();
    expect(finishUserTaskRequest.result).toEqual({ decision: 'confirmed', actorId: 'user-7' });
  });

  it('constructs AbortRequest with a reason', () => {
    const abortRequest: AbortRequest = {
      reason: 'Customer cancelled before settlement.',
    };
    expect(abortRequest.reason).toBeDefined();
    expect(abortRequest.reason).toBe('Customer cancelled before settlement.');
  });

  it('constructs DeployResponse with deployed entries matching DeployResult shape', () => {
    const deployResponse: DeployResponse = {
      deployed: [
        { processModelId: 'order-fulfillment-demo', version: '2.1.0' },
        { processModelId: 'inventory-sync', version: '1.0.0' },
      ],
    };
    expect(Array.isArray(deployResponse.deployed)).toBe(true);
    expect(deployResponse.deployed).toHaveLength(2);
    expect(deployResponse.deployed[0]).toMatchObject({
      processModelId: 'order-fulfillment-demo',
      version: '2.1.0',
    });
    expect(deployResponse.deployed[1]).toMatchObject({
      processModelId: 'inventory-sync',
      version: '1.0.0',
    });
  });

  it('uses string enum values for runtime and wire compatibility', () => {
    expect(ProcessInstanceState.Running).toBe('running');
    expect(FlowNodeType.UserTask).toBe('user_task');
  });

  it('exposes the expected ProcessInstanceState members', () => {
    expect(new Set(Object.values(ProcessInstanceState))).toEqual(
      new Set([
        ProcessInstanceState.Running,
        ProcessInstanceState.Finished,
        ProcessInstanceState.Fatal,
        ProcessInstanceState.Aborted,
        ProcessInstanceState.Compensated,
        ProcessInstanceState.Escalated,
        ProcessInstanceState.Error,
        ProcessInstanceState.Cancelled,
      ]),
    );
  });
});
