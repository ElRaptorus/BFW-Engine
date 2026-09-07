/**
 * WebSocket event integration tests.
 *
 * Most event-specific tests are skipped because the current engine channel
 * architecture has a fundamental race condition: you cannot subscribe to a
 * process-instance channel before knowing the PI ID, which only exists
 * after the process has started — by which time early events have already
 * been emitted. A redesign of the channel/topic model is needed before
 * these tests can be made reliable. See the Batch 5 review notes.
 *
 * The connection lifecycle and PI-scoped channel isolation tests are
 * stable and remain active.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import type { EngineEventEnvelope } from '@elraptorus/daemonengine_sdk';
import {
  ensureEngineReachable,
  createAdminClient,
  deployFixture,
  cleanupInstances,
  waitForUserTask,
  waitForState,
} from '../support/test-engine.js';

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

let adminClient: DaemonEngineClient | undefined;

const USER_TASK_ID = 'integration-user-task';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  await adminClient.notifications.connect();
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
});

afterAll(async () => {
  if (adminClient === undefined) {
    return;
  }
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

describe('WebSocket Events', { concurrent: false }, () => {
  describe('connection lifecycle', () => {
    it('connect resolves when notifications are established in beforeAll', () => {
      expect(adminClient).toBeDefined();
      expect(adminClient!.notifications).toBeDefined();
    });

    it('disconnect and reconnect work cleanly', async () => {
      adminClient!.notifications.disconnect();
      await adminClient!.notifications.connect();
    });

    it('subscription dispose stops handler calls', async () => {
      const { processInstanceId } = await adminClient!.processes.start(USER_TASK_ID);
      const flowNodeInstanceId = await waitForUserTask(adminClient!, processInstanceId);
      let handlerInvocationCount = 0;
      const subscription = await adminClient!.notifications.subscribeProcessInstance(
        processInstanceId,
        () => {
          handlerInvocationCount += 1;
        },
      );
      subscription.dispose();
      await adminClient!.userTasks.finish(flowNodeInstanceId, { result: { approved: true } });
      await waitForState(adminClient!, processInstanceId, 'finished');
      await sleep(500);
      expect(handlerInvocationCount).toBe(0);
      await adminClient!.processInstances.delete(processInstanceId);
    });
  });

  describe('PI-scoped channel filtering', () => {
    it('does not deliver another process instance events to a single-instance subscription', async () => {
      const firstStartResult = await adminClient!.processes.start(USER_TASK_ID);
      const firstProcessInstanceId = firstStartResult.processInstanceId;
      const firstFlowNodeInstanceId = await waitForUserTask(adminClient!, firstProcessInstanceId);

      const receivedForFirstChannel: EngineEventEnvelope[] = [];
      const firstSubscription = await adminClient!.notifications.subscribeProcessInstance(
        firstProcessInstanceId,
        (event: EngineEventEnvelope) => {
          receivedForFirstChannel.push(event);
        },
      );

      const secondStartResult = await adminClient!.processes.start(USER_TASK_ID);
      const secondProcessInstanceId = secondStartResult.processInstanceId;
      const secondFlowNodeInstanceId = await waitForUserTask(adminClient!, secondProcessInstanceId);

      await adminClient!.userTasks.finish(secondFlowNodeInstanceId, { result: {} });
      await waitForState(adminClient!, secondProcessInstanceId, 'finished');
      await sleep(1000);

      firstSubscription.dispose();

      for (const event of receivedForFirstChannel) {
        if ('processInstanceId' in event.data) {
          const dataRecord = event.data as { processInstanceId: string };
          expect(dataRecord.processInstanceId).toBe(firstProcessInstanceId);
        }
      }

      await adminClient!.userTasks.finish(firstFlowNodeInstanceId, { result: {} });
      await waitForState(adminClient!, firstProcessInstanceId, 'finished');
      await adminClient!.processInstances.delete(firstProcessInstanceId);
      await adminClient!.processInstances.delete(secondProcessInstanceId);
    });
  });

  /**
   * The tests below are skipped due to the subscribe-before-start race
   * condition. They will be re-enabled once the engine channel architecture
   * supports reliable event delivery for events emitted during process startup.
   */
  describe.skip('ProcessInstanceStateChanged (pending channel redesign)', () => {
    it.todo('emits null→running and running→finished transitions');
  });

  describe.skip('FlowNodeInstanceStarted (pending channel redesign)', () => {
    it.todo('includes flow node metadata on process channel');
  });

  describe.skip('FlowNodeInstanceFinished (pending channel redesign)', () => {
    it.todo('includes terminal state and flow node type');
  });

  describe.skip('UserTaskCreated (pending channel redesign)', () => {
    it.todo('includes assignees array and identifiers');
  });

  describe.skip('UserTaskFinished (pending channel redesign)', () => {
    it.todo('emits outcome completed');
    it.todo('emits outcome aborted');
  });

  describe.skip('UserTaskValidationFailed (pending channel redesign)', () => {
    it.todo('emits violations when result breaks contract');
  });

  describe.skip('CallActivityChildStarted (pending channel redesign)', () => {
    it.todo('links parent instance to child process identity and version');
  });

  describe.skip('DataObjectWritten (pending channel redesign)', () => {
    it.todo('records write metadata and value after service task output');
  });
});
