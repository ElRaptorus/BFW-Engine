import { FniNotWaitingError, NotFoundError, UnauthorizedError } from '@elraptorus/bfw_engine_sdk';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import type { BfwEngineClient } from '../../src/bfw-engine-client.js';
import {
  cleanupInstances,
  createAdminClient,
  createUnauthenticatedClient,
  deployFixture,
  ensureEngineReachable,
  waitForState,
  waitForUserTask,
} from '../support/test-engine.js';

let adminClient: BfwEngineClient;
let unauthenticatedClient: BfwEngineClient;

const MANUAL_TASK_ID = 'integration-manual-task';
const USER_TASK_ID = 'integration-user-task';
const ENTERED_PAYLOAD = { step: 'pack' };

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  unauthenticatedClient = await createUnauthenticatedClient();
  await adminClient.notifications.connect();
  await deployFixture(adminClient, 'integration-manual-task.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
});

afterAll(async () => {
  if (!adminClient) {
    return;
  }
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

async function startWaitingManualTask(): Promise<{ processInstanceId: string; flowNodeInstanceId: string }> {
  const { processInstanceId } = await adminClient.processes.start(MANUAL_TASK_ID, { payload: ENTERED_PAYLOAD });
  const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId, 15_000, 'manual_task');
  return { processInstanceId, flowNodeInstanceId };
}

describe('Manual Task Lifecycle', { concurrent: false }, () => {
  describe('happy paths', () => {
    it('confirms a manual task and the entered token passes through', async () => {
      const { processInstanceId, flowNodeInstanceId } = await startWaitingManualTask();

      await adminClient.manualTasks.confirm(flowNodeInstanceId);

      await waitForState(adminClient, processInstanceId, 'finished');

      const result = await adminClient.graphql.queryFlowNodeInstances({
        fields: ['id', 'state', 'outputToken'],
        filter: { id: { eq: flowNodeInstanceId } },
        pagination: { mode: 'offset', limit: 1, offset: 0 },
      });
      expect(result.data[0].state).toBe('finished');
      expect(result.data[0].outputToken).toEqual(ENTERED_PAYLOAD);
    });

    it('cancels a manual task and process instance aborts', async () => {
      const { processInstanceId, flowNodeInstanceId } = await startWaitingManualTask();

      await adminClient.manualTasks.cancel(flowNodeInstanceId, { reason: 'not needed' });

      await waitForState(adminClient, processInstanceId, 'aborted');
    });
  });

  describe('bad paths', () => {
    it('rejects confirm of a user task with NotFoundError', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);

      try {
        await adminClient.manualTasks.confirm(flowNodeInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
      } finally {
        await adminClient.userTasks.finish(flowNodeInstanceId, { values: {} });
        await waitForState(adminClient, processInstanceId, 'finished');
      }
    });

    it('rejects user task finish of a manual task with NotFoundError', async () => {
      const { processInstanceId, flowNodeInstanceId } = await startWaitingManualTask();

      try {
        await adminClient.userTasks.finish(flowNodeInstanceId, { values: {} });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
      } finally {
        await adminClient.manualTasks.confirm(flowNodeInstanceId);
        await waitForState(adminClient, processInstanceId, 'finished');
      }
    });

    it('rejects confirm of an already-confirmed manual task', async () => {
      const { processInstanceId, flowNodeInstanceId } = await startWaitingManualTask();
      await adminClient.manualTasks.confirm(flowNodeInstanceId);
      await waitForState(adminClient, processInstanceId, 'finished');

      try {
        await adminClient.manualTasks.confirm(flowNodeInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(FniNotWaitingError);
      }
    });

    it('rejects confirm without authentication', async () => {
      try {
        await unauthenticatedClient.manualTasks.confirm('any-id');
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(UnauthorizedError);
      }
    });
  });
});
