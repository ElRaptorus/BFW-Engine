/**
 * Data-access security tests: soft-delete invisibility and claim-scoped visibility.
 *
 * Soft-delete tests verify that deleted records are absolutely invisible
 * through all API surfaces — including for the `zeeky_boogie_doog` admin.
 *
 * Claim-scoped tests verify that actors only see data their claims permit.
 *
 * Requires a running engine (docker-compose.dev.yml).
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  createOwnPiClient,
  createLaneClient,
  deployFixture,
  deployDmnFixture,
  readFixture,
  cleanupInstances,
  waitForState,
  waitForUserTask,
} from '../support/test-engine.js';

let adminClient: DaemonEngineClient;

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  await adminClient.notifications.connect();
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
  await deployFixture(adminClient, 'integration-user-task-lane.bpmn');
  await deployDmnFixture(adminClient, 'simple_unique.dmn');
});

afterAll(async () => {
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

// ---------------------------------------------------------------------------
// Soft-Delete Tests
// ---------------------------------------------------------------------------

describe.sequential('Soft-Delete Invisibility', () => {
  // 5.1
  describe('soft-deleted PI invisible via GraphQL', () => {
    it('admin cannot see soft-deleted PI via get or list', async () => {
      const { processInstanceId } = await adminClient.processes.start(
        'integration-passthrough',
      );
      await waitForState(adminClient, processInstanceId, 'finished');

      const instanceBefore = await adminClient.graphql.getProcessInstance(
        processInstanceId,
        { fields: ['id', 'state'] },
      );
      expect(instanceBefore).not.toBeNull();

      await adminClient.processInstances.delete(processInstanceId);

      const instanceAfter = await adminClient.graphql.getProcessInstance(
        processInstanceId,
        { fields: ['id', 'state'] },
      );
      expect(instanceAfter).toBeNull();

      const listResult = await adminClient.graphql.queryProcessInstances({
        fields: ['id'],
        filter: { id: { eq: processInstanceId } },
        pagination: { mode: 'offset', limit: 10, offset: 0 },
      });
      expect(listResult.data.length).toBe(0);
    });
  });

  // 5.2
  describe('soft-deleted ProcessVersion invisible', () => {
    it('admin cannot see deleted process version via REST', async () => {
      const secondVersionBpmn = readFixture('integration-passthrough.bpmn')
        .replace(
          '<evil:version>1.0.0</evil:version>',
          '<evil:version>99.99.99</evil:version>',
        );

      await adminClient.processes.deploy(secondVersionBpmn);

      const versionsBefore = await adminClient.processes.getVersions(
        'integration-passthrough',
      );
      const hasVersion = versionsBefore.some(
        (version) => version.version === '99.99.99',
      );
      expect(hasVersion).toBe(true);

      await adminClient.processes.deleteVersion(
        'integration-passthrough',
        '99.99.99',
      );

      const versionsAfter = await adminClient.processes.getVersions(
        'integration-passthrough',
      );
      const stillHas = versionsAfter.some(
        (version) => version.version === '99.99.99',
      );
      expect(stillHas).toBe(false);
    });
  });

  // 5.3
  describe('soft-deleted DecisionVersion invisible', () => {
    it('admin cannot see deleted decision version via REST', async () => {
      const versionsBefore = await adminClient.decisions.getVersions(
        'definitions_discount',
      );
      expect(versionsBefore.length).toBeGreaterThanOrEqual(1);

      const targetVersion = versionsBefore[versionsBefore.length - 1]!;
      const versionString = targetVersion.version!;

      await adminClient.decisions.deleteVersion(
        'definitions_discount',
        versionString,
      );

      const versionsAfter = await adminClient.decisions.getVersions(
        'definitions_discount',
      );
      const stillHas = versionsAfter.some(
        (version) => version.version === versionString,
      );
      expect(stillHas).toBe(false);

      // Re-deploy so other tests still have a valid decision
      await deployDmnFixture(adminClient, 'simple_unique.dmn');
    });
  });

  // 5.4
  describe('admin + soft-delete', () => {
    it('zeeky_boogie_doog admin gets null for soft-deleted PI', async () => {
      const { processInstanceId } = await adminClient.processes.start(
        'integration-passthrough',
      );
      await waitForState(adminClient, processInstanceId, 'finished');

      await adminClient.processInstances.delete(processInstanceId);

      const result = await adminClient.graphql.getProcessInstance(
        processInstanceId,
        { fields: ['id', 'state'] },
      );

      expect(result).toBeNull();
    });
  });
});

// ---------------------------------------------------------------------------
// Claim-Scoped Visibility Tests
// ---------------------------------------------------------------------------

describe.sequential('Claim-Scoped Visibility', () => {
  // 5.5
  describe('starter-only read', () => {
    it('Actor B (wrong lane) cannot see PI on accounting lane', async () => {
      const actorBClient = await createOwnPiClient({
        sub: 'actor-b-viewer',
        'lane:default': false,
      });

      const { processInstanceId } = await adminClient.processes.start(
        'integration-user-task-lane',
      );
      await waitForUserTask(adminClient, processInstanceId);

      const actorBResult = await actorBClient.graphql.getProcessInstance(
        processInstanceId,
        { fields: ['id', 'state'] },
      );
      expect(actorBResult).toBeNull();

      const accountingClient = await createLaneClient(['accounting']);
      const accountingResult =
        await accountingClient.graphql.getProcessInstance(processInstanceId, {
          fields: ['id', 'state'],
        });
      expect(accountingResult).not.toBeNull();

      await adminClient.processInstances.abort(processInstanceId);
      await adminClient.processInstances.delete(processInstanceId);
    });
  });

  // 5.6
  describe('lane-scoped read', () => {
    it('only actors with matching lane claim see the PI', async () => {
      const accountingClient = await createLaneClient(['accounting']);

      const { processInstanceId } = await adminClient.processes.start(
        'integration-user-task-lane',
      );
      await waitForUserTask(adminClient, processInstanceId);

      const accountingResult =
        await accountingClient.graphql.getProcessInstance(processInstanceId, {
          fields: ['id', 'state'],
        });
      expect(accountingResult).not.toBeNull();

      const engineeringClient = await createLaneClient(['engineering']);
      const engineeringResult =
        await engineeringClient.graphql.getProcessInstance(
          processInstanceId,
          { fields: ['id', 'state'] },
        );
      expect(engineeringResult).toBeNull();

      await adminClient.processInstances.abort(processInstanceId);
      await adminClient.processInstances.delete(processInstanceId);
    });
  });

  // 5.7
  describe('admin sees all', () => {
    it('zeeky_boogie_doog admin sees PIs regardless of starter/lane', async () => {
      const restrictedClient = await createOwnPiClient({
        sub: 'restricted-starter',
      });
      const { processInstanceId } = await restrictedClient.processes.start(
        'integration-passthrough',
      );
      await waitForState(adminClient, processInstanceId, 'finished');

      const adminResult = await adminClient.graphql.getProcessInstance(
        processInstanceId,
        { fields: ['id', 'state'] },
      );
      expect(adminResult).not.toBeNull();
      expect(adminResult!.id).toBe(processInstanceId);

      await adminClient.processInstances.delete(processInstanceId);
    });
  });

  // 5.8
  describe('GraphQL list scoping', () => {
    it('each actor only sees their visible subset', async () => {
      const actorAClient = await createLaneClient(['accounting']);
      const actorBClient = await createLaneClient(['engineering']);

      const startA = await adminClient.processes.start(
        'integration-user-task-lane',
      );
      await waitForUserTask(adminClient, startA.processInstanceId);

      const startB = await adminClient.processes.start(
        'integration-user-task-lane',
      );
      await waitForUserTask(adminClient, startB.processInstanceId);

      const aList = await actorAClient.graphql.queryProcessInstances({
        fields: ['id'],
        pagination: { mode: 'offset', limit: 100, offset: 0 },
      });
      const aIds = aList.data.map((instance) => instance.id);
      expect(aIds).toContain(startA.processInstanceId);

      const bList = await actorBClient.graphql.queryProcessInstances({
        fields: ['id'],
        pagination: { mode: 'offset', limit: 100, offset: 0 },
      });
      const bIds = bList.data.map((instance) => instance.id);
      expect(bIds).not.toContain(startA.processInstanceId);
      expect(bIds).not.toContain(startB.processInstanceId);

      await adminClient.processInstances.abort(startA.processInstanceId);
      await adminClient.processInstances.abort(startB.processInstanceId);
      await adminClient.processInstances.delete(startA.processInstanceId);
      await adminClient.processInstances.delete(startB.processInstanceId);
    });
  });
});
