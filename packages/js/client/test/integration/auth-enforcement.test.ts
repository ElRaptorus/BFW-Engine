import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { DaemonEngineClient } from '../../src/daemon-engine-client.js';
import {
  ensureEngineReachable,
  createAdminClient,
  createUnauthenticatedClient,
  createExpiredTokenClient,
  deployFixture,
  cleanupInstances,
  waitForUserTask,
  readFixture,
} from '../support/test-engine.js';
import { UnauthorizedError } from '@elraptorus/daemonengine_sdk';

let adminClient: DaemonEngineClient;
let unauthenticatedClient: DaemonEngineClient;
let expiredTokenClient: DaemonEngineClient;
let existingProcessId: string;
let existingPiId: string;
let existingFniId: string;

beforeAll(async () => {
  await ensureEngineReachable();
  adminClient = await createAdminClient();
  unauthenticatedClient = await createUnauthenticatedClient();
  expiredTokenClient = await createExpiredTokenClient();
  await adminClient.notifications.connect();
  expect(readFixture('integration-passthrough.bpmn')).toContain('integration-passthrough');
  expect(readFixture('integration-user-task.bpmn')).toContain('integration-user-task');
  await deployFixture(adminClient, 'integration-passthrough.bpmn');
  await deployFixture(adminClient, 'integration-user-task.bpmn');
  existingProcessId = 'integration-passthrough';
  const passthroughStartResult = await adminClient.processes.start(existingProcessId);
  existingPiId = passthroughStartResult.processInstanceId;
  const userTaskStartResult = await adminClient.processes.start('integration-user-task');
  existingFniId = await waitForUserTask(adminClient, userTaskStartResult.processInstanceId);
});

afterAll(async () => {
  await cleanupInstances(adminClient);
  adminClient.notifications.disconnect();
});

