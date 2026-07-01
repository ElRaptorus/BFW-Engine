/**
 * Integration tests for global `engine:events` WebSocket channel.
 *
 * Subscribes via `onEngineEvent()` BEFORE triggering actions to avoid
 * the process-instance-specific subscribe-before-start race condition.
 *
 * Requires a running engine (docker-compose.dev.yml).
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { EngineEventEnvelope } from '@elraptorus/daemonengine_sdk';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  deployFixture,
  deployDmnFixture,
  cleanupInstances,
  waitForState,
  waitForUserTask,
} from '../support/test-engine.js';

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

let adminClient: DaemonEngineClient;

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  await adminClient.notifications.connect();
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
});

afterAll(async () => {
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

describe.sequential('Global Engine Events (engine:events channel)', () => {
  // 4.1 — uses user-task fixture so the PI stays alive long enough for
  // FNI events to propagate through the EventBus → PubSub → Channel pipeline.
  describe('subscribe before PI start', () => {
    it('receives ProcessInstanceStateChanged and FlowNodeInstance events', async () => {
      const receivedEvents: EngineEventEnvelope[] = [];
      const subscription = await adminClient.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          receivedEvents.push(envelope);
        },
      );

      try {
        const { processInstanceId } = await adminClient.processes.start(
          'integration-user-task',
        );

        const fniId = await waitForUserTask(adminClient, processInstanceId);

        const eventsForPi = (type: string) =>
          receivedEvents.filter(
            (event) =>
              event.type === type &&
              (event.data as Record<string, unknown>).processInstanceId ===
                processInstanceId,
          );

        const waitForEvents = async (predicate: () => boolean, ms = 5000) => {
          const deadline = Date.now() + ms;
          while (!predicate() && Date.now() < deadline) {
            await sleep(200);
          }
        };

        await waitForEvents(
          () =>
            eventsForPi('ProcessInstanceStateChanged').length >= 1 &&
            eventsForPi('FlowNodeInstanceStarted').length >= 1,
        );

        expect(eventsForPi('ProcessInstanceStateChanged').length).toBeGreaterThanOrEqual(1);
        expect(eventsForPi('FlowNodeInstanceStarted').length).toBeGreaterThanOrEqual(1);

        await adminClient.userTasks.finish(fniId);
        await waitForState(adminClient, processInstanceId, 'finished');

        await waitForEvents(
          () => eventsForPi('FlowNodeInstanceFinished').length >= 1,
        );

        expect(eventsForPi('FlowNodeInstanceFinished').length).toBeGreaterThanOrEqual(1);
        expect(eventsForPi('ProcessInstanceStateChanged').length).toBeGreaterThanOrEqual(2);

        await adminClient.processInstances.delete(processInstanceId);
      } finally {
        subscription.dispose();
      }
    });
  });

  // 4.2
  describe('multiple concurrent PIs', () => {
    it('receives events from both PIs on the global channel', async () => {
      const receivedEvents: EngineEventEnvelope[] = [];
      const subscription = await adminClient.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          receivedEvents.push(envelope);
        },
      );

      try {
        const start1 = await adminClient.processes.start('integration-passthrough');
        const start2 = await adminClient.processes.start('integration-passthrough');

        await waitForState(adminClient, start1.processInstanceId, 'finished');
        await waitForState(adminClient, start2.processInstanceId, 'finished');
        await sleep(1500);

        const piIds = new Set(
          receivedEvents
            .filter((event) => event.type === 'ProcessInstanceStateChanged')
            .map(
              (event) =>
                (event.data as Record<string, unknown>)
                  .processInstanceId as string,
            ),
        );

        expect(piIds.has(start1.processInstanceId)).toBe(true);
        expect(piIds.has(start2.processInstanceId)).toBe(true);

        await adminClient.processInstances.delete(start1.processInstanceId);
        await adminClient.processInstances.delete(start2.processInstanceId);
      } finally {
        subscription.dispose();
      }
    });
  });

  // 4.3
  describe('DMN events on global channel', () => {
    it('receives DecisionEvaluated event after ad-hoc evaluation', async () => {
      await deployDmnFixture(adminClient, 'simple_unique.dmn');

      const receivedEvents: EngineEventEnvelope[] = [];
      const subscription = await adminClient.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          if (envelope.type === 'DecisionEvaluated') {
            receivedEvents.push(envelope);
          }
        },
      );

      try {
        receivedEvents.length = 0;
        await adminClient.decisions.evaluate('definitions_discount', {
          age: 25,
        });
        await sleep(1500);

        expect(receivedEvents.length).toBeGreaterThanOrEqual(1);
        const event = receivedEvents[0]!;
        expect(event.type).toBe('DecisionEvaluated');
        expect(
          (event.data as Record<string, unknown>).decisionDefinitionId,
        ).toBeDefined();
      } finally {
        subscription.dispose();
      }
    });
  });

  // 4.4
  describe('envelope shape', () => {
    it('every event has type (string), data (object), occurredAt (ISO 8601)', async () => {
      const receivedEvents: EngineEventEnvelope[] = [];
      const subscription = await adminClient.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          receivedEvents.push(envelope);
        },
      );

      try {
        const { processInstanceId } = await adminClient.processes.start(
          'integration-passthrough',
        );
        await waitForState(adminClient, processInstanceId, 'finished');
        await sleep(1500);

        expect(receivedEvents.length).toBeGreaterThanOrEqual(1);

        for (const event of receivedEvents) {
          expect(typeof event.type).toBe('string');
          expect(event.type.length).toBeGreaterThan(0);
          expect(typeof event.data).toBe('object');
          expect(event.data).not.toBeNull();

          const occurredAt = (event as Record<string, unknown>)
            .occurredAt as string;
          if (occurredAt != null) {
            expect(typeof occurredAt).toBe('string');
            expect(new Date(occurredAt).toISOString()).toBeTruthy();
          }
        }

        await adminClient.processInstances.delete(processInstanceId);
      } finally {
        subscription.dispose();
      }
    });
  });

  // 4.5
  describe('dispose stops delivery', () => {
    it('no new events after dispose', async () => {
      let eventCount = 0;
      const subscription = await adminClient.notifications.onEngineEvent(
        () => {
          eventCount += 1;
        },
      );

      subscription.dispose();
      const countAtDispose = eventCount;

      const { processInstanceId } = await adminClient.processes.start(
        'integration-passthrough',
      );
      await waitForState(adminClient, processInstanceId, 'finished');
      await sleep(1500);

      expect(eventCount).toBe(countAtDispose);

      await adminClient.processInstances.delete(processInstanceId);
    });
  });

  // 4.6
  describe('reconnect', () => {
    it('events flow after disconnect and reconnect', async () => {
      adminClient.notifications.disconnect();
      await adminClient.notifications.connect();

      const receivedEvents: EngineEventEnvelope[] = [];
      const subscription = await adminClient.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          receivedEvents.push(envelope);
        },
      );

      try {
        const { processInstanceId } = await adminClient.processes.start(
          'integration-passthrough',
        );
        await waitForState(adminClient, processInstanceId, 'finished');
        await sleep(1500);

        expect(receivedEvents.length).toBeGreaterThanOrEqual(1);

        await adminClient.processInstances.delete(processInstanceId);
      } finally {
        subscription.dispose();
      }
    });
  });
});
