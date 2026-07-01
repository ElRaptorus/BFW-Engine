import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  deployFixture,
  waitForState,
  cleanupInstances,
} from '../support/test-engine.js';

const SIGNAL_CATCH_PROCESS_ID = 'IntegrationSignalCatch';
const MESSAGE_CATCH_PROCESS_ID = 'IntegrationMessageCatch';

describe('Event Trigger Integration', () => {
  let adminClient: DaemonEngineClient;

  beforeAll(async () => {
    await ensureEngineReachable();
    adminClient = await createAdminClient();
    await deployFixture(adminClient, [
      'integration-signal-catch.bpmn',
      'integration-message-catch.bpmn',
    ]);
  });

  afterAll(async () => {
    await cleanupInstances(adminClient);
  });

  describe('triggerSignal', () => {
    it('delivers signal to a waiting catch event and PI finishes', async () => {
      const startResult = await adminClient.processes.start(SIGNAL_CATCH_PROCESS_ID);
      const processInstanceId = startResult.processInstanceId;

      await waitForCatchWaiting(adminClient, processInstanceId);

      const triggerResult = await adminClient.events.triggerSignal('integration-test-signal');

      expect(triggerResult.signalName).toBe('integration-test-signal');
      expect(triggerResult.signalId).toBeTruthy();
      expect(triggerResult.deliveries.length).toBeGreaterThanOrEqual(1);
      expect(triggerResult.pending).toBe(false);

      await waitForState(adminClient, processInstanceId, 'finished');
    });

    it('returns pending when no subscriber is active', async () => {
      const triggerResult = await adminClient.events.triggerSignal('no-subscriber-signal');

      expect(triggerResult.signalName).toBe('no-subscriber-signal');
      expect(triggerResult.deliveries).toEqual([]);
      expect(triggerResult.pending).toBe(true);
    });
  });

  describe('triggerMessage', () => {
    it('delivers message to a waiting catch event and PI finishes', async () => {
      const startResult = await adminClient.processes.start(MESSAGE_CATCH_PROCESS_ID);
      const processInstanceId = startResult.processInstanceId;

      await waitForCatchWaiting(adminClient, processInstanceId);

      const triggerResult = await adminClient.events.triggerMessage(
        'integration-test-message',
        { data: 'integration-payload' },
      );

      expect(triggerResult.messageName).toBe('integration-test-message');
      expect(triggerResult.messageId).toBeTruthy();
      expect(triggerResult.deliveries.length).toBeGreaterThanOrEqual(1);
      expect(triggerResult.pending).toBe(false);

      await waitForState(adminClient, processInstanceId, 'finished');
    });

    it('returns pending when no subscriber is active', async () => {
      const triggerResult = await adminClient.events.triggerMessage(
        'no-subscriber-message',
        { data: 'will-pend' },
      );

      expect(triggerResult.messageName).toBe('no-subscriber-message');
      expect(triggerResult.deliveries).toEqual([]);
      expect(triggerResult.pending).toBe(true);
    });
  });
});

/**
 * Poll until a flow node instance is in 'waiting' state for this PI.
 * This replaces WebSocket-based waiting with simple polling.
 */
async function waitForCatchWaiting(
  client: DaemonEngineClient,
  processInstanceId: string,
  timeoutMs = 15_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await client.graphql.queryFlowNodeInstances({
      fields: ['id', 'state', 'flowNodeType'],
      filter: {
        processInstanceId: { eq: processInstanceId },
        state: { eq: 'waiting' },
      },
      pagination: { mode: 'offset', limit: 10, offset: 0 },
    });
    if (result.data.length > 0) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(
    `No waiting flow node instance found for PI ${processInstanceId} within ${timeoutMs}ms`,
  );
}