describe('Auth Enforcement', () => {
  describe('401 - no or invalid token on every protected route', () => {
    const protectedRoutes: { name: string; call: (client: DaemonEngineClient) => Promise<unknown> }[] = [
      { name: 'processes.getAll()', call: (client) => client.processes.getAll() },
      { name: 'processes.get(id)', call: (client) => client.processes.get(existingProcessId) },
      { name: 'processes.getVersions(id)', call: (client) => client.processes.getVersions(existingProcessId) },
      { name: 'processes.deploy(sources)', call: (client) => client.processes.deploy('<dummy/>') },
      { name: 'processes.start(id)', call: (client) => client.processes.start(existingProcessId) },
      { name: 'processes.enable(id)', call: (client) => client.processes.enable(existingProcessId) },
      { name: 'processes.disable(id)', call: (client) => client.processes.disable(existingProcessId) },
      { name: 'processes.undeploy(id)', call: (client) => client.processes.undeploy(existingProcessId) },
      {
        name: 'processes.deleteVersion(id, v)',
        call: (client) => client.processes.deleteVersion(existingProcessId, '1.0.0'),
      },
      { name: 'processInstances.abort(id)', call: (client) => client.processInstances.abort(existingPiId) },
      { name: 'processInstances.delete(id)', call: (client) => client.processInstances.delete(existingPiId) },
      {
        name: 'userTasks.finish(id, result)',
        call: (client) => client.userTasks.finish(existingFniId, { result: {} }),
      },
      { name: 'userTasks.cancel(id)', call: (client) => client.userTasks.cancel(existingFniId) },
      { name: 'engine.stats()', call: (client) => client.engine.stats() },
      {
        name: 'graphql.queryProcessModels',
        call: (client) =>
          client.graphql.queryProcessModels({
            fields: ['id'],
            pagination: { mode: 'offset', limit: 1, offset: 0 },
          }),
      },
      {
        name: 'graphql.queryProcessInstances',
        call: (client) =>
          client.graphql.queryProcessInstances({
            fields: ['id'],
            pagination: { mode: 'offset', limit: 1, offset: 0 },
          }),
      },
    ];

    for (const route of protectedRoutes) {
      it(`rejects ${route.name} with invalid token`, async () => {
        try {
          await route.call(unauthenticatedClient);
          expect.fail('Should have thrown');
        } catch (error) {
          expect(error).toBeInstanceOf(UnauthorizedError);
          if (error instanceof UnauthorizedError) {
            expect(error.statusCode).toBe(401);
          }
        }
      });
    }
  });

  describe('401 - expired token on every protected route', () => {
    const protectedRoutes: { name: string; call: (client: DaemonEngineClient) => Promise<unknown> }[] = [
      { name: 'processes.getAll()', call: (client) => client.processes.getAll() },
      { name: 'processes.get(id)', call: (client) => client.processes.get(existingProcessId) },
      { name: 'processes.getVersions(id)', call: (client) => client.processes.getVersions(existingProcessId) },
      { name: 'processes.deploy(sources)', call: (client) => client.processes.deploy('<dummy/>') },
      { name: 'processes.start(id)', call: (client) => client.processes.start(existingProcessId) },
      { name: 'processes.enable(id)', call: (client) => client.processes.enable(existingProcessId) },
      { name: 'processes.disable(id)', call: (client) => client.processes.disable(existingProcessId) },
      { name: 'processes.undeploy(id)', call: (client) => client.processes.undeploy(existingProcessId) },
      {
        name: 'processes.deleteVersion(id, v)',
        call: (client) => client.processes.deleteVersion(existingProcessId, '1.0.0'),
      },
      { name: 'processInstances.abort(id)', call: (client) => client.processInstances.abort(existingPiId) },
      { name: 'processInstances.delete(id)', call: (client) => client.processInstances.delete(existingPiId) },
      {
        name: 'userTasks.finish(id, result)',
        call: (client) => client.userTasks.finish(existingFniId, { result: {} }),
      },
      { name: 'userTasks.cancel(id)', call: (client) => client.userTasks.cancel(existingFniId) },
      { name: 'engine.stats()', call: (client) => client.engine.stats() },
      {
        name: 'graphql.queryProcessModels',
        call: (client) =>
          client.graphql.queryProcessModels({
            fields: ['id'],
            pagination: { mode: 'offset', limit: 1, offset: 0 },
          }),
      },
      {
        name: 'graphql.queryProcessInstances',
        call: (client) =>
          client.graphql.queryProcessInstances({
            fields: ['id'],
            pagination: { mode: 'offset', limit: 1, offset: 0 },
          }),
      },
    ];

    for (const route of protectedRoutes) {
      it(`rejects ${route.name} with expired token`, async () => {
        try {
          await route.call(expiredTokenClient);
          expect.fail('Should have thrown');
        } catch (error) {
          expect(error).toBeInstanceOf(UnauthorizedError);
          if (error instanceof UnauthorizedError) {
            expect(error.statusCode).toBe(401);
          }
        }
      });
    }
  });

  describe('unprotected routes pass without auth', () => {
    it('health() resolves without auth', async () => {
      await unauthenticatedClient.engine.health();
    });

    it('info() resolves without auth', async () => {
      const info = await unauthenticatedClient.engine.info();
      expect(info).toBeDefined();
    });

    it('metrics() resolves without auth', async () => {
      const metrics = await unauthenticatedClient.engine.metrics();
      expect(metrics === null || typeof metrics === 'string').toBe(true);
    });
  });

  describe('valid token passes on all protected routes', () => {
    const readOnlyProtectedRoutes: { name: string; call: (client: DaemonEngineClient) => Promise<unknown> }[] = [
      { name: 'processes.getAll()', call: (client) => client.processes.getAll() },
      { name: 'processes.get(id)', call: (client) => client.processes.get(existingProcessId) },
      { name: 'processes.getVersions(id)', call: (client) => client.processes.getVersions(existingProcessId) },
      { name: 'engine.stats()', call: (client) => client.engine.stats() },
      {
        name: 'graphql.queryProcessModels',
        call: (client) =>
          client.graphql.queryProcessModels({
            fields: ['id'],
            pagination: { mode: 'offset', limit: 1, offset: 0 },
          }),
      },
      {
        name: 'graphql.queryProcessInstances',
        call: (client) =>
          client.graphql.queryProcessInstances({
            fields: ['id'],
            pagination: { mode: 'offset', limit: 1, offset: 0 },
          }),
      },
    ];

    for (const route of readOnlyProtectedRoutes) {
      it(`succeeds ${route.name} with valid token`, async () => {
        await route.call(adminClient);
      });
    }
  });
});
