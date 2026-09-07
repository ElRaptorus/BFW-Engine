/**
 * Integration tests for BPMN process definition lifecycle WebSocket events.
 *
 * These events are broadcast on the `engine:events` channel (not PI-scoped),
 * so there is no subscribe-before-start race condition.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { EngineEventEnvelope } from '@elraptorus/daemonengine_sdk';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  readFixture,
} from '../support/test-engine.js';

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

let adminClient: DaemonEngineClient | undefined;
const FIXTURE_NAME = 'integration-passthrough.bpmn';
const PROCESS_MODEL_ID = 'integration-passthrough';

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  await adminClient.notifications.connect();
});

afterAll(async () => {
  if (adminClient === undefined) {
    return;
  }
  adminClient.notifications.disconnect();
});

describe('Process Definition Lifecycle Events', { concurrent: false }, () => {
  describe('ProcessDefinitionDeployed', () => {
    it('emits a deploy event when a process is deployed via REST', async () => {
      const subscription = await adminClient!.notifications.onEngineEvent(() => {});
      subscription.dispose();

      const receivedEvents: EngineEventEnvelope[] = [];
      const eventSubscription = await adminClient!.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          if (envelope.type === 'ProcessDefinitionDeployed') {
            receivedEvents.push(envelope);
          }
        },
      );

      try {
        const source = readFixture(FIXTURE_NAME);

        try {
          await adminClient!.processes.undeploy(PROCESS_MODEL_ID);
        } catch {
          // ignore — may not exist
        }
        await sleep(200);
        receivedEvents.length = 0;

        await adminClient!.processes.deploy(source);
        await sleep(1000);

        expect(receivedEvents.length).toBeGreaterThanOrEqual(1);

        const deployEvent = receivedEvents[0];
        expect(deployEvent.type).toBe('ProcessDefinitionDeployed');

        const data = deployEvent.data as Record<string, unknown>;
        expect(data.processModelId).toBe(PROCESS_MODEL_ID);
        expect(data.version).toBeTruthy();
        expect(data.source).toMatch(/^user:/);
        expect(data.occurredAt).toBeTruthy();
      } finally {
        eventSubscription.dispose();
      }
    });
  });

  describe('ProcessDefinitionEnabled / ProcessDefinitionDisabled', () => {
    it('emits disable and enable events when toggling process state', async () => {
      const source = readFixture(FIXTURE_NAME);
      try {
        await adminClient!.processes.deploy(source);
      } catch {
        // already deployed
      }

      const receivedEvents: EngineEventEnvelope[] = [];
      const eventSubscription = await adminClient!.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          if (
            envelope.type === 'ProcessDefinitionEnabled' ||
            envelope.type === 'ProcessDefinitionDisabled'
          ) {
            receivedEvents.push(envelope);
          }
        },
      );

      try {
        await adminClient!.processes.disable(PROCESS_MODEL_ID);
        await sleep(500);

        expect(receivedEvents.length).toBeGreaterThanOrEqual(1);
        const disableEvent = receivedEvents.find(
          (event) => event.type === 'ProcessDefinitionDisabled',
        );
        expect(disableEvent).toBeDefined();

        const disableData = disableEvent!.data as Record<string, unknown>;
        expect(disableData.processModelId).toBe(PROCESS_MODEL_ID);
        expect(disableData.source).toMatch(/^user:/);

        receivedEvents.length = 0;

        await adminClient!.processes.enable(PROCESS_MODEL_ID);
        await sleep(500);

        expect(receivedEvents.length).toBeGreaterThanOrEqual(1);
        const enableEvent = receivedEvents.find(
          (event) => event.type === 'ProcessDefinitionEnabled',
        );
        expect(enableEvent).toBeDefined();

        const enableData = enableEvent!.data as Record<string, unknown>;
        expect(enableData.processModelId).toBe(PROCESS_MODEL_ID);
        expect(enableData.source).toMatch(/^user:/);
      } finally {
        eventSubscription.dispose();
      }
    });
  });

  describe('ProcessDefinitionUndeployed', () => {
    it('emits an undeploy event when a process version is deleted', async () => {
      const source = readFixture(FIXTURE_NAME);
      try {
        await adminClient!.processes.deploy(source);
      } catch {
        // already deployed
      }

      const receivedEvents: EngineEventEnvelope[] = [];
      const eventSubscription = await adminClient!.notifications.onEngineEvent(
        (envelope: EngineEventEnvelope) => {
          if (envelope.type === 'ProcessDefinitionUndeployed') {
            receivedEvents.push(envelope);
          }
        },
      );

      try {
        await adminClient!.processes.undeploy(PROCESS_MODEL_ID);
        await sleep(1000);

        expect(receivedEvents.length).toBeGreaterThanOrEqual(1);

        const undeployEvent = receivedEvents[0];
        expect(undeployEvent.type).toBe('ProcessDefinitionUndeployed');

        const data = undeployEvent.data as Record<string, unknown>;
        expect(data.processModelId).toBe(PROCESS_MODEL_ID);
        expect(data.source).toMatch(/^user:/);
        expect(data.occurredAt).toBeTruthy();
      } finally {
        eventSubscription.dispose();
      }
    });
  });
});
