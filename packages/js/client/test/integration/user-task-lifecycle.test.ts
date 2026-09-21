import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { BfwEngineClient } from '../../src/bfw-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  createReadOnlyClient,
  createLaneClient,
  createAdminBypassOnlyClient,
  createUnauthenticatedClient,
  deployFixture,
  cleanupInstances,
  waitForUserTask,
  waitForState,
} from '../support/test-engine.js';
import {
  FniNotWaitingError,
  NotFoundError,
  UnauthorizedError,
} from '@elraptorus/bfw_engine_sdk';

let adminClient: BfwEngineClient;
let readOnlyClient: BfwEngineClient;
let laneAccountingClient: BfwEngineClient;
let adminBypassClient: BfwEngineClient;
let unauthenticatedClient: BfwEngineClient;

const USER_TASK_ID = 'integration-user-task';
const USER_TASK_LANE_ID = 'integration-user-task-lane';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  readOnlyClient = await createReadOnlyClient();
  laneAccountingClient = await createLaneClient(['accounting']);
  adminBypassClient = await createAdminBypassOnlyClient();
  unauthenticatedClient = await createUnauthenticatedClient();
  await adminClient.notifications.connect();
  await deployFixture(adminClient, 'integration-user-task.bpmn');
  await deployFixture(adminClient, 'integration-user-task-lane.bpmn');
});

afterAll(async () => {
  if (!adminClient) {
    return;
  }
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

describe('User Task Lifecycle', { concurrent: false }, () => {
  describe('happy paths', () => {
    it('finishes a user task and process instance completes', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_ID);

      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);
      expect(flowNodeInstanceId).toBeDefined();
      expect(typeof flowNodeInstanceId).toBe('string');

      await adminClient.userTasks.finish(flowNodeInstanceId, { result: { approved: true } });

      await waitForState(adminClient, processInstanceId, 'finished');
    });

    it('cancels a user task and process instance aborts', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);

      await adminClient.userTasks.cancel(flowNodeInstanceId);

      await waitForState(adminClient, processInstanceId, 'aborted');
    });
  });

  describe('bad paths - finish and cancel', () => {
    it('rejects finish of nonexistent flow node instance', async () => {
      try {
        await adminClient.userTasks.finish('nonexistent-fni-id', { result: {} });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
      }
    });

    it('rejects finish of already-completed flow node instance', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);
      await adminClient.userTasks.finish(flowNodeInstanceId, { result: {} });
      await waitForState(adminClient, processInstanceId, 'finished');

      try {
        await adminClient.userTasks.finish(flowNodeInstanceId, { result: {} });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(FniNotWaitingError);
        if (error instanceof FniNotWaitingError) {
          expect(error.statusCode).toBe(422);
        }
      }
    });

    it('rejects cancel of already-completed flow node instance', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);
      await adminClient.userTasks.finish(flowNodeInstanceId, { result: {} });
      await waitForState(adminClient, processInstanceId, 'finished');

      try {
        await adminClient.userTasks.cancel(flowNodeInstanceId);
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(FniNotWaitingError);
      }
    });
  });

  describe('bad paths - lane visibility', () => {
    it('hides lane-gated user task from user without lane claim', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_LANE_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);

      try {
        await readOnlyClient.userTasks.finish(flowNodeInstanceId, { result: {} });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(NotFoundError);
      } finally {
        await adminClient.userTasks.finish(flowNodeInstanceId, { result: {} });
        await waitForState(adminClient, processInstanceId, 'finished');
      }
    });

    it('allows user with lane claim to finish', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_LANE_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);

      await laneAccountingClient.userTasks.finish(flowNodeInstanceId, { result: {} });
      await waitForState(adminClient, processInstanceId, 'finished');
    });

    it('admin bypass finishes lane-gated task', async () => {
      const { processInstanceId } = await adminClient.processes.start(USER_TASK_LANE_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient, processInstanceId);

      await adminBypassClient.userTasks.finish(flowNodeInstanceId, { result: {} });
      await waitForState(adminClient, processInstanceId, 'finished');
    });
  });

  describe('bad paths - authentication', () => {
    it('rejects finish without authentication', async () => {
      try {
        await unauthenticatedClient.userTasks.finish('any-id', { result: {} });
        expect.fail('Should have thrown');
      } catch (error) {
        expect(error).toBeInstanceOf(UnauthorizedError);
      }
    });
  });
});
